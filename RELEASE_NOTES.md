## App 2.2.0

Die App löscht keine Kopplung mehr im Stillen, sondern fragt.

- **Nachfrage statt Selbstheilung.** Scheitert die Verbindung dreimal
  hintereinander am selben Muster – die Funkverbindung steht, die
  Einrichtung läuft nicht durch –, meldet sich die App mit einem Fenster.
  Erst auf „Kopplung erneuern“ wird die gespeicherte Kopplung entfernt;
  danach fragt der Sensor wieder nach der PIN. Bisher tat die App das von
  selbst, und wer nicht wusste warum, hielt die PIN-Abfrage für den Fehler.
- Ein Sensor außer Reichweite löst die Nachfrage nicht aus. Gezählt wird
  nur, was auch wirklich nach einer veralteten Kopplung aussieht.
- „Später“ hält für die laufende Sitzung. Auf iOS lässt sich eine Kopplung
  ohnehin nur in den Bluetooth-Einstellungen entfernen; das sagt die App
  jetzt auch.
- Passend dazu räumt Firmware 2.2.0 auf der Sensorseite auf: dort werden
  Bonds nur noch beim Werksreset gelöscht.
- Intern: 68 Unit-Tests.

## App 2.1.2

Schärft das Verbindungsprotokoll, nachdem der erste Blick darauf zwei
Schwächen gezeigt hat.

- **Keine erfundenen Trennungen mehr.** Der Zustandsstrom meldet beim
  Abonnieren sofort den aktuellen Stand; das landete als „Verbindung
  getrennt“ im Protokoll, noch bevor überhaupt eine Verbindung bestand.
  Protokolliert wird eine Trennung jetzt nur, wenn vorher wirklich eine
  Verbindung stand.
- **Trennungen mit Grund.** Android liefert einen Code dazu; er
  unterscheidet die Fälle, auf die es ankommt - vom Sensor beendet,
  Funkstrecke weg oder Verschlüsselung gescheitert. Bisher sahen die im
  Protokoll alle gleich aus.
- Ein gelungener zweiter Anlauf steht jetzt als solcher da. Bisher folgte
  auf „Verbindungsaufbau fehlgeschlagen“ wortlos „Verbunden und
  eingerichtet“, was sich wie ein Widerspruch las.

## App 2.1.1

- **Das Verbindungsprotokoll ist jetzt von der Startseite aus erreichbar**
  - im Entwicklermodus über das Uhr-Symbol oben rechts. Bisher lag es
  nur in den Wartungseinstellungen des Sensors, und die öffnen sich nur
  bei bestehender Verbindung. Ausgerechnet im Fehlerfall, dem das
  Protokoll gilt, kam man also nicht heran.
- Der bisherige Weg über Wartung → Entwicklermodus bleibt bestehen.

## App 2.1.0

Nur Diagnose. Sichtbar ist die Neuerung ausschließlich im
Entwicklermodus, am normalen Betrieb ändert sich nichts.

- **Verbindungsprotokoll mit Uhrzeit, das den App-Neustart übersteht.**
  Die Konsole zeigt nur, was seit dem letzten Start passiert ist; ein
  Fehler, der erst nach Stunden auftritt, ist damit nicht zu fassen.
  Das neue Protokoll schreibt in eine Datei und hält fest, wann
  verbunden und getrennt wurde, wie jeder gescheiterte
  Verbindungsversuch geendet hat, jeden Wechsel des Systembonds und
  jedes Löschen einer Kopplung - die Selbstheilung mit einer eigenen,
  auffälligen Zeile.
- Zu finden im Entwicklermodus unter „Verbindungsprotokoll“, mit
  Knöpfen zum Kopieren und Leeren. Es fasst 500 Zeilen, danach fallen
  die ältesten heraus.
- Gedacht für die Frage, warum ein gekoppeltes Handy nach etwa einem
  Tag Betrieb wieder nach der PIN gefragt wird. Die Gegenprobe auf der
  Sensorseite liefert Firmware 2.1.0 zusammen mit dem PC-Werkzeug 1.2.0.
- Intern: 68 Unit-Tests.

## App 2.0.1

