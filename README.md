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
flutter run
```

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
