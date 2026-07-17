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
