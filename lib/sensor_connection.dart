import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_service.dart';
import 'github_releases.dart';
import 'protocol.dart';

/// Zustand und BLE-Kommunikation EINES Sensors im Mehrsensor-Betrieb:
/// eigener [ProteusBle]-Kanal, geparster Status, Log und RSSI. UI-Seiten
/// hören per [addListener] auf Änderungen.
class SensorConnection extends ChangeNotifier {
  SensorConnection({required this.id, required String name})
      : displayName = name {
    _lineSub = ble.lines.listen(_onLine);
    _connSub = ble.connected.listen(_onConnected);
  }

  /// BLE-Geräteadresse (remoteId) – eindeutiger Schlüssel.
  final String id;

  /// Anzeigename (Bluetooth-Name, z. B. "LevelSense-1A2B3C" oder der
  /// vergebene Sensorname). Wird beim Verbinden aktualisiert.
  String displayName;

  final ProteusBle ble = ProteusBle();
  BluetoothDevice? device;

  bool connected = false;
  bool connecting = false;

  /// Frühestens dann wieder automatisch verbinden (Backoff nach Fehlschlag;
  /// nach abgelehnter Kopplung länger, damit der Pairing-Dialog nicht im
  /// Sekundentakt neu aufpoppt).
  DateTime? _retryAfter;
  bool get retryDue =>
      _retryAfter == null || DateTime.now().isAfter(_retryAfter!);

  /// true, solange ein OS-autoConnect-Auftrag läuft. Das OS verbindet dann
  /// selbstständig – auch nach Abriss.
  bool autoPending = false;
  DateTime? _autoSince; // seit wann der Auftrag unverbunden wartet

  /// In dieser App-Sitzung wurde schon mindestens einmal erfolgreich
  /// verbunden. Erst dann ist der autoConnect sicher: Wir wissen, dass der
  /// Bond auf BEIDEN Seiten gültig ist. Ein stehengebliebener Android-Bond
  /// bei modulseitig gelöschter Kopplung (nach Werksreset/PIN-Wechsel) würde
  /// sonst in den autoConnect laufen, wo der Pairing-Dialog nicht gehalten
  /// werden kann und sofort wieder verschwindet.
  bool _proven = false;

  /// autoConnect wartet ungewöhnlich lange -> Auftrag neu aufsetzen
  /// (fängt z. B. modulseitig gelöschte Bonds ab).
  bool get autoStale =>
      autoPending &&
      !connected &&
      _autoSince != null &&
      DateTime.now().difference(_autoSince!) > const Duration(seconds: 60);

  /// Während eines Firmware-Updates ruhen Auto-Reconnect und RSSI-Polling
  /// (der DFU-Transfer verwaltet die Verbindung selbst).
  bool dfuRunning = false;

  SensorStatus? status; // letzter STAT (bleibt bei Trennung als "zuletzt" stehen)
  String? sensorName; // im Sensor gespeicherter Name (NAME-Abfrage)
  List<int>? linCurve; // Tankform-Kennlinie
  bool bootloaderMode = false;
  String? bootloaderVersion;
  int? rssi;
  final List<String> log = [];

  // Firmware-Update-Prüfung (wird vom [SensorRegistry] gesetzt).
  bool updateChecked = false;
  bool updateAvailable = false;
  String? latestVersion;

  /// Wird beim ersten STAT mit Versionsnummer je Verbindung aufgerufen.
  void Function(SensorConnection)? onVersion;

  StreamSubscription<String>? _lineSub;
  StreamSubscription<bool>? _connSub;
  Timer? _rssiTimer;

