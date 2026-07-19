import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Kapselt die BLE-Kommunikation mit dem Würth-Proteus-e-Modul
/// (SPP-like Profil). Empfangene Notifications werden an `\n` in einzelne
/// Textzeilen zerlegt und über [lines] ausgegeben.
class ProteusBle {
  // UUIDs aus dem Proteus-e Referenzhandbuch (siehe BLE_Protokoll.md).
  static final Guid serviceUuid =
      Guid('6E400001-C352-11E5-953D-0002A5D5C51B');
  static final Guid rxUuid = // App -> Sensor (Write)
      Guid('6E400002-C352-11E5-953D-0002A5D5C51B');
  static final Guid txUuid = // Sensor -> App (Notify)
      Guid('6E400003-C352-11E5-953D-0002A5D5C51B');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;

  final StreamController<String> _lineController =
      StreamController<String>.broadcast();
  final StreamController<bool> _connectedController =
      StreamController<bool>.broadcast();

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  String _buffer = '';
  bool _autoMode = false; // OS-autoConnect aktiv (nur für gebondete Geräte)
  int _autoFails = 0;

  /// Stream vollständiger empfangener Textzeilen (ohne Zeilenende).
  Stream<String> get lines => _lineController.stream;

  /// true, sobald verbunden und die Charakteristiken gefunden sind.
  Stream<bool> get connected => _connectedController.stream;

  bool get isConnected => _rx != null && _tx != null;

