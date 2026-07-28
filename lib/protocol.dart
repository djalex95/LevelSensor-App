/// Parsen und Erzeugen der Textnachrichten des Füllstandsensors.
/// Siehe PC_Tools/BLE_Protokoll.md für die vollständige Spezifikation.

/// Dekodierter Status aus einer `STAT;...`-Zeile.
class SensorStatus {
  final double? level; // Füllstand in %
  final double? temp; // Temperatur in °C
  final int? fluidType; // 0..15
  final int? capacity; // Liter
  final int? instance; // 0..15
  final bool? calibrated; // 100%-Kalibrierung vorhanden
  final String? version; // Firmware-Version, z. B. "1.2.0"
  final int? hwRev; // Hardware-Revision, z. B. 1000
  final int? hwVariant; // Hardware-Variante (Messprinzip): 1000=Druck V1,
  // 1001=Druck V2, 1002=Ultraschall. Grundlage für die passende
  // Firmware-Auswahl beim Update (Cross-Flash-Schutz). null = altes STAT
  // ohne HWV-Feld.

  const SensorStatus({
    this.level,
    this.temp,
    this.fluidType,
    this.capacity,
    this.instance,
    this.calibrated,
    this.version,
    this.hwRev,
    this.hwVariant,
  });

  /// Parst `STAT;L=73.5;T=23.45;F=1;C=150;I=0;CAL=1;V=1.2.3-dev;HW=1000;HWV=1000`.
  /// Zerlegt die Zeile ab `STAT` an `;` in `Schlüssel=Wert`-Paare, sodass auch
  /// nicht-numerische Werte (z. B. `V=1.2.3-dev`) vollständig erhalten bleiben.
  /// Unbekannte/fehlende Felder werden toleriert (Vorwärts-/Rückwärtskompat.).
  static SensorStatus? parse(String line) {
    final start = line.indexOf('STAT');
    if (start < 0) return null;
    final map = <String, String>{};
    for (final part in line.substring(start).split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        map[part.substring(0, eq).trim().toUpperCase()] =
            part.substring(eq + 1).trim();
      }
    }
    if (!map.containsKey('L')) return null;
    return SensorStatus(
      level: double.tryParse(map['L'] ?? ''),
      temp: double.tryParse(map['T'] ?? ''),
      fluidType: int.tryParse(map['F'] ?? ''),
      capacity: int.tryParse(map['C'] ?? ''),
      instance: int.tryParse(map['I'] ?? ''),
      calibrated: map['CAL'] == '1',
      version: map['V'],
      hwRev: int.tryParse(map['HW'] ?? ''),
      hwVariant: int.tryParse(map['HWV'] ?? ''),
    );
  }
}

/// Parst `LIN;0,10,...,100` in eine Liste mit 11 Werten. Null bei Fehler.
/// Toleriert führende Störzeichen (sucht ab `LIN;`).
List<int>? parseLin(String line) {
  final i = line.indexOf('LIN;');
  if (i < 0) return null;
  final parts = line.substring(i + 4).split(',');
  if (parts.length < 11) return null;
  final pts = <int>[];
  for (var k = 0; k < 11; k++) {
    final v = int.tryParse(parts[k].trim());
    if (v == null) return null;
    pts.add(v);
  }
  return pts;
}

/// Parst `NAME;<text>` - der im Sensor gespeicherte Name (Antwort auf das
/// Kommando `NAME` ohne Argument). Null, wenn keine NAME-Zeile; leerer
/// String, wenn noch kein Name gesetzt ist. ("OK NAME" matcht nicht.)
String? parseName(String line) {
  final i = line.indexOf('NAME;');
  if (i < 0) return null;
  return line.substring(i + 5).trim();
}

/// Erkennt die Antwort auf das Kommando `FACTORYRESET`:
/// true = `OK FACTORYRESET` (Sensor löscht den Config und startet neu),
/// false = `ERR FACTORYRESET`, null = andere Zeile.
bool? parseFactoryResetAck(String line) {
  if (line.contains('OK FACTORYRESET')) return true;
  if (line.contains('ERR FACTORYRESET')) return false;
  return null;
}

/// Kalibrierwert aus der Antwort `CAL;<0/1>;<max_val>` (Kommando `CAL`).
/// `max_val` ist der Rohdruck bei 100 % Füllstand. Null, wenn die Zeile keine
/// CAL-Antwort ist – `OK CAL …` und `OK CALRESET` matchen bewusst nicht.
class CalibrationValue {
  final bool calibrated;
  final int maxVal;

  const CalibrationValue({required this.calibrated, required this.maxVal});
}

CalibrationValue? parseCal(String line) {
  final i = line.indexOf('CAL;');
  if (i < 0) return null;
  final parts = line.substring(i + 4).split(';');
  if (parts.length < 2) return null;
  final max = int.tryParse(parts[1].trim());
  if (max == null) return null;
  return CalibrationValue(
    calibrated: parts[0].trim() == '1',
    maxVal: max,
  );
}

/// Klartextnamen der Hardware-Varianten (Messprinzip), gemeldet als `HWV`
/// in der STAT-Zeile. Siehe ARCHITECTURE.md der Firmware.
const Map<int, String> hwVariantNames = {
  1000: 'Drucksensor V1',
  1001: 'Drucksensor V2',
  1002: 'Ultraschall',
};

/// Anzeigetext für eine Variantennummer. Unbekannte Nummern werden als reine
/// Zahl gezeigt, damit auch künftige Varianten sichtbar bleiben; `null`
/// (altes STAT ohne HWV) ergibt einen Gedankenstrich.
String hwVariantLabel(int? id) {
  if (id == null) return '–';
  final name = hwVariantNames[id];
  return name == null ? '$id' : '$name ($id)';
}

