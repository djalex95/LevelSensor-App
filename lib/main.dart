import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_service.dart';
import 'dfu.dart';
import 'protocol.dart';

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
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ProteusBle _ble = ProteusBle();

  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  bool _connected = false;
  String _deviceName = '';
  BluetoothDevice? _device;
  SensorStatus? _status;
  final List<String> _log = [];

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _showSettings = false;
  bool _autoConnecting = false;

  // Merker für den zuletzt verbundenen Sensor (SharedPreferences).
  static const _prefLastId = 'last_device_id';
  static const _prefLastName = 'last_device_name';

  int _fluidSel = 1;
  final TextEditingController _capCtrl = TextEditingController();
  final TextEditingController _instCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  bool _configInit = false;

  // Gemessene Füllhöhe (%) je Schritt für den Tankform-Assistenten
  final List<TextEditingController> _heightCtrls =
      List.generate(11, (_) => TextEditingController());

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _subs.add(_ble.lines.listen(_onLine));
    _subs.add(_ble.connected.listen((c) => setState(() {
          _connected = c;
          if (!c) _showSettings = false; // bei Trennung zurück zur Startseite
        })));
    _subs.add(FlutterBluePlus.scanResults
        .listen((r) => setState(() => _scanResults = r)));
    _subs.add(FlutterBluePlus.isScanning
        .listen((s) => setState(() => _isScanning = s)));
    _init();
  }

  Future<void> _init() async {
    await _requestPermissions();
    await _tryAutoConnect();
  }

  /// Beim Start versuchen, sich mit dem zuletzt verbundenen Sensor zu verbinden.
  Future<void> _tryAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_prefLastId);
    if (id == null || id.isEmpty) return;
    final name = prefs.getString(_prefLastName) ?? '';
    setState(() => _autoConnecting = true);
    try {
      final device = BluetoothDevice.fromId(id);
      _addLog('Verbinde automatisch mit ${name.isNotEmpty ? name : id}…');
      await _connect(device, fallbackName: name);
    } catch (e) {
      _addLog('Auto-Verbinden fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _autoConnecting = false);
    }
  }

  Future<void> _saveLastDevice(BluetoothDevice device, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLastId, device.remoteId.str);
    await prefs.setString(_prefLastName, name);
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

  void _onLine(String line) {
    final st = SensorStatus.parse(line);
    if (st != null) {
      setState(() {
        _status = st;
        if (!_configInit) {
          _fluidSel = fluidNames.containsKey(st.fluidType) ? st.fluidType! : 1;
          _capCtrl.text = (st.capacity ?? 0).toString();
          _instCtrl.text = (st.instance ?? 0).toString();
          _configInit = true;
        }
      });
      return;
    }
    final lin = parseLin(line);
    if (lin != null) {
      _addLog('Kennlinie: ${lin.join(",")}');
      return;
    }
    _addLog(line);
  }

  void _addLog(String msg) {
    setState(() {
      _log.insert(0, msg);
      if (_log.length > 40) _log.removeLast();
    });
  }

  Future<void> _startScan() async {
    await _requestPermissions();
    _scanResults = [];
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      _addLog('Scan-Fehler: $e');
    }
  }

  Future<void> _connect(BluetoothDevice device, {String? fallbackName}) async {
    await FlutterBluePlus.stopScan();
    try {
      await _ble.connect(device);
      _device = device;
      _configInit = false;
      final pn = device.platformName;
      _deviceName = pn.isNotEmpty
          ? pn
          : (fallbackName != null && fallbackName.isNotEmpty
              ? fallbackName
              : device.remoteId.str);
      _nameCtrl.text = _deviceName;
      _addLog('Verbunden mit $_deviceName');
      await _saveLastDevice(device, _deviceName); // Sensor merken
    } catch (e) {
      _addLog('Verbindung fehlgeschlagen: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verbindung fehlgeschlagen: $e')));
      }
    }
  }

  Future<void> _send(String cmd) async {
    _addLog('> $cmd');
    try {
      await _ble.send(cmd);
    } catch (e) {
      _addLog('Sendefehler: $e');
    }
  }

  void _changeName() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    _send('NAME $name');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Name gesendet. Das Modul startet neu – bitte danach neu verbinden.'),
      ));
    }
  }

  void _captureHeight(int i) {
    final lvl = _status?.level;
    if (lvl == null) {
      _addLog('Noch kein Füllstand empfangen');
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

  void _sendTankForm() {
    try {
      final heights = _heightCtrls.map((c) {
        final v = double.tryParse(c.text.trim().replaceAll(',', '.'));
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
      _send(buildLinCommand(_resampleToHeightGrid(heights)));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _ble.dispose();
    _capCtrl.dispose();
    _instCtrl.dispose();
    _nameCtrl.dispose();
    for (final c in _heightCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _showSettings ? _buildSettingsScaffold() : _buildHomeScaffold();
  }

  // ---------------- Startseite (Live-Anzeige) ----------------

  Widget _buildHomeScaffold() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(_connected ? _deviceName : 'Füllstandsensor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Einstellungen',
            onPressed:
                _connected ? () => setState(() => _showSettings = true) : null,
          ),
        ],
      ),
      drawer: _buildDeviceDrawer(),
      body: _connected ? _buildHomeBody() : _buildDisconnectedHint(),
    );
  }

  Widget _buildHomeBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [_levelCard()],
    );
  }

  Widget _buildDisconnectedHint() {
    final hint = Theme.of(context).hintColor;
    if (_autoConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Verbinde mit letztem Sensor…',
                style: TextStyle(color: hint)),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bluetooth_disabled, size: 48, color: hint),
            const SizedBox(height: 12),
            Text('Kein Gerät verbunden',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Öffne links das Menü und wähle deinen Sensor.',
                textAlign: TextAlign.center, style: TextStyle(color: hint)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.menu),
              label: const Text('Geräte-Menü öffnen'),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Geräte-Menü (Drawer) ----------------

  Widget _buildDeviceDrawer() {
    final devices =
        _scanResults.where((r) => r.device.platformName.isNotEmpty).toList();
    final cs = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child:
                  Text('Geräte', style: Theme.of(context).textTheme.titleLarge),
            ),
            if (_connected)
              ListTile(
                leading: CircleAvatar(
                    backgroundColor: cs.primaryContainer,
                    child: const Icon(Icons.sensors)),
                title: Text(_deviceName),
                subtitle: const Text('verbunden'),
                trailing: IconButton(
                  icon: const Icon(Icons.link_off),
                  tooltip: 'Trennen',
                  onPressed: () => _ble.disconnect(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                icon: Icon(_isScanning
                    ? Icons.hourglass_top
                    : Icons.bluetooth_searching),
                label: Text(_isScanning ? 'Suche läuft…' : 'Nach Sensor suchen'),
                onPressed: _isScanning ? null : _startScan,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Text(
                          _isScanning ? 'Suche…' : 'Keine Geräte gefunden',
                          style: TextStyle(color: hint)))
                  : ListView(
                      children: devices
                          .map((r) => ListTile(
                                leading: const Icon(Icons.sensors),
                                title: Text(r.device.platformName),
                                subtitle: Text(r.device.remoteId.str),
                                trailing: Text('${r.rssi} dBm'),
                                onTap: () {
                                  Navigator.of(context).pop();
                                  _connect(r.device);
                                },
                              ))
                          .toList(),
                    ),
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
          title: const Text('Einstellungen'),
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

  Color _levelColor(double v) {
    if (v < 20) return const Color(0xFFE53935);
    if (v < 50) return const Color(0xFFFB8C00);
    return const Color(0xFF43A047);
  }

  Widget _levelCard() {
    final s = _status;
    final level = (s?.level ?? 0).clamp(0.0, 100.0);
    final color = _levelColor(level.toDouble());
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              s?.level != null ? '${s!.level!.toStringAsFixed(1)} %' : '– %',
              style: TextStyle(
                fontSize: 52,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
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

  Widget _fieldRow(TextEditingController ctrl, String label, VoidCallback onSend) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
    final cap = _status?.capacity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          onPressed: () =>
              _send(buildLinCommand(List.generate(11, (i) => i * 10))),
        ),
        const SizedBox(height: 4),
        const Text('setzt die Kennlinie auf linear – der Sensor zeigt dann die rohe Höhe',
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
      fill = '+${step.toStringAsFixed(1)} L  (∑ ${total.toStringAsFixed(0)} L)';
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
                contentPadding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
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
    final fw = _status?.version;
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
        const Divider(height: 24),
        const Text(
          'Der Name wird dauerhaft im Modul gespeichert. Nach dem Ändern startet '
          'das Modul neu und die Verbindung trennt sich – danach neu verbinden.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: 'Modulname',
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
        const Text('Firmware-Update (OTA)',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Neue Firmware (.bin) auswählen und über Bluetooth übertragen. Der '
          'Sensor startet dazu neu und ist währenddessen nicht messbereit.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.system_update, size: 18),
          label: const Text('Firmware-Datei wählen & aktualisieren'),
          onPressed: _startFirmwareUpdate,
        ),
      ],
    );
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
    if (_device == null) return;
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.single.bytes == null) return;
    final fw = result.files.single.bytes!;
    final name = result.files.single.name;

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
            ],
          ),
        ),
      ),
    );

    String? error;
    await _keepScreenOn(true); // Display während des Updates anlassen
    try {
      await DfuTransfer(
        ble: _ble,
        device: _device!,
        firmware: fw,
        onProgress: (s, p) {
          status.value = s;
          progress.value = p;
        },
      ).run();
    } catch (e) {
      error = '$e';
    } finally {
      await _keepScreenOn(false);
    }

    if (mounted) Navigator.pop(context); // Fortschrittsdialog schließen
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(error == null ? 'Update erfolgreich' : 'Update fehlgeschlagen'),
          content: Text(error == null
              ? 'Die neue Firmware wurde übertragen. Der Sensor startet neu – '
                  'bitte anschließend neu verbinden.'
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
  }

  Widget _logBody() {
    if (_log.isEmpty) {
      return const Text('–', style: TextStyle(color: Colors.grey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _log
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
