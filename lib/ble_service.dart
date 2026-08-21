import 'dart:async';
import 'dart:io' show Platform;
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'debug_log.dart';

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
  /* Nur fuers Protokoll: jeder Wechsel des Systembonds wird
   * mitgeschrieben. Genau hier faellt auf, wenn ein Bond
   * verschwindet, ohne dass jemand danach gefragt hat. */
  StreamSubscription<BluetoothBondState>? _bondSub;
  String _buffer = '';
  bool _autoMode = false; // OS-autoConnect aktiv (schnelleres Wiederverbinden)

  /// Stream vollständiger empfangener Textzeilen (ohne Zeilenende).
  Stream<String> get lines => _lineController.stream;

  /// true, sobald verbunden und die Charakteristiken gefunden sind.
  Stream<bool> get connected => _connectedController.stream;

  bool get isConnected => _rx != null && _tx != null;

  /// Verdacht auf eine veraltete Kopplung: so oft hintereinander stand die
  /// Funkverbindung, ohne dass die Einrichtung durchlief. Genau dieses
  /// Muster erzeugt der klassische Fehlerfall der PIN-Sicherheit - das Handy
  /// hat noch einen Bond, das Modul kennt ihn nicht mehr (nach PIN-Wechsel
  /// oder Werksreset), die Verschlüsselung scheitert. Ein Sensor ausser
  /// Reichweite zaehlt hier nicht mit, dort kommt gar keine Verbindung
  /// zustande.
  ///
  /// Die App loescht deswegen von sich aus nichts mehr. Sie zaehlt nur, und
  /// die Oberflaeche fragt den Nutzer, sobald der Verdacht dicht genug ist.
  int staleBondStreak = 0;

  /// Beginn der laufenden Fehlerserie.
  DateTime? _staleSince;

  /// Ab hier wird der Nutzer gefragt.
  ///
  /// Zwei Bedingungen, und die zweite ist die wichtigere. Android wirft im
  /// Betrieb regelmaessig GATT_ERROR (133) oder GATT_INTERNAL_ERROR (129)
  /// beim Einrichten - das sieht genauso aus wie eine veraltete Kopplung,
  /// erledigt sich aber im naechsten Anlauf von selbst. Eine wirklich tote
  /// Kopplung erledigt sich nie. Deshalb muss die Serie nicht nur lang
  /// genug sein, sondern auch lange genug andauern; ein Erfolg dazwischen
  /// setzt beides zurueck.
  static const int _staleMinFails = 5;
  static const Duration _staleMinAge = Duration(minutes: 2);

  bool get staleBondSuspect =>
      staleBondStreak >= _staleMinFails &&
      _staleSince != null &&
      DateTime.now().difference(_staleSince!) >= _staleMinAge;

  /// Stand in DIESEM Verbindungsversuch schon einmal eine Funkverbindung?
  bool _linkSeenThisAttempt = false;

  /// Nur fuers Protokoll: erst wenn wirklich einmal eine Verbindung stand,
  /// ist ein 'getrennt' eine Nachricht. Der Zustandsstrom meldet beim
  /// Abonnieren sofort den aktuellen Stand - ohne diese Bremse stuenden im
  /// Protokoll vor jedem Verbindungsversuch zwei sinnlose Trennungen.
  bool _wasConnected = false;

  /// Verbindet mit [device]. Ab Firmware 2.0.0 ist die Schnittstelle mit
  /// Static-Passkey-Pairing gesichert: Android zeigt beim Aktivieren der
  /// Notifications automatisch den PIN-Dialog (das Bonding stößt der
  /// BLE-Stack selbst an - deshalb wird hier weiterhin KEIN createBond
  /// erzwungen, das schlug bei Geräten ohne Sicherheit fehl). Bei älterer
  /// Firmware ohne Verschlüsselung ändert sich nichts.
  ///
  /// [autoConnect] = true: OS-gestützter autoConnect – kehrt sofort zurück,
  /// das Betriebssystem verbindet, sobald der Sensor erscheint (schnelleres
  /// Wiederverbinden). Einrichtung folgt im State-Listener.
  /// [autoConnect] = false (Standard): direkter Versuch mit Timeout.
  Future<void> connect(BluetoothDevice device,
      {bool autoConnect = false}) async {
    _device = device;
    _autoMode = autoConnect;
    _linkSeenThisAttempt = false;
    DebugLog.add('Verbinden mit ${device.remoteId} '
        '(autoConnect: $autoConnect)');

    /* evtl. alte Subscriptions lösen (z. B. beim Neuverbinden im DFU) */
    await _stateSub?.cancel();
    await _notifySub?.cancel();
    await _bondSub?.cancel();
    _bondSub = null;
    _buffer = '';

    if (Platform.isAndroid) {
      _bondSub = device.bondState.listen(
          (st) => DebugLog.add('Systembond: ${st.name}'),
          onError: (Object e) => DebugLog.add('Systembond-Fehler: $e'));
    }

    _stateSub = device.connectionState.listen((state) async {
      if (state == BluetoothConnectionState.connected) {
        _wasConnected = true;
        _linkSeenThisAttempt = true;
        // Beim OS-autoConnect steht die Verbindung asynchron -> hier einrichten.
        if (_autoMode && !isConnected) {
          try {
            await _setup(device);
            _clearStaleSuspicion();
            DebugLog.add('Verbunden und eingerichtet (autoConnect)');
            _connectedController.add(true);
          } catch (e) {
            DebugLog.add('Einrichtung nach autoConnect fehlgeschlagen: $e');
            /* Einrichtung fehlgeschlagen - zweiter Anlauf (Pairing abwarten
             * bzw. alten Systembond löschen). Klappt auch der nicht, verbindet
             * das OS gleich von selbst erneut. */
            try {
              if (await _recover(device)) {
                _clearStaleSuspicion();
                DebugLog.add('Zweiter Anlauf erfolgreich (autoConnect)');
                _connectedController.add(true);
              } else {
                await _noteFailedAttempt(device);
              }
            } catch (_) {}
          }
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        if (_wasConnected) {
          /* Der Grund unterscheidet die Faelle, auf die es ankommt: vom
           * Sensor beendet, Funkstrecke weg oder Verschluesselung
           * gescheitert sehen im Protokoll sonst gleich aus. */
          final r = device.disconnectReason;
          DebugLog.add('Verbindung getrennt'
              '${r == null ? '' : ' (Grund ${r.code}: ${r.description})'}');
          _wasConnected = false;
        }
        _cleanup();
        _connectedController.add(false);
      }
    });

    if (autoConnect) {
      await device.connect(autoConnect: true, mtu: null);
      return; // Einrichtung folgt im State-Listener, sobald verbunden
    }

    try {
      /* mtu: null -> die MTU fordert _setup selbst an (dort abgesichert).
       * Sonst macht flutter_blue_plus das intern noch in connect(), und ein
       * Abbruch dabei lässt connect() werfen, bevor _setup überhaupt
       * läuft - dann greift auch der zweite Anlauf nicht. */
      await device.connect(timeout: const Duration(seconds: 15), mtu: null);
      await _setup(device);
    } catch (e) {
      DebugLog.add('Verbindungsaufbau fehlgeschlagen: $e');
      if (!await _recover(device)) {
        await _noteFailedAttempt(device);
        rethrow;
      }
      DebugLog.add('Zweiter Anlauf erfolgreich');
    }
    _clearStaleSuspicion();
    DebugLog.add('Verbunden und eingerichtet');
    _connectedController.add(true);
  }

  /// Zweiter Anlauf, nachdem der Verbindungsaufbau fehlgeschlagen ist.
  ///
  /// Beim gesicherten Sensor ist der häufigste Grund eine gerade erst
  /// gestartete Kopplung – dann hilft nur warten, bis Android sie
  /// abgeschlossen hat. Bleibt es dabei, passt der gespeicherte Systembond
  /// vermutlich nicht mehr zum Modul (alte PIN, Werksreset). Geloescht wird
  /// er hier trotzdem nicht: das entscheidet der Nutzer, siehe
  /// [staleBondStreak].
  /// true = Sensor ist eingerichtet und benutzbar.
  Future<bool> _recover(BluetoothDevice device) async {
    return await _awaitBonded(device) && await _reconnectAndSetup(device);
  }

  /// Ein geglueckter Anlauf raeumt den Verdacht restlos ab.
  void _clearStaleSuspicion() {
    staleBondStreak = 0;
    _staleSince = null;
  }

  /// Nach einem endgueltig gescheiterten Versuch: war es das Muster einer
  /// veralteten Kopplung? Nur dann steigt der Verdachtszaehler.
  Future<void> _noteFailedAttempt(BluetoothDevice device) async {
    if (!Platform.isAndroid || !_linkSeenThisAttempt) {
      return; // gar keine Funkverbindung -> lag nicht an der Kopplung
    }
    try {
      if (await device.bondState.first != BluetoothBondState.bonded) {
        return; // ohne gespeicherte Kopplung gibt es nichts zu erneuern
      }
    } catch (_) {
      return;
    }
    _staleSince ??= DateTime.now();
    staleBondStreak++;
    DebugLog.add('Einrichtung gescheitert, obwohl die Funkverbindung stand - '
        'Verdacht auf veraltete Kopplung ($staleBondStreak in Folge)');
  }

  /// Verbindet bei Bedarf neu und richtet die Charakteristiken ein.
  /// Wirft nicht – false heißt nur "hat wieder nicht geklappt".
  Future<bool> _reconnectAndSetup(BluetoothDevice device) async {
    try {
      if (!device.isConnected) {
        if (_autoMode) {
          return false; // das Betriebssystem verbindet selbst erneut
        }
        await device.connect(
            timeout: const Duration(seconds: 20), mtu: null);
      }
      await _setup(device);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Wartet, bis Android eine laufende Kopplung abgeschlossen hat.
  ///
  /// Beim gesicherten Sensor stößt erst das Einschalten der Notifications
  /// (Schreibzugriff auf Descriptor 2902) das Pairing an. Android gibt genau
  /// diesen Schreibzugriff sofort als Fehler zurück (GATT_ERROR 133), während
  /// der PIN-Dialog gerade erst erscheint. Wer daraufhin abbricht, reißt die
  /// Verbindung weg, bevor der Nutzer die PIN eintippen kann – genau das war
  /// der Grund für die endlosen Kopplungsversuche.
  ///
  /// true = Gerät ist jetzt gekoppelt, ein zweiter Anlauf lohnt sich.
  Future<bool> _awaitBonded(BluetoothDevice device) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      if (await device.bondState.first == BluetoothBondState.bonded) {
        return true;
      }
    } catch (_) {}

    final done = Completer<bool>();
    var sawBonding = false;
    StreamSubscription<BluetoothBondState>? sub;
    Timer? idle;
    void finish(bool ok) {
      if (!done.isCompleted) {
        done.complete(ok);
      }
    }

    sub = device.bondState.listen((st) {
      if (st == BluetoothBondState.bonding) {
        sawBonding = true; // Nutzer tippt gerade die PIN
      } else if (st == BluetoothBondState.bonded) {
        finish(true);
      } else if (sawBonding) {
        finish(false); // abgebrochen oder falsche PIN
      }
    }, onError: (_) => finish(false));

    /* Läuft gar keine Kopplung, hatte der Fehler eine andere Ursache. */
    idle = Timer(const Duration(seconds: 3), () {
      if (!sawBonding) {
        finish(false);
      }
    });

    bool ok;
    try {
      ok = await done.future.timeout(const Duration(seconds: 60));
    } catch (_) {
      ok = false;
    }
    idle.cancel();
    await sub.cancel();

    if (ok) {
      /* Der Stack braucht nach dem Bonding einen Moment, bis die
       * verschlüsselte Verbindung wirklich benutzbar ist. */
      await Future.delayed(const Duration(milliseconds: 800));
    }
    return ok;
  }

  /// Löscht die Android-Kopplung zu diesem Sensor – nach PIN-Wechsel oder
  /// Werksreset passt der alte Bond nicht mehr zum Modul, und ohne Löschen
  /// scheitert der nächste Kopplungsversuch. Auf iOS nicht möglich (dort muss
  /// der Nutzer das Gerät in den Bluetooth-Einstellungen entfernen).
  /// true = Kopplung wurde entfernt.
  Future<bool> forgetBond() async {
    final device = _device;
    if (device == null || !Platform.isAndroid) {
      return false;
    }
    DebugLog.add('Systembond wird geloescht (PIN-Wechsel oder Werksreset)');
    try {
      await device.removeBond();
    } catch (e) {
      DebugLog.add('Systembond loeschen fehlgeschlagen: $e');
      return false;
    }
    _clearStaleSuspicion();
    return true;
  }

  /// Große MTU anfordern, Charakteristiken suchen, Notifications aktivieren.
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
    _bondSub?.cancel();
    _lineController.close();
    _connectedController.close();
  }
}