/// Vollständige Sicherung der Sensorkonfiguration.
///
/// Bewusst **nicht** enthalten: die geclaimte NMEA2000-Quelladresse (würde
/// beim Einspielen auf ein zweites Gerät Adresskonflikte auslösen und wird
/// beim Start ohnehin neu ausgehandelt) sowie interne Marker der Firmware.
/// Die DAC-Kalibrierung liegt fest in der Firmware und ist nicht Teil des
/// Konfigurationsspeichers.
class SensorBackup {
  /// Kennung im Dateikopf, damit fremde JSON-Dateien sauber abgelehnt werden.
  static const String kind = 'levelsense-backup';

  /// Formatversion der Datei. Wird beim Einlesen geprüft; ältere Stände
  /// bleiben lesbar, wenn später Felder hinzukommen.
  static const int formatVersion = 1;

  final DateTime created;
  final String? sourceName; // Name des Sensors zum Zeitpunkt der Sicherung
  final String? firmware;
  final int? hwRev;
  final int? hwVariant;

  final bool calibrated;
  final int? calValue; // max_val, Rohdruck bei 100 %
  final int? fluidType;
  final int? capacity;
  final int? instance;
  final String? name;
  final List<int>? curve; // 11 Stützstellen

  const SensorBackup({
    required this.created,
    this.sourceName,
    this.firmware,
    this.hwRev,
    this.hwVariant,
    this.calibrated = false,
    this.calValue,
    this.fluidType,
    this.capacity,
    this.instance,
    this.name,
    this.curve,
  });

  Map<String, dynamic> toJson() => {
        'typ': kind,
        'format': formatVersion,
        'erstellt': created.toIso8601String(),
        'quelle': {
          'name': sourceName,
          'firmware': firmware,
          'hw_revision': hwRev,
          'hw_variante': hwVariant,
        },
        'konfig': {
          'kalibriert': calibrated,
          'kalibrierwert': calValue,
          'fluidtyp': fluidType,
          'kapazitaet_liter': capacity,
          'instanz': instance,
          'name': name,
          'kennlinie': curve,
        },
      };

  /// Liest eine Sicherungsdatei. Wirft [FormatException] mit einer für die
  /// Anzeige geeigneten Meldung, wenn die Datei nicht passt.
  factory SensorBackup.fromJson(Map<String, dynamic> j) {
    if (j['typ'] != kind) {
      throw const FormatException('Das ist keine Sensor-Sicherung.');
    }
    final fmt = j['format'];
    if (fmt is! int || fmt > formatVersion) {
      throw FormatException(
          'Format $fmt wird von dieser App-Version noch nicht unterstützt.');
    }
    final src = (j['quelle'] as Map?)?.cast<String, dynamic>() ?? {};
    final cfg = (j['konfig'] as Map?)?.cast<String, dynamic>();
    if (cfg == null) {
      throw const FormatException('Die Sicherung enthält keine Konfiguration.');
    }

    List<int>? curve;
    final raw = cfg['kennlinie'];
    if (raw is List) {
      if (raw.length != 11) {
        throw const FormatException('Die Kennlinie muss 11 Werte haben.');
      }
      curve = raw.map((e) => (e as num).round()).toList();
      for (final v in curve) {
        if (v < 0 || v > 100) {
          throw const FormatException('Kennlinienwerte müssen 0..100 sein.');
        }
      }
      for (var i = 1; i < 11; i++) {
        if (curve[i] < curve[i - 1]) {
          throw const FormatException('Die Kennlinie muss steigen.');
        }
      }
    }

    int? range(String key, int min, int max) {
      final v = cfg[key];
      if (v == null) return null;
      final n = (v as num).round();
      if (n < min || n > max) {
        throw FormatException('Wert für „$key" liegt außerhalb $min..$max.');
      }
      return n;
    }

    return SensorBackup(
      created: DateTime.tryParse('${j['erstellt']}') ?? DateTime(1970),
      sourceName: src['name'] as String?,
      firmware: src['firmware'] as String?,
      hwRev: (src['hw_revision'] as num?)?.round(),
      hwVariant: (src['hw_variante'] as num?)?.round(),
      calibrated: cfg['kalibriert'] == true,
      calValue: range('kalibrierwert', 1, 1000000),
      fluidType: range('fluidtyp', 0, 15),
      capacity: range('kapazitaet_liter', 1, 255),
      instance: range('instanz', 0, 15),
      name: cfg['name'] as String?,
      curve: curve,
    );
  }
}

/// Fluidtyp-Codes nach NMEA2000.
const Map<int, String> fluidNames = {
  0: 'Kraftstoff',
  1: 'Wasser',
  2: 'Grauwasser',
  3: 'Live Well',
  4: 'Öl',
  5: 'Schwarzwasser',
  6: 'Benzin',
};

/// Baut das Schreibkommando für die Tankform-Kennlinie: `LIN v0,v1,...,v10`.
/// Wirft [ArgumentError] bei ungültiger Tabelle (nicht 11 Werte, außerhalb
/// 0..100 oder nicht monoton steigend).
String buildLinCommand(List<int> points) {
  if (points.length != 11) {
    throw ArgumentError('Es werden genau 11 Werte benötigt');
  }
  for (final p in points) {
    if (p < 0 || p > 100) throw ArgumentError('Werte müssen 0..100 sein');
  }
  for (var i = 0; i < 10; i++) {
    if (points[i + 1] < points[i]) {
      throw ArgumentError('Werte müssen steigen');
    }
  }
  return 'LIN ${points.join(',')}';
}