  /// Verbindet den Sensor (falls nicht schon verbunden).
  ///
  /// Der ERSTE Versuch je App-Sitzung (und jede manuelle Aktion) läuft über
  /// den direkten, kontrollierten Weg mit explizitem Pairing: Der System-PIN-
  /// Dialog bleibt dank 90-s-createBond stabil stehen, und eine kaputte
  /// Kopplung (Android-Bond ohne passenden Modul-Bond) wird dabei repariert.
  /// Erst NACH einer erfolgreichen Verbindung nutzen die folgenden
  /// Wiederverbindungen den OS-autoConnect – dann ist der Bond nachweislich
  /// beidseitig gültig und es kann kein Pairing-Dialog mehr auftreten.
  Future<void> connect({bool manual = false}) async {
    if (connected || connecting || dfuRunning) return;
    connecting = true;
    notifyListeners();
    try {
      final d = device ??= BluetoothDevice.fromId(id);
      final auto = !manual && Platform.isAndroid && _proven;
      await ble.connect(d, autoConnect: auto);
      autoPending = auto;
      if (auto) _autoSince = DateTime.now();
      _retryAfter = null;
    } catch (e) {
      _retryAfter = DateTime.now().add(
          Duration(seconds: '$e'.contains('Kopplung') ? 30 : 10));
      rethrow;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() {
    autoPending = false;
    _autoSince = null;
    return ble.disconnect();
  }

  /// Verbindungsauftrag frisch aufsetzen (z. B. nach einem OTA, das den
  /// autoConnect gekappt hat, oder wenn er ins Leere läuft). Erst trennen,
  /// damit ein evtl. hängender OS-Auftrag sicher storniert ist.
  void kickReconnect() {
    autoPending = false;
    _autoSince = null;
    ble.disconnect().catchError((_) {}).whenComplete(() {
      connect().catchError((_) {});
    });
  }

  /// Nach dem tatsächlichen Verbinden: Grunddaten abfragen
  /// (VER = Bootloader-Erkennung, LIN = Kennlinie, NAME = Sensorname).
  Future<void> _queryBasics() async {
    if (dfuRunning) return; // während OTA keine Kommandos einstreuen
    final d = device;
    if (d != null) {
      final pn = d.platformName;
      if (pn.isNotEmpty && pn != displayName) displayName = pn;
    }
    addLog('Verbunden mit $displayName');
    try {
      await ble.send('VER');
      await ble.send('LIN');
      await ble.send('NAME');
    } catch (_) {}
  }

  /// Kommando senden und im Log vermerken. Wirft bei Sendefehler.
  Future<void> send(String cmd) async {
    addLog('> $cmd');
    await ble.send(cmd);
  }

  void addLog(String msg) {
    log.insert(0, msg);
    if (log.length > 40) log.removeLast();
    notifyListeners();
  }

  /// Vom Registry nach der GitHub-Abfrage aufgerufen.
  void setUpdateInfo(String? latest, bool available) {
    latestVersion = latest;
    updateAvailable = available;
    notifyListeners();
  }

  void _onConnected(bool c) {
    connected = c;
    if (c) {
      _proven = true; // Bond ist beidseitig gültig -> autoConnect jetzt sicher
      _autoSince = null;
      _startRssi();
      _queryBasics();
    } else {
      if (autoPending) _autoSince = DateTime.now(); // OS verbindet weiter
      _stopRssi();
      rssi = null;
      updateChecked = false;
      updateAvailable = false;
      latestVersion = null;
      bootloaderMode = false;
      bootloaderVersion = null;
      linCurve = null;
      sensorName = null;
    }
    notifyListeners();
  }

  void _onLine(String line) {
    // Bootloader meldet sich mit "BLV;x.y.z" (statt STAT).
    if (line.startsWith('BLV')) {
      final parts = line.split(';');
      bootloaderMode = true;
      bootloaderVersion = parts.length > 1 ? parts[1].trim() : null;
      notifyListeners();
      return;
    }
    final st = SensorStatus.parse(line);
    if (st != null) {
      status = st;
      bootloaderMode = false; // normale Firmware sendet STAT
      notifyListeners();
      if (!updateChecked && st.version != null) {
        updateChecked = true;
        onVersion?.call(this);
      }
      return;
    }
    final lin = parseLin(line);
    if (lin != null) {
      linCurve = lin;
      addLog('Kennlinie: ${lin.join(",")}');
      return;
    }
    final nm = parseName(line);
    if (nm != null) {
      sensorName = nm;
      notifyListeners();
      return;
    }
    addLog(line);
  }

  void _startRssi() {
    _rssiTimer?.cancel();
    _readRssi();
    _rssiTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _readRssi());
  }

  void _stopRssi() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  Future<void> _readRssi() async {
    final d = device;
    if (d == null || !connected || dfuRunning) return;
    try {
      rssi = await d.readRssi();
      notifyListeners();
    } catch (_) {/* Verbindung evtl. instabil – ignorieren */}
  }

  @override
  void dispose() {
    _rssiTimer?.cancel();
    _lineSub?.cancel();
    _connSub?.cancel();
    ble.dispose();
    super.dispose();
  }
}

/// Verwaltet die bekannten Sensoren: Persistenz (SharedPreferences),
/// gleichzeitige Verbindungen und periodisches Wiederverbinden.
class SensorRegistry extends ChangeNotifier {
  final List<SensorConnection> sensors = [];
  Timer? _reconnectTimer;

