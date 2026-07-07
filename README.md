# Füllstandsensor-App (Flutter)

Handy-App für den NMEA2000-Füllstandsensor über das Würth-Proteus-e-BLE-Modul.
Bietet dieselben Funktionen wie das PC-Programm: Live-Füllstand und Temperatur,
Konfiguration (Fluidtyp, Kapazität, Instanz), 100%-Kalibrierung und die
Tankform-Kennlinie. Das verwendete Protokoll ist in
`../PC_Tools/BLE_Protokoll.md` beschrieben.

## Enthaltene Dateien

- `lib/protocol.dart` – Parsen/Erzeugen der Textnachrichten (STAT, LIN, Kommandos)
- `lib/ble_service.dart` – BLE-Anbindung an das Proteus-Modul (flutter_blue_plus)
- `lib/main.dart` – Oberfläche (Scan/Verbinden, Live-Anzeige, Konfig, Kalibrierung, Tankform)
- `pubspec.yaml` – Abhängigkeiten

## Einrichtung

Voraussetzung: Flutter SDK installiert (`flutter --version`).

Da nur der App-Quellcode (`lib/`, `pubspec.yaml`) hier liegt, müssen die
Plattform-Ordner (android/, ios/) einmalig erzeugt werden:

```bash
# 1) Leeres Flutter-Projekt an dieser Stelle erzeugen (füllt android/, ios/ auf,
#    ohne lib/ und pubspec.yaml zu überschreiben)
cd App_Fuellstand
flutter create --project-name fuellstand_app .

# 2) Abhängigkeiten holen
flutter pub get

# 3) Auf angeschlossenem Handy starten
flutter run
```

Falls `flutter create` `pubspec.yaml`/`lib/main.dart` überschreibt: die beiden
Dateien aus diesem Ordner danach wieder einspielen (bzw. vorher sichern).

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
