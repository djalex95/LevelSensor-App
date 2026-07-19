import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'dfu.dart';
import 'github_releases.dart';
import 'protocol.dart';
import 'sensor_connection.dart';

void main() => runApp(const FuellstandApp());

class FuellstandApp extends StatelessWidget {
  const FuellstandApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0A84FF);
    return MaterialApp(
      title: 'Füllstandsensor',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const DashboardPage(),
    );
  }
}

// ======================================================================
// Dashboard: eine Kachel je bekanntem Sensor, alle gleichzeitig verbunden
// ======================================================================

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  final SensorRegistry _registry = SensorRegistry();
  String? _appVersion;

  // App-eigene Updates (APK) aus dem App-Repo.
  static const _appRepo = GithubAppUpdate('djalex95', 'LevelSensor-App');
  static const MethodChannel _installerChannel = MethodChannel('app/installer');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _registry.addListener(_onChange);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Wird die App beendet (nicht nur in den Hintergrund geschoben), die
    // Verbindungen aktiv trennen. So gibt der Sensor die Verbindung sofort
    // frei und advertised beim nächsten Öffnen bereits wieder – das
    // Wiederverbinden ist dann spürbar schneller.
    if (state == AppLifecycleState.detached) {
      _registry.disconnectAll();
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    await _requestPermissions();
    _loadAppVersion();
    _checkAppUpdate(); // unabhängig von den Sensorverbindungen, parallel
    await _registry.load();
    _registry.start(); // alle bekannten Sensoren verbinden + Auto-Reconnect
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _registry.removeListener(_onChange);
    _registry.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    }
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() =>
            _appVersion = '${info.version} (Build ${info.buildNumber})');
      }
    } catch (_) {/* z. B. auf nicht unterstützten Plattformen – ignorieren */}
  }

  /// Beim Start prüfen, ob im App-Repo eine neuere App-Version (APK) liegt,
  /// und bei Zustimmung herunterladen + Installer öffnen (nur Android/Sideload).
  Future<void> _checkAppUpdate() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await _appRepo.fetchLatest();
      if (info == null || info.apkUrl.isEmpty || !mounted) return;
      final current = (await PackageInfo.fromPlatform()).version;
      if (!isNewerVersion(info.version, current) || !mounted) return;

      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('App-Update verfügbar'),
          content: Text(
              'Version ${info.version} ist verfügbar (installiert: $current).\n\n'
              'Jetzt herunterladen und installieren?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Später')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Aktualisieren')),
          ],
        ),
      );
      if (ok == true) await _downloadAndInstall(info);
    } catch (_) {/* offline o. ä. – still ignorieren */}
  }

  Future<void> _downloadAndInstall(AppUpdateInfo info) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Lade Update …')),
        ]),
      ),
    );
    try {
      final bytes = await GithubReleases.download(info.apkUrl);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/app-update.apk');
      await file.writeAsBytes(bytes);
      if (mounted) Navigator.pop(context); // Ladedialog schließen
      await _installerChannel.invokeMethod('install', {'path': file.path});
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Update fehlgeschlagen: $e')));
      }
    }
  }

  // ---------------- Sensor suchen / hinzufügen ----------------

  Future<void> _startScan() async {
    await _requestPermissions();
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Scan-Fehler: $e')));
      }
    }
  }

  void _openScanSheet() {
    _startScan();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final hint = Theme.of(ctx).hintColor;
        return SafeArea(
          child: SizedBox(
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Text('Sensor hinzufügen',
                          style: Theme.of(ctx).textTheme.titleMedium),
                      const Spacer(),
                      StreamBuilder<bool>(
                        stream: FlutterBluePlus.isScanning,
                        initialData: true,
                        builder: (_, snap) => snap.data == true
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : TextButton.icon(
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('Erneut suchen'),
                                onPressed: _startScan,
                              ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: StreamBuilder<List<ScanResult>>(
                    stream: FlutterBluePlus.scanResults,
                    initialData: const [],
                    builder: (_, snap) {
                      final results = (snap.data ?? const <ScanResult>[])
                          .where((r) => r.device.platformName.isNotEmpty)
                          .toList();
                      if (results.isEmpty) {
                        return Center(
                            child: Text('Suche…',
                                style: TextStyle(color: hint)));
                      }
                      return ListView(
                        children: results.map((r) {
                          final known =
                              _registry.byId(r.device.remoteId.str) != null;
                          return ListTile(
                            leading: const Icon(Icons.sensors),
                            title: Text(r.device.platformName),
                            subtitle: Text(known
                                ? 'bereits in der Liste'
                                : r.device.remoteId.str),
                            trailing: Text('${r.rssi} dBm'),
                            enabled: !known,
                            onTap: () => _addFromScan(r),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _addFromScan(ScanResult r) async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    final conn =
        _registry.addSensor(r.device.remoteId.str, r.device.platformName);
    if (mounted) Navigator.pop(context); // Sheet schließen
    conn.connect(manual: true).catchError((_) {}); // direkte Kopplung
  }

  // ---------------- Kachel-Menü (langer Druck) ----------------

  void _tileMenu(SensorConnection c) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(c.connected ? Icons.link_off : Icons.link),
              title: Text(c.connected ? 'Trennen' : 'Jetzt verbinden'),
              onTap: () {
                Navigator.pop(ctx);
                if (c.connected) {
                  c.disconnect();
                } else {
                  c.connect(manual: true).catchError((_) {});
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Aus der Liste entfernen'),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: const Text('Sensor entfernen?'),
                    content: Text(
                        '„${_tileName(c)}" wird aus der Liste entfernt und '
                        'nicht mehr automatisch verbunden. Am Sensor selbst '
                        'ändert sich nichts.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dctx, false),
                          child: const Text('Abbrechen')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dctx, true),
                          child: const Text('Entfernen')),
                    ],
                  ),
                );
                if (ok == true) await _registry.removeSensor(c);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Aufbau ----------------

  String _tileName(SensorConnection c) =>
      (c.sensorName != null && c.sensorName!.isNotEmpty)
          ? c.sensorName!
          : c.displayName;

  @override
  Widget build(BuildContext context) {
    final sensors = _registry.sensors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Füllstandsensor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Sensor hinzufügen',
            onPressed: _openScanSheet,
          ),
        ],
      ),
      body: sensors.isEmpty ? _emptyHint() : _sensorList(sensors),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 6),
          child: Text(
            'App-Version ${_appVersion ?? '–'}',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _emptyHint() {
    final hint = Theme.of(context).hintColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensors_off, size: 48, color: hint),
            const SizedBox(height: 12),
            Text('Noch kein Sensor eingerichtet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
                'Füge deine Sensoren hinzu – sie werden dann alle '
                'gleichzeitig verbunden und hier angezeigt.',
                textAlign: TextAlign.center, style: TextStyle(color: hint)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Nach Sensor suchen'),
              onPressed: _openScanSheet,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sensorList(List<SensorConnection> sensors) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: sensors.map(_sensorTile).toList(),
    );
  }

  Color _levelColor(double v) {
    if (v < 20) return const Color(0xFFE53935);
    if (v < 50) return const Color(0xFFFB8C00);
    return const Color(0xFF43A047);
  }

  int _signalLit(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -55) return 5;
    if (rssi >= -65) return 4;
    if (rssi >= -75) return 3;
    if (rssi >= -85) return 2;
    return 1;
  }

  Widget _sensorTile(SensorConnection c) {
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final s = c.status;

    String stateText;
    Color stateColor;
    if (c.connected) {
      stateText = c.bootloaderMode ? 'Bootloader-Modus' : 'verbunden';
      stateColor = c.bootloaderMode ? cs.tertiary : const Color(0xFF43A047);
    } else if (c.connecting) {
      stateText = 'verbinde…';
      stateColor = hint;
    } else {
      stateText = 'getrennt – verbinde automatisch neu';
      stateColor = hint;
    }

    final lit = _signalLit(c.rssi);
    final sigColor = lit >= 4
        ? const Color(0xFF43A047)
        : lit >= 2
            ? const Color(0xFFFB8C00)
            : const Color(0xFFE53935);

    Widget dataRow;
    if (c.bootloaderMode) {
      dataRow = Row(
        children: [
          Icon(Icons.system_update_alt, size: 20, color: cs.tertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Wartet auf ein Firmware-Update.',
                style: TextStyle(color: hint, fontSize: 13)),
          ),
        ],
      );
    } else if (s?.level != null) {
      final lvl = s!.level!.clamp(0.0, 100.0);
      final color = _levelColor(lvl);
      final liters = s.capacity != null
          ? (lvl * s.capacity! / 100).toStringAsFixed(0)
          : null;
      final details = <String>[
        if (s.capacity != null) 'Tank ${s.capacity} L',
        if (s.temp != null) '${s.temp!.toStringAsFixed(1)} °C',
        if (fluidNames.containsKey(s.fluidType)) fluidNames[s.fluidType]!,
      ];
      dataRow = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('${lvl.toStringAsFixed(1)} %',
                  style: TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w700, color: color)),
              if (liters != null) ...[
                const SizedBox(width: 14),
                Text('≈ $liters L',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurfaceVariant)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: lvl / 100,
              minHeight: 10,
              backgroundColor: cs.surface,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 5),
          Text(details.join('  ·  '),
              style: TextStyle(color: hint, fontSize: 12)),
        ],
      );
    } else {
      dataRow = Text('Noch keine Messwerte empfangen.',
          style: TextStyle(color: hint, fontSize: 13));
    }

    return Card(
      color: cs.surfaceContainerHighest,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => SensorPage(conn: c, registry: _registry)));
        },
        onLongPress: () => _tileMenu(c),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Opacity(
            opacity: c.connected ? 1 : 0.55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.sensors,
                        size: 20,
                        color: c.connected ? cs.primary : hint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_tileName(c),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                          Text(stateText,
                              style:
                                  TextStyle(fontSize: 12, color: stateColor)),
                        ],
                      ),
                    ),
                    if (c.updateAvailable)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Badge(
                          label: const Text('Update'),
                          backgroundColor: cs.primary,
                        ),
                      ),
                    if (c.connected) _SignalBars(lit: lit, color: sigColor),
                  ],
                ),
                const SizedBox(height: 10),
                dataRow,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Detailseite eines Sensors: Live-Anzeige + Einstellungen + OTA-Update
