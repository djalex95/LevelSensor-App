import 'dart:async';
import 'dart:convert';

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
  bool _autoMode = false; // true = OS-gestützter autoConnect

  /// Stream vollständiger empfangener Textzeilen (ohne Zeilenende).
  Stream<String> get lines => _lineController.stream;

  /// true, sobald verbunden und die Charakteristiken gefunden sind.
  Stream<bool> get connected => _connectedController.stream;

  bool get isConnected => _rx != null && _tx != null;

  /// Verbindet mit [device].
  ///
  /// [autoConnect] = false (Standard): direkter Verbindungsversuch mit
  /// Timeout; kehrt erst zurück, wenn eingerichtet und verbindungsbereit
  /// (für DFU und den manuellen „Jetzt verbinden"-Knopf).
  ///
  /// [autoConnect] = true: übergibt dem Betriebssystem den Auftrag, sich zu
  /// verbinden, sobald der Sensor wieder erscheint. Kehrt sofort zurück; die
  /// Einrichtung passiert, wenn die Verbindung tatsächlich steht. Das ist
  /// beim Wieder­verbinden nach App-Start deutlich schneller als eigene
  /// Timeout-Schleifen und schont den Akku.
  Future<void> connect(BluetoothDevice device,
      {bool autoConnect = false}) async {
    _device = device;
    _autoMode = autoConnect;

    /* evtl. alte Subscriptions lösen (z. B. beim Neuverbinden im DFU) */
    await _stateSub?.cancel();
    await _notifySub?.cancel();
    _buffer = '';

    _stateSub = device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        // Beim OS-autoConnect steht die Verbindung asynchron -> hier einrichten.
        if (_autoMode && !isConnected) {
          try {
            await _setup(device);
            _connectedController.add(true);
          } catch (_) {/* Einrichtung fehlgeschlagen – OS versucht es erneut */}
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        _cleanup();
        _connectedController.add(false);
      }
    });

    // MTU wird nicht im Handshake ausgehandelt (mtu: null) – bei autoConnect
    // ist das Pflicht; wir fordern sie danach separat in _setup an.
    if (autoConnect) {
      await device.connect(autoConnect: true, mtu: null);
      // kehrt sofort zurück; _setup läuft, sobald „connected" eintritt
    } else {
      await device.connect(timeout: const Duration(seconds: 15), mtu: null);
      await _setup(device);
      _connectedController.add(true);
    }
  }

  /// Große MTU anfordern, Charakteristiken suchen, Notifications aktivieren.
  Future<void> _setup(BluetoothDevice device) async {
    try {
      await device.requestMtu(247); // längere Kommandos (LIN …); iOS: No-op
    } catch (_) {}

    _rx = null;
    _tx = null;
    final services = await device.discoverServices();
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
    await _tx!.setNotifyValue(true);
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
    _autoMode = false; // laufenden OS-autoConnect beenden, nicht neu einrichten
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
