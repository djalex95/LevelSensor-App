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