// ======================================================================

class SensorPage extends StatefulWidget {
  const SensorPage({super.key, required this.conn, required this.registry});

  final SensorConnection conn;
  final SensorRegistry registry;

  @override
  State<SensorPage> createState() => _SensorPageState();
}

class _SensorPageState extends State<SensorPage> {
  SensorConnection get c => widget.conn;

  bool _showSettings = false;
  bool _configInit = false;

  int _fluidSel = 1;
  final TextEditingController _capCtrl = TextEditingController();
  final TextEditingController _instCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _pinCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  String? _lastSensorName; // zuletzt ins Feld übernommener Name

  // Gemessene Füllhöhe (%) je Schritt für den Tankform-Assistenten
  final List<TextEditingController> _heightCtrls =
      List.generate(11, (_) => TextEditingController());

  // Firmware-Releases aus GitHub (öffentliches Repo).
  static const _fwRepo = GithubReleases('djalex95', 'LevelsensorV1');
  List<FirmwareAsset> _fwAssets = [];
  FirmwareAsset? _fwSel;
  bool _fwLoading = false;
  String? _fwError;

  @override
  void initState() {
    super.initState();
    c.addListener(_onConn);
    // Bereits vorhandene Daten übernehmen (Seite kann jederzeit geöffnet werden)
    _fwAssets = widget.registry.fwAssets;
    if (_fwAssets.isNotEmpty) _fwSel = _fwAssets.first;
    _seedFromConn();
  }