Reine Bau-Änderung, an der App selbst ändert sich nichts. Die APK hier
im GitHub-Release verhält sich wie 2.0.0.

- Die App wird ab jetzt in zwei Varianten gebaut. Die GitHub-Variante
  meldet sich wie bisher selbst, wenn eine neuere Version vorliegt. Der
  Play-Store-Variante fehlt dieser In-App-Updater, weil Play
  Selbst-Updates am Store vorbei verbietet; dort kommen die Updates aus
  dem Store. Sie fordert dafür auch die Berechtigung zum Installieren
  von Apps nicht mehr an.
- Das Firmware-Update des Sensors ist davon nicht betroffen und läuft in
  beiden Varianten unverändert.
- Intern: 68 Unit-Tests.

## App 2.0.0

Die Verbindung zum Sensor ist ab Firmware 2.0.0 mit einer Kopplungs-PIN
gesichert. Die App führt durch die Kopplung, wechselt die PIN und räumt
veraltete Kopplungen selbst weg. Außerdem sind die Diagnose-Anzeigen aus
der Oberfläche verschwunden, die im Alltag niemand braucht.

### Kopplungs-PIN
- Neuer Abschnitt „Sicherheit (Kopplungs-PIN)" in den Einstellungen. Dort
  lässt sich die sechsstellige PIN ändern; ab Werk ist es 123123. Vor dem
  Senden fragt die App nach, weil der Sensor dabei alle gespeicherten
  Kopplungen löscht und das Funkmodul neu startet.
- Nach einem PIN-Wechsel und nach einem Werksreset entfernt die App die
  Android-Kopplung zu diesem Sensor selbst. Ohne das gehört der
  gespeicherte Bond noch zur alten PIN, und der nächste Verbindungsversuch
  scheitert wortlos. Auf iOS geht das nicht - dort muss der Sensor von
  Hand aus den Bluetooth-Einstellungen entfernt werden.
- **Die App bricht die Kopplung nicht mehr ab, während der PIN-Dialog
  offen steht.** Bisher lief ihr eigener Zeitgeber weiter, während das
  Handy noch auf die Eingabe wartete; sie riss die Verbindung weg, bevor
  die PIN überhaupt eingetippt werden konnte. Das war die Ursache der
  endlosen Kopplungsversuche. Jetzt wartet sie, solange Android eine
  Kopplung meldet, und wertet erst danach aus.
- **Selbstheilung bei veralteter Kopplung.** Scheitert die
  Verschlüsselung, löscht die App einmal je Verbindungsanlauf den
  Android-Bond und versucht es erneut - das Modul fragt dann wieder nach
  der PIN. Das greift genau in dem Fall, in dem das Handy noch einen Bond
  hat, den das Modul nicht mehr kennt: nach PIN-Wechsel, nach Werksreset
  oder wenn der Sensor mit einem anderen Gerät neu gekoppelt wurde.

### Entwicklermodus
- **Die Diagnose-Anzeigen sind im Normalbetrieb ausgeblendet:** der
  Abschnitt „Log & Konsole" samt Eingabefeld, die Rohdruck-Zeile in den
  beiden Kalibrierkarten und die Zeile „Bond-Status" unter Sicherheit.
  Keine davon wird im Betrieb gebraucht, und das Konsolenfeld schickt
  beliebige Kommandos an den Sensor.
- Freigeschaltet wird durch siebenmaliges Tippen auf die Versionszeile
  unten auf der Startseite. Ist der Modus an, steht das in der
  Versionszeile, und ein eigener Abschnitt „Entwicklermodus" in den
  Einstellungen schaltet ihn wieder ab. Der Zustand überlebt den
  Neustart.
- Werksreset und PIN-Wechsel bleiben sichtbar. Beides gehört zum
  normalen Betrieb; hier ging es nur darum, die Oberfläche aufzuräumen.

- Passend zu Sensor-Firmware 2.0.0; ältere Firmware wird weiter
  unterstützt, dort entfällt der Abschnitt Sicherheit.
- Intern: 68 Unit-Tests.

## App 1.4.9