  /// Sensor, auf dem gerade ein Firmware-Update läuft (global max. eines –
  /// zwei parallele OTA-Transfers will man nicht).
  SensorConnection? dfuActive;

  static const _prefKnown = 'known_sensors';
  // Alt-Schlüssel (Einzelsensor bis App 1.4.5) – werden einmalig migriert.
  static const _prefLastId = 'last_device_id';
  static const _prefLastName = 'last_device_name';

  // Firmware-Releases (eine Abfrage, Ergebnis je Sensor bewertet).
  static const _fwRepo = GithubReleases('djalex95', 'LevelsensorV1');
  List<FirmwareAsset> fwAssets = [];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKnown);
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final e in (jsonDecode(raw) as List)) {
          _add(e['id'] as String, (e['name'] as String?) ?? '');
        }
      } catch (_) {/* kaputte Prefs -> leer starten */}
    } else {
      // Migration: zuletzt verbundener Sensor aus App <= 1.4.5.
      final id = prefs.getString(_prefLastId);
      if (id != null && id.isNotEmpty) {
        _add(id, prefs.getString(_prefLastName) ?? '');
        await save();
      }
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefKnown,
        jsonEncode([
          for (final s in sensors) {'id': s.id, 'name': s.displayName}
        ]));
  }

  SensorConnection _add(String id, String name) {
    final conn = SensorConnection(id: id, name: name.isNotEmpty ? name : id);
    conn.onVersion = _checkFirmwareUpdate;
    conn.addListener(notifyListeners);
    sensors.add(conn);
    return conn;
  }

  SensorConnection? byId(String id) {
    for (final s in sensors) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Sensor in die Liste aufnehmen (oder den vorhandenen liefern).
  SensorConnection addSensor(String id, String name) {
    final existing = byId(id);
    if (existing != null) return existing;
    final conn = _add(id, name);
    save();
    notifyListeners();
    return conn;
  }

  Future<void> removeSensor(SensorConnection conn) async {
    sensors.remove(conn);
    await save();
    try {
      await conn.disconnect();
    } catch (_) {}
    conn.removeListener(notifyListeners);
    conn.dispose();
    notifyListeners();
  }

  /// Beim App-Start alle bekannten Sensoren verbinden und getrennte danach
  /// zügig (alle 5 s) erneut versuchen. Ein laufender Versuch blockiert nicht
  /// (connecting-Guard in connect()); zusammen mit dem aktiven Trennen beim
  /// App-Schließen advertised der Sensor beim nächsten Öffnen schon wieder,
  /// sodass der erste Versuch meist sofort greift.
  void start() {
    for (final s in sensors) {
      s.connect().catchError((_) {});
    }
    _reconnectTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (dfuActive != null) return; // während OTA nichts anfassen
      for (final s in sensors) {
        if (s.connected || s.connecting) continue;
        if (s.autoPending) {
          // OS-autoConnect läuft; nur eingreifen, wenn er hängt
          if (s.autoStale) s.kickReconnect();
        } else if (s.retryDue) {
          s.connect().catchError((_) {});
        }
      }
    });
  }

  /// Alle Verbindungen aktiv trennen (beim Beenden der App).
  void disconnectAll() {
    for (final s in sensors) {
      s.disconnect().catchError((_) {});
    }
  }

  Future<void> _checkFirmwareUpdate(SensorConnection conn) async {
    try {
      if (fwAssets.isEmpty) fwAssets = await _fwRepo.fetchBinAssets();
      if (fwAssets.isEmpty) return;
      final latest = fwAssets.first.version; // neueste zuerst
      final cur = conn.status?.version;
      if (cur == null) return;
      conn.setUpdateInfo(latest, isNewerVersion(latest, cur));
    } catch (_) {/* offline o. ä. – still ignorieren */}
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    for (final s in sensors) {
      s.removeListener(notifyListeners);
      s.dispose();
    }
    super.dispose();
  }
}
