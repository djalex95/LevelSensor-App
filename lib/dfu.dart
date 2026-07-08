import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_service.dart';

/// CRC32 (IEEE/zlib) – identisch zu dfu_common.c und make_meta.py.
int dfuCrc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b & 0xFF;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> buildDfuStart(int size, int crc) =>
    [...utf8.encode('DFUS'), ..._le32(size), ..._le32(crc)];

List<int> buildDfuData(int offset, List<int> payload) =>
    [...utf8.encode('DFUD'), ..._le32(offset), ...payload];

List<int> buildDfuEnd() => utf8.encode('DFUE');

/// ---- Plausibilitätsprüfung des App-Images ----
/// Flash-/RAM-Layout des Sensors (muss zu dfu_common.h der Firmware passen).
const int dfuAppAddr = 0x08008000; // Anwendungsstart hinter dem Bootloader
const int dfuAppMax = 90 * 1024; // maximale App-Größe
const int _ramStart = 0x20000000;
const int _ramEnd = 0x20024000; // 144 KB RAM

/// Prüft, ob [fw] plausibel ein App-Image für den Sensor ist.
/// Liefert null wenn ok, sonst eine erklärende Fehlermeldung.
///
/// Fängt die häufigsten Verwechslungen ab (Bootloader-.bin, beliebige
/// Fremddateien), BEVOR etwas in den Flash geschrieben wird – der Bootloader
/// selbst prüft nur die Transfer-CRC, nicht die Sinnhaftigkeit des Inhalts.
/// Genutzt werden die ersten 8 Byte der Vektortabelle: der initiale
/// Stackpointer muss ins RAM zeigen, der Reset-Vektor (Thumb, ungerade) in
/// den App-Bereich.
String? validateAppImage(Uint8List fw) {
  String hex(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(8, '0')}';
  if (fw.length < 1024) {
    return 'Datei zu klein (${fw.length} Byte) – das ist keine Firmware.';
  }
  if (fw.length > dfuAppMax) {
    return 'Datei zu groß (${fw.length} Byte, max. $dfuAppMax Byte) – '
        'falsche Datei?';
  }
  int le32(int o) =>
      fw[o] | (fw[o + 1] << 8) | (fw[o + 2] << 16) | (fw[o + 3] << 24);
  final sp = le32(0);
  final pc = le32(4);
  if (sp < _ramStart || sp > _ramEnd) {
    return 'Kein App-Image: Initial-Stackpointer ${hex(sp)} zeigt nicht '
        'ins RAM.';
  }
  if ((pc & 1) == 0 || pc < dfuAppAddr || pc >= dfuAppAddr + dfuAppMax) {
    return 'Kein App-Image für ${hex(dfuAppAddr)}: Reset-Vektor ${hex(pc)} '
        'liegt nicht im App-Bereich (Bootloader-Datei gewählt?).';
  }
  return null;
}

/// Führt das komplette OTA-Update durch: DFU anfordern, neu verbinden,
/// Firmware im Lock-Step übertragen (jedes Paket auf die Antwort warten).
class DfuTransfer {
  final ProteusBle ble;
  final BluetoothDevice device;
  final Uint8List firmware;
  final void Function(String status, double progress) onProgress;

  /// Wird mit der Bootloader-Version aufgerufen, sobald sie bekannt ist.
  final void Function(String blVersion)? onBootloaderVersion;

  /// Nutzdaten je DFUD-Paket (passt inkl. Header in einen BLE-Write).
  static const int chunk = 192;

  DfuTransfer({
    required this.ble,
    required this.device,
    required this.firmware,
    required this.onProgress,
    this.onBootloaderVersion,
  });

