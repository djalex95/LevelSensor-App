# Füllstandsensor-App (Flutter)

Handy-App für den NMEA2000-Füllstandsensor über das Würth-Proteus-e-BLE-Modul.
Bietet dieselben Funktionen wie das PC-Programm: Live-Füllstand und Temperatur,
Konfiguration (Fluidtyp, Kapazität, Instanz), 100%-Kalibrierung und die
Tankform-Kennlinie. Das verwendete Protokoll ist im Firmware-Repository
(`CAN_FuellstandsensorBLE`) unter `PC_Tools/BLE_Protokoll.md` beschrieben.

## Enthaltene Dateien

- `lib/protocol.dart` – Parsen/Erzeugen der Textnachrichten (STAT, LIN, Kommandos)
- `lib/ble_service.dart` – BLE-Anbindung an das Proteus-Modul (flutter_blue_plus)
- `lib/main.dart` – Oberfläche (Scan/Verbinden, Live-Anzeige, Konfig, Kalibrierung, Tankform)
- `pubspec.yaml` – Abhängigkeiten

## Einrichtung

Voraussetzung: Flutter SDK installiert (`flutter --version`).

Die Plattform-Ordner (android/, ios/ usw.) sind im Repository enthalten,
es ist kein `flutter create` nötig:

```bash
cd Fuellstandsensor-App

# 1) Abhängigkeiten holen
flutter pub get

# 2) Auf angeschlossenem Handy starten
flutter run --flavor github --dart-define=APP_CHANNEL=github
```

Der Flavor ist Pflicht, siehe naechster Abschnitt.

## Versionsnummern

Zwischen zwei Releases traegt `pubspec.yaml` die naechste Nummer mit
`-dev`, zum Beispiel `2.1.3-dev+31`. So ist auf dem Handy an der
Versionszeile sofort zu sehen, ob dort ein Zwischenstand oder ein Release
laeuft, und es werden keine Nummern fuer jeden Zwischenschritt verbraucht.

Zum Release wird das Suffix entfernt und die Nummer festgelegt - Fehler-
korrektur als Patch, neue Funktion als Minor. Erst danach wird getaggt.
Die Build-Nummer hinter dem Plus steigt bei jedem Stand, den ein Geraet zu
sehen bekommt; der Play Store nimmt jede nur einmal an.

Der Release-Workflow bricht ab, wenn zum Tag noch ein `-dev` in
`pubspec.yaml` steht.

## Build-Varianten

Die App wird in zwei Varianten gebaut. Inhaltlich sind sie identisch, sie
unterscheiden sich nur im In-App-Updater, der beim Start nach einer neueren
APK im GitHub-Release sucht und sie auf Wunsch installiert.

- `github` - APK fuer die GitHub-Releases, In-App-Updater aktiv.
  Bringt ueber `android/app/src/github/AndroidManifest.xml` die Berechtigung
  `REQUEST_INSTALL_PACKAGES` mit.
- `play` - AAB fuer den Google Play Store, In-App-Updater abgeschaltet und
  die Berechtigung nicht im Manifest. Play verbietet Apps, die sich am
  Store-Update-Mechanismus vorbei selbst aktualisieren; dort kommen
  App-Updates ueber den Store.

Das Firmware-Update des Sensors (`.bin` ueber BLE) ist davon nicht betroffen
und laeuft in beiden Varianten unveraendert.

Der Schalter im Dart-Code steht in `lib/build_config.dart`
(`BuildConfig.selfUpdate`). Weil er `const` ist, entfernt der Compiler den
Updater im Play-Build vollstaendig. Flavor und `--dart-define` muessen
zusammenpassen; `android/app/build.gradle.kts` bricht den Build sonst mit
einer Meldung ab.

```bash
# GitHub-Variante
flutter run --flavor github --dart-define=APP_CHANNEL=github
flutter build apk --release --flavor github --dart-define=APP_CHANNEL=github

# Play-Variante
flutter build appbundle --release --flavor play --dart-define=APP_CHANNEL=play
```

Der Release-Workflow (`.github/workflows/release.yml`) baut beim Tag beides:
die APK aus dem Flavor `github` und das AAB aus dem Flavor `play`.

## Berechtigungen

### Android — `android/app/src/main/AndroidManifest.xml`

Innerhalb von `<manifest>` (vor `<application>`) ergänzen:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- Für Android 11 und älter zusätzlich: -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"
    android:maxSdkVersion="30" />
```

Mindest-SDK in `android/app/build.gradle` auf 21 oder höher setzen
(`minSdkVersion 21`).

### iOS — `ios/Runner/Info.plist`

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Die App verbindet sich per Bluetooth mit dem Füllstandsensor.</string>
```

## Bedienung

1. „Nach Sensor suchen" → Gerät in der Liste antippen (Proteus-Modul, meist mit
   Namen „Proteus-e…"). Nach dem Verbinden erscheint das Dashboard.
2. Füllstand und Temperatur aktualisieren sich automatisch (ca. jede Sekunde).
3. Konfiguration ändern → jeweils „Senden". Werte werden dauerhaft gespeichert.
4. Kalibrierung: Tank voll → „Als 100 % setzen".
5. Tankform: „Lesen" holt die aktuelle Kennlinie, nach dem Bearbeiten
   „Kennlinie senden" (11 Werte 0..100, von links nach rechts steigend).

## Nächste Ausbaustufen (optional)

- Verlaufsgraph des Füllstands (Werte aus dem STAT-Stream puffern)
- Tankform-Assistent wie im PC-Tool („X Liter einfüllen → aktuellen Wert
  übernehmen"), inkl. Liter-Anzeige aus der Kapazität
- Automatisches Wiederverbinden, Anzeige des Verbindungsstatus

## Versionsnummern

Die Nummer hat drei Stellen, X.Y.Z, und jede Stelle hat eine feste Bedeutung:
**X** steigt bei einer größeren Änderung, **Y** wenn ein kleineres Feature
dazukommt, **Z** bei Bugfixes. Das gilt gleich in allen drei Repositories
(Firmware, Bootloader, App).

Die App zählt in `version:` in `pubspec.yaml`. Die Zahl hinter dem `+` ist der
Build-Zähler für die Stores und läuft unabhängig davon weiter. Freigegeben wird
über einen Tag `vX.Y.Z`; die CI bricht ab, wenn Tag und `pubspec.yaml` nicht
zusammenpassen.
