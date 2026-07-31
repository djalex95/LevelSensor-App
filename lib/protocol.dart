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
  final int? hwVariant; // Hardware-Variante (Messprinzip): 1000=Druck V1,
  // 1001=Druck V2 ±10 kPa, 1003=Druck V2 flach ±1 kPa (siehe
  // hwVariantNames). Grundlage für die passende Firmware-Auswahl beim
  // Update (Cross-Flash-Schutz). null = altes STAT ohne HWV-Feld.
  final String? hwSuffix; // Platinen-Stand: Buchstabe hinter der Variante
  // (z. B. "A" aus "HWV=1003A"). Rein informativ, gleiche Firmware.
  // null = Firmware, die noch keinen Buchstaben meldet.
  final int? rawPress; // ungefilterter, offsetkorrigierter Messdruck in µBar
  // (Feld P, ab Firmware 1.3.0). null = ältere Firmware. Dient zugleich als
  // Erkennung, ob der Sensor CAL0/FILT unterstützt.
  final int? errorBits; // Fehlerbits (Feld E): 1=CAN, 2=I2C, 4=HW-Variante.

  const SensorStatus({
    this.level,
    this.temp,
    this.fluidType,
    this.capacity,
    this.instance,
    this.calibrated,
    this.version,
    this.hwVariant,
    this.hwSuffix,
    this.rawPress,
    this.errorBits,
  });

  /// Parst `STAT;L=73.5;T=23.45;F=1;C=150;I=0;CAL=1;V=1.2.3-dev;HWV=1003A`.
  /// Ältere Firmware meldet `HWV=1000` ohne Buchstaben und zusätzlich
  /// `HW=1000` (die frühere separate Revision) - das HW-Feld wird ignoriert.
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
      hwVariant: _hwvNumber(map['HWV']),
      hwSuffix: _hwvSuffix(map['HWV']),
      rawPress: int.tryParse(map['P'] ?? ''),
      errorBits: int.tryParse(map['E'] ?? ''),
    );
  }

  /// Zerlegt die HWV-Meldung `1003A` (oder alt: `1000`) in Zahl und
  /// Platinen-Buchstaben.
  static final RegExp _hwvRe = RegExp(r'^(\d+)\s*([A-Za-z]?)$');
  static int? _hwvNumber(String? v) {
    final m = _hwvRe.firstMatch(v?.trim() ?? '');
    return m == null ? null : int.tryParse(m.group(1)!);
  }
  static String? _hwvSuffix(String? v) {
    final m = _hwvRe.firstMatch(v?.trim() ?? '');
    final s = m?.group(2) ?? '';
    return s.isEmpty ? null : s.toUpperCase();
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

/// Kalibrierwerte aus der Antwort `CAL;<0/1>;<max_val>[;<offset>]`
/// (Kommando `CAL`). `max_val` ist der Rohdruck bei 100 % Füllstand,
/// `offset` der Nullpunkt aus `CAL0` in µBar (ab Firmware 1.3.0; ältere
/// Firmware sendet das Feld nicht -> null). Null, wenn die Zeile keine
/// CAL-Antwort ist – `OK CAL …` und `OK CALRESET` matchen bewusst nicht.
class CalibrationValue {
  final bool calibrated;
  final int maxVal;
  final int? offset;

  const CalibrationValue(
      {required this.calibrated, required this.maxVal, this.offset});
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
    offset: parts.length > 2 ? int.tryParse(parts[2].trim()) : null,
  );
}

/// Neuer Nullpunkt aus der Bestätigung `OK CAL0 <offset>` (Kommando `CAL0`).
/// Damit zeigt die App den Wert sofort, ohne extra CAL-Abfrage.
/// Null bei anderen Zeilen; `OK CAL0RESET` matcht bewusst nicht.
final RegExp _cal0AckRe = RegExp(r'OK CAL0 (-?\d+)');
int? parseCal0Ack(String line) {
  final m = _cal0AckRe.firstMatch(line);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Filterstärke aus der Antwort `FILT;<0..990>` (Kommando `FILT`).
/// Anteil des alten Werts in Promille. Null, wenn die Zeile keine
/// FILT-Antwort ist – `OK FILT …` matcht bewusst nicht.
int? parseFilt(String line) {
  final i = line.indexOf('FILT;');
  if (i < 0) return null;
  final v = int.tryParse(line.substring(i + 5).trim());
  return (v != null && v >= 0 && v <= 990) ? v : null;
}

/// Klartextnamen der Hardware-Varianten (Messprinzip), gemeldet als `HWV`
/// in der STAT-Zeile. Siehe ARCHITECTURE.md der Firmware.
const Map<int, String> hwVariantNames = {
  // Entspricht Core/Inc/version.h der Firmware. Eine Variante 1002
  // (Ultraschall) ist dort nur als Idee vermerkt und existiert nicht -
  // unbekannte Nummern zeigt hwVariantLabel als reine Zahl an.
  1000: 'Drucksensor V1',
  1001: 'Drucksensor V2 ±10 kPa',
  1003: 'Drucksensor V2 flach ±1 kPa',
};

/// Anzeigetext für eine Variantennummer. Unbekannte Nummern werden als reine
/// Zahl gezeigt, damit auch künftige Varianten sichtbar bleiben; `null`
/// (altes STAT ohne HWV) ergibt einen Gedankenstrich.
String hwVariantLabel(int? id, [String? hwSuffix]) {
  if (id == null) return '–';
  final code = '$id${hwSuffix ?? ''}';
  final name = hwVariantNames[id];
  return name == null ? code : '$name ($code)';
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
  final int? hwVariant;
  final String? hwSuffix; // Platinen-Buchstabe, z. B. "A"

  final bool calibrated;
  final int? calValue; // max_val, Rohdruck bei 100 %
  final int? calOffset; // Nullpunkt-Offset in µBar (CAL0, ab Firmware 1.3.0)
  final int? filter; // EMA-Filter, Anteil alter Wert in Promille (FILT)
  final int? fluidType;
  final int? capacity;
  final int? instance;
  final String? name;
  final List<int>? curve; // 11 Stützstellen

  const SensorBackup({
    required this.created,
    this.sourceName,
    this.firmware,
    this.hwVariant,
    this.hwSuffix,
    this.calibrated = false,
    this.calValue,
    this.calOffset,
    this.filter,
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
          'hw_variante': hwVariant,
          'hw_platine': hwSuffix,
        },
        'konfig': {
          'kalibriert': calibrated,
          'kalibrierwert': calValue,
          'nullpunkt_offset': calOffset,
          'filter_promille': filter,
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
      hwVariant: (src['hw_variante'] as num?)?.round(),
      hwSuffix: src['hw_platine'] as String?,
      calibrated: cfg['kalibriert'] == true,
      calValue: range('kalibrierwert', 1, 1000000),
      calOffset: range('nullpunkt_offset', -30000, 30000),
      filter: range('filter_promille', 0, 990),
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