  Future<void> run() async {
    final size = firmware.length;
    final crc = dfuCrc32(firmware);

    // 1) Falls die App läuft: in den Update-Modus schicken (Sensor startet neu).
    //    Falls schon im Bootloader (z. B. nach einem Abbruch): schadet nicht,
    //    der Bootloader ignoriert das Kommando.
    onProgress('Update wird vorbereitet…', 0);
    if (ble.isConnected) {
      await ble.send('DFU');
    }

    // 2) Auf einen Neustart/Trennung warten. Kommt keine Trennung, sind wir
    //    vermutlich schon im Bootloader und bleiben verbunden.
    final disconnected = await _waitDisconnect(const Duration(seconds: 6));
    if (disconnected) {
      await Future.delayed(const Duration(seconds: 3)); // Modul bootet + advertised
      onProgress('Neu verbinden…', 0);
      await _reconnect();
    } else if (!ble.isConnected) {
      onProgress('Neu verbinden…', 0);
      await _reconnect();
    }

    // 2b) Bootloader-Version abfragen (informativ; alte Bootloader ohne
    //     VER-Kommando antworten nicht – dann einfach überspringen).
    try {
      // Listener zuerst, dann senden – sonst kann eine schnelle Antwort
      // zwischen Write und Listen verloren gehen.
      final blFut =
          _awaitLine((l) => l.startsWith('BLV'), const Duration(seconds: 3));
      await ble.send('VER');
      final v = await blFut;
      final parts = v.split(';');
      if (parts.length > 1) onBootloaderVersion?.call(parts[1].trim());
    } catch (_) {/* kein VER-fähiger Bootloader – ignorieren */}

    // 3) Transfer starten.
    onProgress('Übertragung startet…', 0);
    final s = await _sendAndAwait(buildDfuStart(size, crc),
        (l) => l.startsWith('DFUS'), const Duration(seconds: 12));
    if (!s.contains('OK')) throw Exception('Start abgelehnt: $s');

    // 4) Datenblöcke sequentiell senden. Robust gegen verlorene Bestätigungen:
    //    Bleibt das Ack aus, wird dasselbe Paket erneut gesendet. Die Position
    //    richtet sich immer nach der vom Bootloader gemeldeten Empfangsposition
    //    (er ist idempotent und antwortet bei bereits geschriebenem Offset mit
    //    "DFUD ERR seq <pos>", beim Erfolg mit "DFUD <pos> OK").
    final okRe = RegExp(r'DFUD\s+(\d+)\s+OK');
    final seqRe = RegExp(r'ERR\s+seq\s+(\d+)');
    const maxRetries = 8;
    int off = 0;
    int retries = 0;
    while (off < size) {
      final end = (off + chunk < size) ? off + chunk : size;

      String r;
      try {
        r = await _sendAndAwait(buildDfuData(off, firmware.sublist(off, end)),
            (l) => l.startsWith('DFUD'), const Duration(seconds: 5));
      } on TimeoutException {
        if (++retries > maxRetries) {
          throw Exception('Zeitüberschreitung bei '
              '${(off * 100 / size).round()} % (nach $maxRetries Versuchen)');
        }
        onProgress(
            'Aussetzer – wiederhole bei ${(off * 100 / size).round()} % …',
            off / size);
        await Future.delayed(const Duration(milliseconds: 150));
        continue; // dasselbe Paket erneut senden
      }
      retries = 0;

      final ok = okRe.firstMatch(r);
      final seq = seqRe.firstMatch(r);
      if (ok != null) {
        off = int.parse(ok.group(1)!); // vom Bootloader bestätigte Position
      } else if (seq != null) {
        off = int.parse(seq.group(1)!); // Ack war verloren -> resynchronisieren
      } else {
        throw Exception('Übertragungsfehler: $r'); // echter Fehler (z. B. write)
      }
      onProgress('Übertrage… ${(off * 100 / size).round()} %', off / size);
    }

    // 5) Abschluss + CRC-Prüfung im Bootloader.
    onProgress('Prüfe und schließe ab…', 1);
    final f = await _sendAndAwait(
        buildDfuEnd(), (l) => l.startsWith('DFUE'), const Duration(seconds: 20));
    if (!f.contains('OK')) throw Exception('Abschluss fehlgeschlagen: $f');

    onProgress('Update erfolgreich – Sensor startet neu.', 1);
  }

  /// true, wenn innerhalb der Zeit eine Trennung eintrat.
  Future<bool> _waitDisconnect(Duration t) async {
    try {
      await ble.connected.firstWhere((c) => c == false).timeout(t);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _reconnect() async {
    Object? last;
    for (int i = 0; i < 6; i++) {
      try {
        if (!ble.isConnected) {
          await ble.connect(device);
        }
        if (ble.isConnected) {
          await Future.delayed(const Duration(milliseconds: 600));
          return;
        }
      } catch (e) {
        last = e;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    throw Exception('Neu verbinden fehlgeschlagen ($last)');
  }

  /// Registriert erst den Antwort-Listener und sendet DANN das Paket.
  /// Vorher wurde nach dem Senden subscribed – eine sehr schnelle Antwort
  /// konnte so zwischen Write und Listen verloren gehen (sporadische
  /// Timeouts, bei DFUS/DFUE ohne Retry sichtbar als Abbruch).
  Future<String> _sendAndAwait(
      List<int> data, bool Function(String) match, Duration timeout) async {
    final c = Completer<String>();
    late StreamSubscription<String> sub;
    sub = ble.lines.listen((line) {
      if (match(line) && !c.isCompleted) {
        c.complete(line);
        sub.cancel();
      }
    });
    try {
      await ble.sendData(data);
    } catch (_) {
      await sub.cancel();
      rethrow;
    }
    return c.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw TimeoutException('Keine Antwort ($timeout)');
    });
  }

  Future<String> _awaitLine(bool Function(String) match, Duration timeout) {
    final c = Completer<String>();
    late StreamSubscription<String> sub;
    sub = ble.lines.listen((line) {
      if (match(line) && !c.isCompleted) {
        c.complete(line);
        sub.cancel();
      }
    });
    return c.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw TimeoutException('Keine Antwort ($timeout)');
    });
  }
}