- **Update-Angebot nach Hardware-Variante gefiltert.** Die App bietet nur
  noch Firmware an, die zur gemeldeten Variante des Sensors passt
  (hwv-Kennung im Dateinamen der Release-Assets). Releases der alten
  V1-Linie (bis Firmware 1.2.9, ohne Kennung) sehen nur V1-Sensoren.
  Damit kann insbesondere die Verwechslung 1001/1003 nicht mehr
  passieren, die nicht als Fehler auffiele, sondern nur als zehnfach
  falscher Fuellstand. Auch die Update-Benachrichtigung bewertet nur
  noch passende Releases.
- **Firmware-Update robuster.** Beim Wechsel in den Update-Modus fragt
  die App nach jedem Verbinden nach, ob sie mit der App-Firmware oder
  dem Bootloader spricht, und fordert den Update-Modus bei Bedarf erneut
  an. Verlorene oder verspaetet zugestellte Kommandos fuehren nicht mehr
  zum Timeout-Abbruch. Zusaetzlich trennt die App die Verbindung selbst,
  statt auf den Bluetooth-Timeout des Handys zu warten - der Wechsel in
  den Bootloader dauert damit zuverlaessig nur wenige Sekunden.
- Unter „Modul" wird die Hardware-Variante mit Platinen-Stand angezeigt,
  z. B. „Drucksensor V2 ±1 kPa (1003A)". Die Variantennamen nennen jetzt
  den Messbereich (±10 kPa / ±1 kPa). Die separate Zeile „HW-Revision"
  entfaellt (Firmware ab 1.2.10 meldet das Feld nicht mehr; bei aelterer
  Firmware trug es keine Information).
- Sicherungsdateien speichern den Platinen-Stand (`hw_platine`) statt der
  frueheren `hw_revision`; alte Sicherungen bleiben lesbar.
- Passend zu Sensor-Firmware 1.2.10; aeltere Firmware (STAT ohne
  Buchstaben oder ohne HWV-Feld) wird weiter unterstuetzt.
- Intern: 68 Unit-Tests.

## App 1.4.8

- **Neu: Sicherung der Konfiguration** (Einstellungen → Sicherung).
  „Sichern" liest Kalibrierwert, Tankform, Fluidtyp, Kapazität, Instanz und
  Name aus dem Sensor und legt sie als lesbare JSON-Datei ab. „Einspielen"
  prüft die Datei, zeigt alle Werte zur Bestätigung und schreibt sie dann
  auf den verbundenen Sensor. Gedacht für Gerätetausch, Wiederherstellung
  nach einem Werksreset und das Einrichten eines zweiten identischen Tanks.
  Stammt die Sicherung von einer anderen Hardware-Variante, warnt die App.
  Benötigt Sensor-Firmware ab 1.2.9.
- **Neu: Verbindung im Hintergrund freigeben.** Läuft die App länger als
  15 Sekunden im Hintergrund, trennt sie die Verbindung, damit ein anderes
  Handy an den Sensor kommt. Kommt die App vorher zurück, bleibt die
  Verbindung bestehen; ein laufendes Firmware-Update wird nie unterbrochen.
- Unter „Modul" wird zusätzlich die Hardware-Variante angezeigt
  (z. B. „Drucksensor V1 (1000)"), sofern der Sensor sie meldet.
- Passend zu Sensor-Firmware 1.2.9.
- Intern: 57 Unit-Tests.

## App 1.4.7

- Nach einem Werksreset zeigt die App den Sensor automatisch wieder mit
  seinem Standardnamen („LevelSense-…") an – Entfernen und Neu-Hinzufügen
  ist nicht mehr nötig. Anzeigenamen bekannter Sensoren werden bei jedem
  Scan aus frischen Bluetooth-Advertisements aktualisiert.
- Irreführender Hinweis „Bluetooth-Name weicht ab" nach dem Umbenennen
  entfernt: Der im Sensor gespeicherte Name ist die einzige Quelle der
  Wahrheit, die Anzeige folgt ihm jetzt direkt (der Namens-Cache des
  Systems lieferte nach dem Umbenennen oft noch den alten Namen).
- Passend zu Sensor-Firmware 1.2.8 (Namensstand sofort auf dem NMEA-Bus).

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