  void _seedFromConn() {
    final s = c.status;
    if (s != null && !_configInit) {
      _fluidSel = fluidNames.containsKey(s.fluidType) ? s.fluidType! : 1;
      _capCtrl.text = (s.capacity ?? 0).toString();
      _instCtrl.text = (s.instance ?? 0).toString();
      _configInit = true;
    }
    final nm = c.sensorName;
    if (nm != null && nm.isNotEmpty && nm != _lastSensorName) {
      if (!_nameFocus.hasFocus) _nameCtrl.text = nm;
      _lastSensorName = nm;
    } else if (_nameCtrl.text.isEmpty) {
      _nameCtrl.text = c.displayName;
    }
  }

  void _onConn() {
    if (!mounted) return;
    setState(() {
      _seedFromConn();
      if (!c.connected) {
        _configInit = false; // nach Neuverbinden neu übernehmen
        // Bei Trennung zurück zur Live-Ansicht (nicht während eines OTA,
        // dort verwaltet der DFU-Transfer die Verbindung selbst).
        if (_showSettings && !c.dfuRunning) _showSettings = false;
      }
    });
  }

  @override
  void dispose() {
    c.removeListener(_onConn);
    _capCtrl.dispose();
    _instCtrl.dispose();
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    _nameFocus.dispose();
    for (final ctrl in _heightCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  String get _title =>
      (c.sensorName != null && c.sensorName!.isNotEmpty)
          ? c.sensorName!
          : c.displayName;

  // ---------------- Senden / Kommandos ----------------

  Future<void> _send(String cmd) async {
    try {
      await c.send(cmd);
    } catch (e) {
      _snack('Sendefehler: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _changeName() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    _send('NAME $name');
    _snack('Name gesendet. Das Modul startet neu – die Verbindung wird '
        'automatisch wiederhergestellt.');
  }

  /// Bluetooth-PIN ändern: Sicherheitsabfrage, dann `PIN nnnnnn` senden und
  /// auf `OK PIN` warten. Bei Änderung trennt der Sensor die Verbindung,
  /// löscht alle Kopplungen und verlangt beim nächsten Verbinden die neue PIN.
  Future<void> _changePin() async {
    final pin = _pinCtrl.text.trim();
    if (!isValidBlePin(pin)) {
      _snack('Die PIN muss aus genau 6 Ziffern bestehen.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bluetooth-PIN ändern?'),
        content: Text(
            'Die PIN wird auf „$pin" geändert.\n\n'
            'Der Sensor trennt danach die Verbindung und löscht alle '
            'bestehenden Kopplungen – jedes Handy muss sich mit der neuen '
            'PIN neu koppeln.\n\n'
            'Tipp: Falls die Neukopplung fehlschlägt, den Sensor in den '
            'Bluetooth-Einstellungen des Handys einmal entfernen '
            '(„Gerät ignorieren") und erneut verbinden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('PIN ändern')),
        ],
      ),
    );
    if (ok != true) return;

    final completer = Completer<bool>();
    final sub = c.ble.lines.listen((line) {
      final ack = parsePinAck(line);
      if (ack != null && !completer.isCompleted) completer.complete(ack);
    });
    c.addLog('> PIN ******');
    try {
      await c.ble.send('PIN $pin');
    } catch (e) {
      await sub.cancel();
      _snack('Sendefehler: $e');
      return;
    }
    bool? res;
    try {
      res = await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      res = null;
    }
    await sub.cancel();
    if (!mounted) return;
    if (res == true) {
      _pinCtrl.clear();
      _snack('PIN geändert – bitte mit der neuen PIN neu koppeln.');
    } else if (res == false) {
      _snack('PIN abgelehnt (genau 6 Ziffern erforderlich).');
    } else {
      _snack('Keine Bestätigung erhalten – Verbindung prüfen.');
    }
  }

  /// Sicherheitsabfrage vor dem Werksreset (wie im PC-Tool).
  Future<void> _confirmFactoryReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Werksreset?'),
        content: const Text(
            'Setzt den Sensor auf Werkszustand zurück und löscht:\n\n'
            '• 100%-Kalibrierung\n'
            '• Tankform-Kennlinie\n'
            '• Fluidtyp, Kapazität, Instanz\n'
            '• Sensorname (der Bluetooth-Name wird beim nächsten Start '
            'wieder „LevelSense-…")\n'
            '• gespeicherte NMEA2000-Adresse\n\n'
            'Der Sensor startet danach neu und die Verbindung trennt sich.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zurücksetzen'),
          ),
        ],
      ),
    );
    if (ok == true) await _factoryReset();
  }

  /// Sendet FACTORYRESET und wartet auf die Bestätigung (`OK FACTORYRESET`).
  Future<void> _factoryReset() async {
    final completer = Completer<bool>();
    final sub = c.ble.lines.listen((line) {
      final ack = parseFactoryResetAck(line);
      if (ack != null && !completer.isCompleted) completer.complete(ack);
    });
    c.addLog('> FACTORYRESET');
    try {
      await c.ble.send('FACTORYRESET');
    } catch (e) {
      await sub.cancel();
      _snack('Sendefehler: $e');
      return;
    }
    bool? ok;
    try {
      ok = await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      ok = null;
    }
    await sub.cancel();
    if (!mounted) return;
    if (ok == true) {
      _snack('Werksreset ausgeführt – der Sensor startet neu.');
      Navigator.of(context).popUntil((r) => r.isFirst); // zum Dashboard
    } else if (ok == false) {
      _snack('Werksreset fehlgeschlagen (Sensor meldet Fehler).');
    } else {
      _snack('Keine Bestätigung erhalten – Verbindung prüfen.');
    }
  }

  void _captureHeight(int i) {
    final lvl = c.status?.level;
    if (lvl == null) {
      c.addLog('Noch kein Füllstand empfangen');
      return;
    }
    setState(() => _heightCtrls[i].text = lvl.toStringAsFixed(1));
  }

  /// Aus den gemessenen Höhen (bei je 10 % mehr Volumen) das Volumen an den
  /// Höhen-Gitterpunkten 0,10,…,100 % interpolieren (= Firmware-Kennlinie).
  List<int> _resampleToHeightGrid(List<double> heights) {
    final volumes = List.generate(11, (i) => i * 10);
    final table = <int>[];
    for (var h = 0; h <= 100; h += 10) {
      double v;
      if (h <= heights[0]) {
        v = volumes[0].toDouble();
      } else if (h >= heights[10]) {
        v = volumes[10].toDouble();
      } else {
        v = volumes[10].toDouble();
        for (var j = 0; j < 10; j++) {
          if (heights[j] <= h && h <= heights[j + 1]) {
            final span = heights[j + 1] - heights[j];
            v = span <= 0
                ? volumes[j].toDouble()
                : volumes[j] +
                    (volumes[j + 1] - volumes[j]) * (h - heights[j]) / span;
            break;
          }
        }
      }
      table.add(v.round().clamp(0, 100));
    }
    return table;
  }

  Future<void> _sendTankForm() async {
    try {
      final heights = _heightCtrls.map((ctrl) {
        final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
        if (v == null) {
          throw ArgumentError('Alle 11 Felder ausfüllen (»Übernehmen«)');
        }
        return v;
      }).toList();
      for (var i = 0; i < 10; i++) {
        if (heights[i + 1] < heights[i]) {
          throw ArgumentError('Der Füllstand muss von oben nach unten steigen');
        }
      }
      await _sendLin(_resampleToHeightGrid(heights));
    } catch (e) {
      _snack('$e');
    }
  }

  /// Sendet die Kennlinie und wartet auf die Bestätigung des Sensors
  /// (`OK LIN` / `ERR LIN`), zeigt das Ergebnis an.
  Future<void> _sendLin(List<int> pts) async {
    final cmd = buildLinCommand(pts);
    final completer = Completer<bool>();
    final sub = c.ble.lines.listen((line) {
      if (line.contains('OK LIN')) {
        if (!completer.isCompleted) completer.complete(true);
      } else if (line.contains('ERR LIN')) {
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    c.addLog('> $cmd');
    try {
      await c.ble.send(cmd);
    } catch (e) {
      await sub.cancel();
      _snack('Sendefehler: $e');
      return;
    }
    bool? ok;
    try {
      ok = await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      ok = null;
    }
    await sub.cancel();
    if (!mounted) return;
    if (ok == null) {
      _snack('Keine Bestätigung erhalten – bitte erneut versuchen.');
    } else if (ok) {
      _snack('Kennlinie übernommen ✓');
      setState(() => c.linCurve = pts); // Status sofort aktualisieren
    } else {
      _snack('Kennlinie abgelehnt (ungültige Werte).');
    }
  }

  void _showCurveGraph(List<int> curve) {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Korrekturlinie'),
        content: SizedBox(
          width: 320,
          height: 300,
          child: Column(
            children: [
              Expanded(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _LinChartPainter(curve, cs.primary),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'X: Füllhöhe %   ·   Y: Volumen %   ·   grau = linear',
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Export'),
                    onPressed: () => _exportCurveCsv(curve),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Import'),
                    onPressed: () {
                      Navigator.pop(context);
                      _importCurveCsv();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Schließen')),
        ],
      ),
    );
  }

  /// Kennlinie als CSV speichern (Spalten: Füllhöhe %, Volumen %).
  Future<void> _exportCurveCsv(List<int> curve) async {
    final sb = StringBuffer('fuellhoehe_prozent,volumen_prozent\n');
    for (var i = 0; i < curve.length; i++) {
      sb.writeln('${i * 10},${curve[i]}');
    }
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Kennlinie speichern',
        fileName: 'kennlinie.csv',
        bytes: Uint8List.fromList(utf8.encode(sb.toString())),
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (path != null) _snack('Exportiert: ${path.split('/').last}');
    } catch (e) {
      _snack('Export fehlgeschlagen: $e');
    }
  }

  /// CSV wählen, die 11 Volumen-Werte lesen und als Kennlinie senden.
  Future<void> _importCurveCsv() async {
    try {
      final res = await FilePicker.platform.pickFiles(
          withData: true,
          type: FileType.custom,
          allowedExtensions: const ['csv']);
      if (res == null || res.files.single.bytes == null) return;
      final text = utf8.decode(res.files.single.bytes!);
      final vals = <int>[];
      for (final raw in text.split(RegExp(r'[\r\n]+'))) {
        final line = raw.trim();
        if (line.isEmpty) continue;
        final parts = line.split(RegExp(r'[;,\t]'));
        final v = double.tryParse(parts.last.trim().replaceAll(',', '.'));
        if (v == null) continue; // Kopfzeile / ungültig überspringen
        vals.add(v.round());
      }
      if (vals.length < 11) {
        _snack('CSV: 11 Werte nötig (gefunden: ${vals.length}).');
        return;
      }
      final pts = vals.take(11).map((v) => v.clamp(0, 100)).toList();
      for (var i = 1; i < 11; i++) {
        if (pts[i] < pts[i - 1]) {
          _snack('CSV: Werte müssen von 0 auf 100 steigen.');
          return;
        }
      }
      await _sendLin(pts);
    } catch (e) {
      _snack('Import fehlgeschlagen: $e');
    }
  }

  // ---------------- Aufbau ----------------

  @override
  Widget build(BuildContext context) {
    return _showSettings ? _buildSettingsScaffold() : _buildMainScaffold();
  }

  Widget _buildMainScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: c.updateAvailable,
              child: const Icon(Icons.settings),
            ),
            tooltip: c.updateAvailable
                ? 'Einstellungen – Firmware-Update verfügbar'
                : 'Einstellungen',
            onPressed: c.connected
                ? () => setState(() => _showSettings = true)
                : null,
          ),
        ],
      ),
      body: _buildMainBody(),
    );
  }

  Widget _buildMainBody() {
    if (!c.connected) return _disconnectedHint();
    if (c.bootloaderMode) return _bootloaderCard();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [_levelCard()],
    );
  }

  Widget _disconnectedHint() {
    final hint = Theme.of(context).hintColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.connecting) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Verbinde…', style: TextStyle(color: hint)),
            ] else ...[
              Icon(Icons.bluetooth_disabled, size: 48, color: hint),
              const SizedBox(height: 12),
              Text('Verbindung getrennt',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('Es wird automatisch neu verbunden, sobald der Sensor '
                  'erreichbar ist.',
                  textAlign: TextAlign.center, style: TextStyle(color: hint)),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.link),
                label: const Text('Jetzt verbinden'),
                onPressed: () => c.connect(manual: true).catchError((_) {}),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bootloaderCard() {
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.system_update_alt, size: 48, color: cs.primary),
            const SizedBox(height: 12),
            Text('Sensor im Bootloader-Modus',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Bootloader-Version: ${c.bootloaderVersion ?? '–'}',
                style: TextStyle(color: hint)),
            const SizedBox(height: 6),
            Text('Der Sensor sendet keine Messwerte und wartet auf ein '
                'Firmware-Update.',
                textAlign: TextAlign.center, style: TextStyle(color: hint)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.system_update, size: 18),
              label: const Text('Zum Firmware-Update'),
              onPressed: () => setState(() => _showSettings = true),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Einstellungen ----------------

  Widget _buildSettingsScaffold() {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _showSettings = false);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _showSettings = false),
          ),
          title: Text('Einstellungen – $_title'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(30),
            child: _settingsStatusStrip(),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _section(
              icon: Icons.settings_outlined,
              title: 'Konfiguration',
              child: _configBody(),
            ),
            _section(
              icon: Icons.tune,
              title: 'Kalibrierung',
              child: _calibBody(),
            ),
            _section(
              icon: Icons.water_drop_outlined,
              title: 'Tankform',
              child: _tankFormBody(),
            ),
            _section(
              icon: Icons.bluetooth,
              title: 'Modul',
              child: _moduleBody(),
            ),
            _section(
              icon: Icons.article_outlined,
              title: 'Log',
              child: _logBody(),
            ),
          ],
        ),
      ),
    );
  }

  /// Schmale Leiste oben in den Einstellungen: Füllstand (% / L) + Empfang.
  Widget _settingsStatusStrip() {
    final cs = Theme.of(context).colorScheme;
    final s = c.status;
    String txt;
    if (c.bootloaderMode) {
      txt = 'Bootloader-Modus';
    } else if (s?.level != null) {
      final lvl = s!.level!;
      final liters = s.capacity != null
          ? ' · ${(lvl * s.capacity! / 100).toStringAsFixed(0)} L'
          : '';
      txt = '${lvl.toStringAsFixed(1)} %$liters';
    } else {
      txt = '–';
    }
    return Container(
      height: 30,
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.water_drop, size: 15, color: cs.primary),
          const SizedBox(width: 6),
          Text(txt,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600)),
          const Spacer(),
          _signalIndicator(showDbm: false),
        ],
      ),
    );
  }

  Color _levelColor(double v) {
    if (v < 20) return const Color(0xFFE53935);
    if (v < 50) return const Color(0xFFFB8C00);
    return const Color(0xFF43A047);
  }

  /// RSSI -> Anzahl leuchtender Balken (0..5).
  int _signalLit(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -55) return 5;
    if (rssi >= -65) return 4;
    if (rssi >= -75) return 3;
    if (rssi >= -85) return 2;
    return 1;
  }

  /// Empfangsqualität als 5-Balken-Symbol (+ optional dBm).
  Widget _signalIndicator({bool showDbm = true}) {
    final rssi = c.rssi;
    final lit = _signalLit(rssi);
    final color = lit >= 4
        ? const Color(0xFF43A047)
        : lit >= 2
            ? const Color(0xFFFB8C00)
            : const Color(0xFFE53935);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SignalBars(lit: lit, color: color),
        if (showDbm) ...[
          const SizedBox(width: 6),
          Text(rssi != null ? '$rssi dBm' : '–',
              style:
                  TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
        ],
      ],
    );
  }

  bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Widget _levelCard() {
    final s = c.status;
    final level = (s?.level ?? 0).clamp(0.0, 100.0);
    final color = _levelColor(level.toDouble());
    final cs = Theme.of(context).colorScheme;
    final calibrated = s?.calibrated == true;
    final tankform = c.linCurve != null &&
        !_listEq(c.linCurve!, List.generate(11, (i) => i * 10));
    return Card(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                _miniBadge(Icons.verified, 'Kalibriert', calibrated),
                const SizedBox(width: 12),
                _miniBadge(Icons.timeline, 'Tankform', tankform),
                const Spacer(),
                _signalIndicator(),
              ],
            ),
            Text(
              s?.level != null ? '${s!.level!.toStringAsFixed(1)} %' : '– %',
              style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            if (s != null && s.level != null && s.capacity != null) ...[
              Text(
                '≈ ${(s.level! * s.capacity! / 100).toStringAsFixed(0)} L',
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurfaceVariant),
              ),
              Text(
                'von ${s.capacity} L Tankvolumen',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LinearProgressIndicator(
                value: level / 100,
                minHeight: 22,
                backgroundColor: cs.surface,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat(Icon(Icons.thermostat, size: 22, color: cs.primary),
                    s?.temp != null ? '${s!.temp!.toStringAsFixed(1)} °C' : '–'),
                _stat(Icon(Icons.opacity, size: 22, color: cs.primary),
                    fluidNames[s?.fluidType] ?? '–'),
                _stat(TankGlyph(size: 22, color: cs.primary),
                    s?.capacity != null ? '${s!.capacity} L' : '–'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(Widget icon, String text) {
    return Column(
      children: [
        SizedBox(height: 22, child: icon),
        const SizedBox(height: 4),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w500)),
      ],
    );
  }

  /// Kleines Status-Symbol (aktiv = farbig, sonst ausgegraut).
  Widget _miniBadge(IconData icon, String label, bool active) {
    final col = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).disabledColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: col),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontSize: 11, color: col, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [child],
      ),
    );
  }

  Widget _configBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Fluidtyp'),
            const Spacer(),
            DropdownButton<int>(
              value: _fluidSel,
              items: fluidNames.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _fluidSel = v ?? 1),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => _send('FLUID $_fluidSel'),
              child: const Text('Senden'),
            ),
          ],
        ),
        _fieldRow(_capCtrl, 'Kapazität (L)',
            () => _send('CAP ${_capCtrl.text.trim()}')),
        _fieldRow(_instCtrl, 'Instanz (0..15)',
            () => _send('INST ${_instCtrl.text.trim()}')),
      ],
    );
  }

  Widget _fieldRow(
      TextEditingController ctrl, String label, VoidCallback onSend) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(onPressed: onSend, child: const Text('Senden')),
        ],
      ),
    );
  }

  Widget _calibBody() {
    final calibrated = c.status?.calibrated == true;
    final okColor = const Color(0xFF43A047);
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: (calibrated ? okColor : hint).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(calibrated ? Icons.check_circle : Icons.info_outline,
                  size: 18, color: calibrated ? okColor : hint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  calibrated
                      ? 'Sensor ist auf 100 % kalibriert.'
                      : 'Nicht kalibriert – es gilt der Werkswert.',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: calibrated ? okColor : hint),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text('Tank vollständig füllen, dann »Als 100 % setzen«.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: () => _send('CAL100'),
              child: const Text('Als 100 % setzen'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _send('CALRESET'),
              child: const Text('Zurücksetzen'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tankFormBody() {
    final cap = c.status?.capacity;
    final cs = Theme.of(context).colorScheme;
    final identity = List.generate(11, (i) => i * 10);
    final curve = c.linCurve;
    final isCustom = curve != null && !_listEq(curve, identity);
    final statusText = curve == null
        ? 'unbekannt – auf „Auslesen" tippen'
        : (isCustom ? 'angepasst (Tankform aktiv)' : 'Standard (linear)');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(isCustom ? Icons.tune : Icons.timeline,
                size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Kennlinie: $statusText',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.show_chart),
              tooltip: 'Als Graph anzeigen',
              onPressed: curve == null ? null : () => _showCurveGraph(curve),
            ),
            TextButton(
                onPressed: () => _send('LIN'), child: const Text('Auslesen')),
          ],
        ),
        if (curve != null)
          Text('Werte (Vol.-% je 10 % Höhe): ${curve.join(", ")}',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const Divider(height: 20),
        Text(
          cap != null
              ? 'Tank leeren, dann Zeile für Zeile die angegebene Menge einfüllen '
                  'und nach jedem Schritt »Übernehmen« tippen.'
              : 'Erst die Kapazität setzen (oben), dann die Tankform einmessen.',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.straighten, size: 18),
          label: const Text('Messung vorbereiten'),
          onPressed: () => _sendLin(List.generate(11, (i) => i * 10)),
        ),
        const SizedBox(height: 4),
        const Text(
            'setzt die Kennlinie auf linear – der Sensor zeigt dann die rohe Höhe',
            style: TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 8),
        ...List.generate(11, (i) => _tankRow(i, cap)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            icon: const Icon(Icons.upload, size: 18),
            label: const Text('Kennlinie berechnen & senden'),
            onPressed: _sendTankForm,
          ),
        ),
      ],
    );
  }

  Widget _tankRow(int i, int? cap) {
    String fill;
    if (cap == null) {
      fill = '${i * 10}% Volumen';
    } else if (i == 0) {
      fill = 'Tank leeren';
    } else {
      final step = cap / 10;
      final total = cap * i / 10;
      fill = '+${step.toStringAsFixed(1)} L  (∑ ${total.toStringAsFixed(1)} L)';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text('${i * 10}%',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(fill, style: const TextStyle(fontSize: 13))),
          SizedBox(
            width: 60,
            child: TextField(
              controller: _heightCtrls[i],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '%',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Aktuellen Füllstand übernehmen',
            icon: const Icon(Icons.download),
            onPressed: () => _captureHeight(i),
          ),
        ],
      ),
    );
  }

  Widget _moduleBody() {
    final cs = Theme.of(context).colorScheme;
    final fw = c.status?.version;
    final hw = c.status?.hwRev;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.memory, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Text('Firmware-Version: ${fw ?? '–'}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.developer_board, size: 18, color: cs.primary),
            const SizedBox(width: 6),
            Text('HW-Revision: ${hw ?? '–'}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        if (c.updateAvailable) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.system_update,
                    size: 18, color: cs.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Update verfügbar: V${c.latestVersion ?? ''} '
                    '– unten „Aus GitHub-Releases".',
                    style: TextStyle(
                        color: cs.onPrimaryContainer, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ],
        const Divider(height: 24),
        const Text(
          'Der Name wird im Sensor gespeichert und erscheint als Bluetooth-Name '
          'und in der NMEA2000-Geräteliste (Plotter). Nach dem Ändern startet '
          'das Modul neu und die Verbindung trennt sich – danach neu verbinden.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        if (c.sensorName != null &&
            c.sensorName!.isNotEmpty &&
            c.sensorName != c.displayName) ...[
          const SizedBox(height: 6),
          Text(
            'Hinweis: Bluetooth-Name („${c.displayName}") weicht vom gespeicherten '
            'Namen ab (z. B. vom Plotter geändert). Einmal „Ändern" tippen, '
            'um beide anzugleichen.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.tertiary, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                focusNode: _nameFocus,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: 'Sensorname',
                  border: OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _changeName, child: const Text('Ändern')),
          ],
        ),
        const Divider(height: 24),
        // --- Bluetooth-PIN ---
        const Text('Bluetooth-PIN',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Schützt die Bluetooth-Verbindung: Beim ersten Koppeln fragt das '
          'Handy nach der 6-stelligen PIN (Werkseinstellung 123123). Nach '
          'einer Änderung müssen sich alle Geräte neu koppeln.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pinCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Neue PIN (6 Ziffern)',
                  border: OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: _changePin, child: const Text('PIN ändern')),
          ],
        ),
        const Divider(height: 24),
        const Text('Firmware-Update (OTA)',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Firmware über Bluetooth übertragen. Der Sensor startet dazu neu und '
          'ist währenddessen nicht messbereit.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),

        // --- Aus GitHub ---
        Row(
          children: [
            const Text('Aus GitHub-Releases',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: 'Verfügbare Versionen laden',
              icon: _fwLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _fwLoading ? null : _loadGithubFirmware,
            ),
          ],
        ),
        if (_fwError != null)
          Text(_fwError!,
              style: const TextStyle(color: Colors.red, fontSize: 12)),
        if (_fwAssets.isEmpty && !_fwLoading && _fwError == null)
          const Text('Noch nicht geladen – auf ↻ tippen.',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        if (_fwAssets.isNotEmpty)
          DropdownButton<FirmwareAsset>(
            isExpanded: true,
            value: _fwSel,
            hint: const Text('Version wählen'),
            items: _fwAssets
                .asMap()
                .entries
                .map((e) => DropdownMenuItem(
                      value: e.value,
                      child: Text(
                        e.key == 0
                            ? '${e.value.label}   ·   neueste'
                            : e.value.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _fwSel = v),
          ),
        if (_fwAssets.isNotEmpty) const SizedBox(height: 8),
        if (_fwAssets.isNotEmpty)
          FilledButton.icon(
            icon: const Icon(Icons.cloud_download, size: 18),
            label: const Text('Gewählte Version aktualisieren'),
            onPressed: _fwSel == null ? null : () => _updateFromGithub(_fwSel!),
          ),

        const Divider(height: 24),
        // --- Lokale Datei ---
        const Text('Lokale Datei',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('.bin-Datei wählen & aktualisieren'),
          onPressed: _startFirmwareUpdate,
        ),

        const Divider(height: 24),
        // --- Werksreset ---
        const Text('Werksreset',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Löscht Kalibrierung, Tankform, Konfiguration, Name und gespeicherte '
          'NMEA2000-Adresse. Der Sensor startet danach neu.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('Auf Werkszustand zurücksetzen…'),
          style: OutlinedButton.styleFrom(
            foregroundColor: cs.error,
            side: BorderSide(color: cs.error),
          ),
          onPressed: _confirmFactoryReset,
        ),
      ],
    );
  }

  /// Verfügbare Firmware-Versionen aus den GitHub-Releases laden.
  Future<void> _loadGithubFirmware() async {
    setState(() {
      _fwLoading = true;
      _fwError = null;
    });
    try {
      final assets = await _fwRepo.fetchBinAssets();
      widget.registry.fwAssets = assets; // für andere Seiten mitverwenden
      setState(() {
        _fwAssets = assets;
        _fwSel = assets.isNotEmpty ? assets.first : null;
        if (assets.isEmpty) _fwError = 'Keine .bin in den Releases gefunden.';
      });
    } catch (e) {
      setState(() {
        _fwAssets = [];
        _fwSel = null;
        _fwError = 'Laden fehlgeschlagen: $e';
      });
    } finally {
      if (mounted) setState(() => _fwLoading = false);
    }
  }

  /// Gewählte Firmware herunterladen und das Update starten.
  Future<void> _updateFromGithub(FirmwareAsset a) async {
    if (c.device == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Lade Firmware …')),
        ]),
      ),
    );
    Uint8List fw;
    try {
      fw = await GithubReleases.download(a.url);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Download fehlgeschlagen: $e')));
      }
      return;
    }
    if (mounted) Navigator.pop(context); // Lade-Dialog schließen
    await _runFirmwareUpdate(fw, a.assetName);
  }

  // Bildschirm während des OTA anlassen (Method-Channel zur MainActivity,
  // kein Zusatz-Plugin). Auf iOS/ohne Handler einfach wirkungslos.
  static const MethodChannel _screenChannel = MethodChannel('app/screen');
  Future<void> _keepScreenOn(bool on) async {
    try {
      await _screenChannel.invokeMethod(on ? 'keepOn' : 'allowOff');
    } catch (_) {}
  }

  Future<void> _startFirmwareUpdate() async {
    if (c.device == null) return;
    final result = await FilePicker.platform.pickFiles(
        withData: true, type: FileType.custom, allowedExtensions: const ['bin']);
    if (result == null || result.files.single.bytes == null) return;
    await _runFirmwareUpdate(
        result.files.single.bytes!, result.files.single.name);
  }

  /// Gemeinsamer Update-Ablauf für lokale Datei und GitHub-Download.
  Future<void> _runFirmwareUpdate(Uint8List fw, String name) async {
    if (c.device == null) return;

    // Es darf nur EIN OTA-Update gleichzeitig laufen (Mehrsensor-Betrieb).
    final activeDfu = widget.registry.dfuActive;
    if (activeDfu != null && activeDfu != c) {
      _snack('Es läuft bereits ein Firmware-Update auf einem anderen Sensor.');
      return;
    }

    // Plausibilitätsprüfung: falsche Dateien (z. B. die Bootloader-.bin oder
    // eine beliebige Fremddatei) gar nicht erst übertragen – der Bootloader
    // prüft nur die Transfer-CRC, nicht den Inhalt.
    final imgErr = validateAppImage(fw);
    if (imgErr != null) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Ungültige Firmware-Datei'),
            content: Text('$name\n\n$imgErr'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Firmware-Update'),
        content: Text('Datei: $name\nGröße: ${fw.length} Byte\n\n'
            'Der Sensor startet neu und ist während des Updates nicht '
            'messbereit. Fortfahren?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Update starten')),
        ],
      ),
    );
    if (confirm != true) return;

    final status = ValueNotifier<String>('Start …');
    final progress = ValueNotifier<double>(0);
    final blVersion = ValueNotifier<String?>(null);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Firmware-Update'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, v, __) => Text(v, textAlign: TextAlign.center)),
              const SizedBox(height: 14),
              ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, v, __) =>
                      LinearProgressIndicator(value: v > 0 ? v : null)),
              ValueListenableBuilder<String?>(
                valueListenable: blVersion,
                builder: (_, v, __) => v == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('Bootloader v$v',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                      ),
              ),
            ],
          ),
        ),
      ),
    );

    String? error;
    widget.registry.dfuActive = c; // Auto-Reconnect + weitere OTAs sperren
    c.dfuRunning = true;
    await _keepScreenOn(true); // Display während des Updates anlassen
    try {
      await DfuTransfer(
        ble: c.ble,
        device: c.device!,
        firmware: fw,
        onProgress: (s, p) {
          status.value = s;
          progress.value = p;
        },
        onBootloaderVersion: (v) => blVersion.value = v,
      ).run();
    } catch (e) {
      error = '$e';
    } finally {
      await _keepScreenOn(false);
      c.dfuRunning = false;
      widget.registry.dfuActive = null;
      // Der DFU hat die Verbindung selbst verwaltet -> Auftrag neu aufsetzen,
      // damit der Sensor nach seinem Neustart automatisch wiederkommt.
      c.kickReconnect();
    }

    if (mounted) Navigator.pop(context); // Fortschrittsdialog schließen
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title:
              Text(error == null ? 'Update erfolgreich' : 'Update fehlgeschlagen'),
          content: Text(error == null
              ? 'Die neue Firmware wurde übertragen. Der Sensor startet neu '
                  'und wird automatisch wieder verbunden.'
              : 'Fehler: $error\n\nDer Sensor bleibt im Bootloader (weißes '
                  'Blinken); das Update kann erneut gestartet werden.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
    }
    status.dispose();
    progress.dispose();
    blVersion.dispose();
  }

  Widget _logBody() {
    if (c.log.isEmpty) {
      return const Text('–', style: TextStyle(color: Colors.grey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: c.log
          .take(12)
          .map((m) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(m,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
              ))
          .toList(),
    );
  }
}

/// Zeichnet die Korrekturlinie: X = Füllhöhe %, Y = Volumen %.
/// Graue Diagonale = linear (ohne Korrektur), farbige Linie = aktuelle Kennlinie.
class _LinChartPainter extends CustomPainter {
  final List<int> pts; // 11 Werte (0..100)
  final Color color;
  _LinChartPainter(this.pts, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 10.0;
    final rect = Rect.fromLTRB(pad, pad, size.width - pad, size.height - pad);

    Offset at(double hx, double vy) => Offset(
          rect.left + rect.width * hx / 100,
          rect.bottom - rect.height * vy / 100,
        );

    // Gitter (25 %)
    final grid = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 0.5;
    for (var g = 0; g <= 4; g++) {
      final x = rect.left + rect.width * g / 4;
      final y = rect.bottom - rect.height * g / 4;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
    // Rahmen / Achsen
    final axis = Paint()
      ..color = const Color(0xFF9E9E9E)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, axis);

    // Lineare Vergleichslinie (gestrichelt grau)
    final ref = Paint()
      ..color = const Color(0xFFBDBDBD)
      ..strokeWidth = 1;
    _dash(canvas, at(0, 0), at(100, 100), ref);

    // Kennlinie
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = at(i * 10.0, pts[i].toDouble());
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, line);
    final dot = Paint()..color = color;
    for (var i = 0; i < pts.length; i++) {
      canvas.drawCircle(at(i * 10.0, pts[i].toDouble()), 2.5, dot);
    }
  }

  void _dash(Canvas c, Offset a, Offset b, Paint p,
      {double dash = 5, double gap = 3}) {
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final e = (d + dash) < total ? d + dash : total;
      c.drawLine(a + dir * d, a + dir * e, p);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _LinChartPainter old) =>
      old.pts != pts || old.color != color;
}

