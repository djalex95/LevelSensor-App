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

/// Führt das komplette OTA-Update durch: DFU anfordern, neu verbinden,
/// Firmware im Lock-Step übertragen (jedes Paket auf die Antwort warten).
class DfuTransfer {
  final ProteusBle ble;
  final BluetoothDevice device;
  final Uint8List firmware;
  final void Function(String status, double progress) onProgress;

  /// Nutzdaten je DFUD-Paket (passt inkl. Header in einen BLE-Write).
  static const int chunk = 192;

  DfuTransfer({
    required this.ble,
    required this.device,
    required this.firmware,
    required this.onProgress,
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

    // 3) Transfer starten.
    onProgress('Übertragung startet…', 0);
    await ble.sendData(buildDfuStart(size, crc));
    final s = await _awaitLine((l) => l.startsWith('DFUS'), const Duration(seconds: 12));
    if (!s.contains('OK')) throw Exception('Start abgelehnt: $s');

    // 4) Datenblöcke sequentiell, jeweils auf Bestätigung warten.
    int off = 0;
    while (off < size) {
      final end = (off + chunk < size) ? off + chunk : size;
      await ble.sendData(buildDfuData(off, firmware.sublist(off, end)));
      final r = await _awaitLine((l) => l.startsWith('DFUD'), const Duration(seconds: 8));
      if (r.contains('ERR')) throw Exception('Übertragungsfehler: $r');
      off = end;
      onProgress('Übertrage… ${(off * 100 / size).round()} %', off / size);
    }

    // 5) Abschluss + CRC-Prüfung im Bootloader.
    onProgress('Prüfe und schließe ab…', 1);
    await ble.sendData(buildDfuEnd());
    final f = await _awaitLine((l) => l.startsWith('DFUE'), const Duration(seconds: 20));
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