  /// Verbindet mit [device].
  ///
  /// [autoConnect] = true darf NUR für bereits gekoppelte (gebondete) Sensoren
  /// verwendet werden: Das OS verbindet dann selbstständig, sobald der Sensor
  /// erscheint, und die Verschlüsselung läuft stumm über die gespeicherten
  /// Schlüssel – ein Pairing-Dialog kann nicht auftreten. Kehrt sofort zurück;
  /// die Einrichtung passiert, wenn die Verbindung tatsächlich steht.
  ///
  /// [autoConnect] = false (Standard): direkter, kontrollierter Versuch mit
  /// explizitem Pairing (createBond, 90 s für die PIN-Eingabe) – der einzige
  /// Weg, auf dem der System-Pairing-Dialog stabil stehen bleibt.
  Future<void> connect(BluetoothDevice device,
      {bool autoConnect = false}) async {
    _device = device;
    _autoMode = autoConnect;
    _autoFails = 0;

    /* evtl. alte Subscriptions lösen (z. B. beim Neuverbinden im DFU) */
    await _stateSub?.cancel();
    await _notifySub?.cancel();
    _buffer = '';

    _stateSub = device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        // Beim OS-autoConnect steht die Verbindung asynchron -> einrichten.
        // Das Gerät ist gebondet, die Verschlüsselung braucht keinen Dialog.
        if (_autoMode && !isConnected) {
          try {
            await _setup(device);
            _autoFails = 0;
            _connectedController.add(true);
          } catch (_) {
            // z. B. Bond modulseitig ungültig geworden: nach 2 Fehlversuchen
            // den autoConnect stoppen, damit keine Endlosschleife entsteht –
            // der nächste reguläre Versuch nimmt den Pairing-Weg.
            if (++_autoFails >= 2) _autoMode = false;
            try {
              await device.disconnect();
            } catch (_) {}
          }
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        _cleanup();
        _connectedController.add(false);
      }
    });

    if (autoConnect) {
      await device.connect(autoConnect: true, mtu: null);
      return; // Einrichtung folgt im State-Listener, sobald verbunden
    }

    // Direkter Weg: bis zu zwei Anläufe. Scheitert der erste am Zugriff auf
    // die verschlüsselten Charakteristiken (typisch LINK_SUPERVISION_TIMEOUT),
    // liegt meist ein EINSEITIGER Bond vor: Android hält noch eine Kopplung,
    // das Modul hat seine nach Werksreset/PIN-Wechsel gelöscht. Dann verweigert
    // das Modul die Verschlüsselung (mit dem alten Schlüssel), Android zeigt
    // aber KEINEN Pairing-Dialog, weil es sich für gekoppelt hält. Deshalb den
    // Android-Bond entfernen und im zweiten Anlauf frisch koppeln – jetzt kommt
    // der PIN-Dialog.
    for (var attempt = 0; attempt < 2; attempt++) {
      await device.connect(timeout: const Duration(seconds: 15));

      // Kopplung explizit anstoßen (nur Android; iOS koppelt beim ersten
      // Zugriff selbst). 90 s, damit die PIN-Eingabe im System-Dialog nicht
      // in einen Timeout läuft.
      if (Platform.isAndroid) {
        try {
          await device.createBond(timeout: 90);
        } catch (_) {
          try {
            await device.disconnect();
          } catch (_) {}
          throw Exception('Kopplung fehlgeschlagen oder abgelehnt – '
              'PIN prüfen (Werkseinstellung 123123)');
        }
      }

      try {
        await _setup(device);
        _connectedController.add(true);
        return; // erfolgreich verbunden und eingerichtet
      } catch (_) {
        try {
          await device.disconnect();
        } catch (_) {}

        if (Platform.isAndroid && attempt == 0) {
          // veralteten Bond entfernen und einmal frisch neu koppeln
          try {
            await device.removeBond();
          } catch (_) {}
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        throw Exception('Kopplung ungültig – bitte erneut verbinden '
            '(koppelt neu, PIN Werkseinstellung 123123)');
      }
    }
  }

  /// Große MTU anfordern, Charakteristiken suchen, Notifications aktivieren.
  /// Timeouts großzügig: auf iOS kann hier noch das System-Pairing laufen.
  Future<void> _setup(BluetoothDevice device) async {
    try {
      await device.requestMtu(247); // längere Kommandos (LIN …); iOS: No-op
    } catch (_) {}

    _rx = null;
    _tx = null;
    final services = await device.discoverServices(timeout: 30);
    for (final s in services) {
      if (s.uuid == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == rxUuid) _rx = c;
          if (c.uuid == txUuid) _tx = c;
        }
      }
    }

    if (_rx == null || _tx == null) {
      await device.disconnect();
      throw Exception('Proteus-Service oder Charakteristiken nicht gefunden');
    }

    await _notifySub?.cancel();
    await _tx!.setNotifyValue(true, timeout: 60);
    _notifySub = _tx!.onValueReceived.listen(_onData);
  }

  void _onData(List<int> data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    int idx;
    while ((idx = _buffer.indexOf('\n')) >= 0) {
      // Steuerzeichen entfernen – u. a. den 0x01-Datenheader, den das
      // Proteus-Modul jeder Notification voranstellt.
      final line = _buffer
          .substring(0, idx)
          .replaceAll(RegExp(r'[\x00-\x1F]'), '')
          .trim();
      _buffer = _buffer.substring(idx + 1);
      if (line.isNotEmpty) _lineController.add(line);
    }
  }

  /// Sendet ein Kommando (Zeilenende wird ergänzt).
  ///
  /// Dem Proteus-Datenpaket muss das Header-Byte 0x01 vorangestellt werden
  /// (0x01 = Nutzdaten laut Referenzhandbuch). Ohne diesen Header verwirft das
  /// Modul den Write stillschweigend. Der Schreibmodus richtet sich nach den
  /// Eigenschaften der Charakteristik (bevorzugt „Write with response").
  Future<void> send(String cmd) async {
    final rx = _rx;
    if (rx == null) {
      throw Exception('RX-Charakteristik nicht verfügbar (nicht verbunden?)');
    }
    final payload = <int>[0x01, ...utf8.encode('$cmd\n')];
    final bool withResponse = rx.properties.write;
    await rx.write(payload, withoutResponse: !withResponse);
  }

  /// Sendet rohe Nutzdaten (mit Proteus-Header 0x01, ohne Zeilenende).
  /// Für das binäre DFU-Transferprotokoll.
  Future<void> sendData(List<int> payload) async {
    final rx = _rx;
    if (rx == null) {
      throw Exception('RX-Charakteristik nicht verfügbar (nicht verbunden?)');
    }
    final bytes = <int>[0x01, ...payload];
    final bool withResponse = rx.properties.write;
    await rx.write(bytes, withoutResponse: !withResponse);
  }

  Future<void> disconnect() async {
    _autoMode = false; // laufenden OS-autoConnect-Auftrag beenden
    await _device?.disconnect();
    _cleanup();
  }

  void _cleanup() {
    _notifySub?.cancel();
    _notifySub = null;
    _rx = null;
    _tx = null;
    _buffer = '';
  }

  void dispose() {
    _stateSub?.cancel();
    _notifySub?.cancel();
    _lineController.close();
    _connectedController.close();
  }
}
