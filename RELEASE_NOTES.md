## App 1.4.6

- **Mehrsensor-Dashboard:** Mehrere Sensoren werden jetzt gleichzeitig
  verbunden und als Kacheln angezeigt (Name, Füllstand, Liter, Temperatur,
  Verbindungsstatus). Tippen öffnet die Detail-/Einstellungsansicht eines
  Sensors; Sensoren lassen sich per „+" hinzufügen und per langem Druck
  entfernen.
- Der aktuelle Füllstand in Litern wird genauso prominent angezeigt wie die
  Prozentanzeige; die Tankgröße bleibt klein daneben. Die App-Version steht
  fest am unteren Bildschirmrand.
- Schnelleres automatisches Wiederverbinden nach dem Öffnen der App.
- Intern: Die Bluetooth-Verbindung nutzt kein erzwungenes Pairing mehr –
  dadurch verbindet sich die App zuverlässig (passend zu Sensor-Firmware 1.2.7).

## App 1.4.5

- Neu: Werksreset des Sensors (Einstellungen → Modul, mit Sicherheitsabfrage).
  Löscht Kalibrierung, Tankform, Konfiguration, Name und gespeicherte
  Adresse; danach startet der Sensor neu, die Verbindung trennt sich und
  die App kehrt zur Suchseite zurück. Benötigt Sensor-Firmware ab 1.2.6.
- Hinweis: Fabrikneue oder zurückgesetzte Sensoren erscheinen beim Scan als
  `LevelSense-<UID>` (ab Firmware 1.2.6).
- Intern: 40 Unit-Tests.

## App 1.4.4

- Sensorname: Der im Sensor gespeicherte Name wird beim Verbinden abgefragt
  und im Einstellungsfeld angezeigt; Umbenennen setzt Bluetooth-Namen und
  NMEA2000-Installation-Description (Geräteliste am Plotter) in einem Schritt
- Hinweis, wenn Bluetooth-Name und gespeicherter Name voneinander abweichen
  (z. B. nach Umbenennung vom Plotter aus)
- Hinweis: Die Namensabfrage benötigt Sensor-Firmware ab 1.2.5 – mit älterer
  Firmware verhält sich die App wie bisher
  
## App 1.4.3

- Schutz vor falschen Firmware-Dateien: vor dem OTA-Update wird geprüft, ob
  die .bin ein gültiges App-Image für den Sensor ist (fängt z. B. die
  Bootloader-Datei ab); die Dateiauswahl zeigt nur noch .bin-Dateien
- Zuverlässigeres OTA-Update: sporadische Timeouts durch verloren gegangene
  Antworten behoben
- GitHub-Abfragen und -Downloads mit Zeitlimit – kein endlos hängender
  Ladedialog mehr bei schlechter Verbindung
- Intern: 25 Unit-Tests für Protokoll-Parser, DFU-Pakete, CRC32
  (Referenzwert-geprüft) und Versionsvergleich