/// Empfangs-Anzeige: 5 Balken, davon [lit] gefüllt (leere sichtbar grau).
class _SignalBars extends StatelessWidget {
  final int lit; // 0..5
  final Color color;
  final double height;
  const _SignalBars({required this.lit, required this.color, this.height = 16});

  @override
  Widget build(BuildContext context) {
    const empty = Color(0x33888888);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(5, (i) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Container(
            width: 4,
            height: height * (0.4 + 0.15 * i),
            decoration: BoxDecoration(
              color: i < lit ? color : empty,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        );
      }),
    );
  }
}

/// Kleines Wassertank-Symbol (Behälter mit Wasserlinie), gezeichnet statt Icon.
class TankGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const TankGlyph({super.key, this.size = 22, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _TankPainter(color));
  }
}

class _TankPainter extends CustomPainter {
  final Color color;
  _TankPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.18, h * 0.10, w * 0.64, h * 0.80),
      Radius.circular(w * 0.14),
    );

    // Wasserfüllung (untere ~55 %) mit Welle, in den Tank geclippt
    canvas.save();
    canvas.clipRRect(body);
    final waterTop = h * 0.45;
    final water = Path()
      ..moveTo(0, waterTop)
      ..cubicTo(w * 0.30, waterTop - h * 0.07, w * 0.55, waterTop + h * 0.07,
          w * 0.75, waterTop)
      ..cubicTo(w * 0.85, waterTop - h * 0.04, w * 0.95, waterTop + h * 0.02, w,
          waterTop)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(water, Paint()..color = color.withValues(alpha: 0.35));
    canvas.restore();

    // Tank-Umriss
    canvas.drawRRect(
      body,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.08
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TankPainter oldDelegate) =>
      oldDelegate.color != color;
}
