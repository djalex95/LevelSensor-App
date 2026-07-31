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

  /// Frühestens dann wieder automatisch verbinden (kurzer Backoff nach einem
  /// fehlgeschlagenen Versuch, damit nicht im Sekundentakt neu verbunden wird).
  DateTime? _retryAfter;
  bool get retryDue =>
      _retryAfter == null || DateTime.now().isAfter(_retryAfter!);

  /// true, solange ein OS-autoConnect-Auftrag läuft. Das OS verbindet dann
  /// selbstständig – auch nach Abriss (schnelleres Wiederverbinden).
  bool autoPending = false;
  DateTime? _autoSince; // seit wann der Auftrag unverbunden wartet

  /// In dieser App-Sitzung wurde schon mindestens einmal erfolgreich
  /// verbunden. Erst dann wird der OS-autoConnect genutzt (der erste Versuch
  /// läuft direkt, damit ein Verbindungsproblem sofort sichtbar wird).
  bool _proven = false;

  /// autoConnect wartet ungewöhnlich lange -> Auftrag neu aufsetzen.
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
  CalibrationValue? calValue; // Kalibrierwerte (CAL-Abfrage), inkl. Nullpunkt
  int? zeroOffset; // Nullpunkt in µBar - aus der CAL-Antwort ODER direkt aus
  // der Bestätigung "OK CAL0 <n>" (so zeigt die UI den Wert sofort an)
  int? filtValue; // EMA-Filterstärke (FILT-Abfrage), Promille Altanteil
  BondsInfo? bondsInfo; // Antwort der BONDS-Diagnose (Sicherheits-Sektion)
  bool bondsUnsupported = false; // Modul-FW kennt CMD_GETBONDS nicht (1.0.0)
  String? moduleFw; // Firmware des Funkmoduls (MODFW-Zeile der BONDS-Antwort)
  bool _v13Queried = false; // CAL/FILT nach dem ersten 1.3.0-STAT abgefragt
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

  /// true, wenn die Firmware die 1.3.0-Funktionen kann (CAL0, FILT, P-Feld).
  /// Erkannt am P-Feld der STAT-Zeile - das gibt es genau ab 1.3.0.
  bool get supportsV13 => status?.rawPress != null;

  StreamSubscription<String>? _lineSub;
  StreamSubscription<bool>? _connSub;
  Timer? _rssiTimer;

  /// Verbindet den Sensor (falls nicht schon verbunden).
  ///
  /// Der ERSTE Versuch je App-Sitzung (und jede manuelle Aktion) läuft direkt,
  /// damit ein Verbindungsproblem sofort sichtbar wird. Erst NACH einer
  /// erfolgreichen Verbindung nutzen die folgenden Wiederverbindungen den
  /// OS-autoConnect – das verbindet nach einem Abriss deutlich schneller.
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
      _retryAfter = DateTime.now().add(const Duration(seconds: 8));
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

  /// Wartet auf die Antwort der laufenden CAL-Abfrage (siehe [requestCal]).
  Completer<CalibrationValue>? _calWaiter;

  /// Fragt den Kalibrierwert ab und wartet auf die Antwort. Wird nur für die
  /// Sicherung gebraucht und daher bewusst nicht bei jedem Verbinden gesendet
  /// – Firmware vor 1.2.9 kennt `CAL` nicht und würde mit `ERR ?` antworten.
  /// Null = keine Antwort (zu alte Firmware oder Verbindung weg).
  Future<CalibrationValue?> requestCal(
      {Duration timeout = const Duration(seconds: 3)}) async {
    _calWaiter = Completer<CalibrationValue>();
    try {
      await send('CAL');
      return await _calWaiter!.future.timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      _calWaiter = null;
    }
  }

  /// Nullpunkt und Filterstärke nacheinander abfragen (die Firmware hat
  /// einen einzelnen Kommandopuffer - zwischen den Kommandos etwas Luft).
  Future<void> _queryV13() async {
    try {
      await send('CAL');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await send('FILT');
    } catch (_) {}
  }

  /// Wartet auf die Antwort der laufenden FILT-Abfrage (siehe [requestFilt]).
  Completer<int>? _filtWaiter;

  /// Fragt die Filterstärke ab und wartet auf die Antwort.
  /// Null = keine Antwort (Firmware vor 1.3.0 oder Verbindung weg).
  Future<int?> requestFilt(
      {Duration timeout = const Duration(seconds: 3)}) async {
    _filtWaiter = Completer<int>();
    try {
      await send('FILT');
      return await _filtWaiter!.future.timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      _filtWaiter = null;
    }
  }

  /// Kommando senden und im Log vermerken. Wirft bei Sendefehler.
  Future<void> send(String cmd) async {
    addLog('> $cmd');
    await ble.send(cmd);
  }

  void addLog(String msg) {
    if (kDebugMode) {
      // Im Debug-Lauf (flutter run) den kompletten BLE-Verkehr mit
      // Zeitstempel ins Terminal spiegeln - zum Nachvollziehen von
      // Timing-Fragen (z. B. CAL0 -> OK CAL0).
      final t = DateTime.now().toIso8601String().substring(11, 23);
      debugPrint('[BLE $t] [$displayName] $msg');
    }
    log.insert(0, msg);
    if (log.length > 300) log.removeLast();
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
      _proven = true; // erste erfolgreiche Verbindung -> autoConnect jetzt nutzen
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
      filtValue = null;
      zeroOffset = null;
      bondsInfo = null;
      bondsUnsupported = false;
      moduleFw = null;
      _v13Queried = false;
    }
    notifyListeners();
  }

  void _onLine(String line) {
    // Alles Empfangene ins Log - das Log-Fenster ist zugleich die
    // Diagnose-Konsole. Die STAT-Flut begrenzt der Log-Puffer (300 Zeilen).
    addLog('< $line');
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
      // Ab Firmware 1.3.0 (P-Feld vorhanden): Nullpunkt und Filterstärke
      // einmal je Verbindung abfragen, damit die Anzeige gefüllt ist.
      if (!_v13Queried && st.rawPress != null) {
        _v13Queried = true;
        _queryV13();
      }
      return;
    }
    final lin = parseLin(line);
    if (lin != null) {
      linCurve = lin;
      notifyListeners();
      return;
    }
    // Antwort auf die CAL-Abfrage. Muss vor der allgemeinen Log-Ausgabe
    // stehen; "OK CAL …" enthält kein "CAL;" und landet weiterhin im Log.
    final cal = parseCal(line);
    if (cal != null) {
      calValue = cal;
      if (cal.offset != null) zeroOffset = cal.offset;
      if (_calWaiter != null && !_calWaiter!.isCompleted) {
        _calWaiter!.complete(cal);
      }
      notifyListeners();
      return;
    }
    // Bestätigungen der Nullpunkt-Kommandos: Offset direkt übernehmen,
    // ohne auf eine eigene CAL-Abfrage zu warten.
    final z = parseCal0Ack(line);
    if (z != null) {
      zeroOffset = z;
      notifyListeners();
      return;
    }
    if (line.contains('OK CAL0RESET')) {
      zeroOffset = 0;
      notifyListeners();
      return;
    }
    final bonds = parseBonds(line);
    if (bonds != null) {
      bondsInfo = bonds;
      bondsUnsupported = false;
      notifyListeners();
      return;
    }
    if (line.contains('ERR BONDS st=255')) {
      bondsUnsupported = true;
      notifyListeners();
      return;
    }
    if (line.startsWith('MODFW;')) {
      moduleFw = line.substring(6).trim();
      notifyListeners();
      return;
    }
    // Antwort auf die FILT-Abfrage ("OK FILT …" matcht bewusst nicht).
    final filt = parseFilt(line);
    if (filt != null) {
      filtValue = filt;
      if (_filtWaiter != null && !_filtWaiter!.isCompleted) {
        _filtWaiter!.complete(filt);
      }
      notifyListeners();
      return;
    }
    final nm = parseName(line);
    if (nm != null) {
      sensorName = nm;
      // Der gespeicherte Sensorname ist die einzige Quelle der Wahrheit:
      // die Firmware haelt den BLE-Modulnamen damit synchron (Boot-Abgleich
      // + sofortiges Umbenennen). Androids platformName kann nach einem
      // Umbenennen noch den alten Namen aus dem Cache liefern - daher
      // displayName hier nachziehen statt dem Cache zu glauben.
      if (nm.isNotEmpty) displayName = nm;
      notifyListeners();
      return;
    }
    // Schon oben ins Log übernommen - hier nichts weiter zu tun.
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
  SensorRegistry() {
    // Frische Advertisements sind die verlässlichste Namensquelle: Androids
    // platformName-Cache liefert nach einem Umbenennen/Werksreset oft noch
    // den alten Namen. Läuft irgendwo ein Scan (Sensor-hinzufügen-Dialog
    // oder refreshNamesFromScan), ziehen bekannte Sensoren ohne
    // gespeicherten Namen ihren Anzeigenamen hier automatisch nach.
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      var changed = false;
      for (final r in results) {
        final s = byId(r.device.remoteId.str);
        if (s == null) continue;
        final adv = r.advertisementData.advName;
        if (adv.isEmpty || adv == s.displayName) continue;
        if (s.sensorName != null && s.sensorName!.isNotEmpty) {
          continue; // gespeicherter Name ist die Wahrheit (NAME-Abfrage)
        }
        s.displayName = adv;
        changed = true;
      }
      if (changed) {
        save();
        notifyListeners();
      }
    });
  }

  final List<SensorConnection> sensors = [];
  Timer? _reconnectTimer;
  StreamSubscription<List<ScanResult>>? _scanSub;

  /// true, während die App im Hintergrund ist und die Sensoren bewusst
  /// freigegeben wurden (siehe suspend()). Unterdrückt den Auto-Reconnect,
  /// damit ein Handy den einzeln koppelbaren Sensor nicht blockiert.
  bool _suspended = false;
  bool get suspended => _suspended;

  /// Kurzen Scan starten, um Anzeigenamen bekannter Sensoren aufzufrischen
  /// (z. B. nach einem Werksreset: der Sensor advertised wieder als
  /// "LevelSense-<UID>"). Die Übernahme erledigt der scanResults-Listener.
  Future<void> refreshNamesFromScan() async {
    if (FlutterBluePlus.isScanningNow) return;
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (_) {/* z. B. Bluetooth aus – dann eben beim nächsten Scan */}
  }

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
      if (_suspended) return; // App im Hintergrund -> Sensor bewusst freigeben
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

  /// App ist (länger) im Hintergrund: Sensoren freigeben, damit sie nicht von
  /// diesem Handy blockiert werden (der Proteus lässt nur EINE Verbindung zu).
  /// Der Auto-Reconnect pausiert, bis resume() aufgerufen wird. Ein laufendes
  /// OTA wird nicht unterbrochen.
  void suspend() {
    if (_suspended || dfuActive != null) return;
    _suspended = true;
    for (final s in sensors) {
      s.disconnect().catchError((_) {});
    }
    notifyListeners();
  }

  /// App ist wieder im Vordergrund: Auto-Reconnect fortsetzen und bekannte
  /// Sensoren sofort neu verbinden (statt bis zum nächsten Timer-Tick zu warten).
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    for (final s in sensors) {
      s.connect().catchError((_) {});
    }
    notifyListeners();
  }

  Future<void> _checkFirmwareUpdate(SensorConnection conn) async {
    try {
      if (fwAssets.isEmpty) fwAssets = await _fwRepo.fetchBinAssets();
      // Nur Assets der eigenen Hardware-Variante bewerten - sonst meldet
      // die App einem V1-Sensor ein "Update", das es fuer ihn nicht gibt.
      final match = assetsForVariant(fwAssets, conn.status?.hwVariant);
      if (match.isEmpty) return;
      final latest = match.first.version; // neueste zuerst
      final cur = conn.status?.version;
      if (cur == null) return;
      conn.setUpdateInfo(latest, isNewerVersion(latest, cur));
    } catch (_) {/* offline o. ä. – still ignorieren */}
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    for (final s in sensors) {
      s.removeListener(notifyListeners);
      s.dispose();
    }
    super.dispose();
  }
}
