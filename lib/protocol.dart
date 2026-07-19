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

  const SensorStatus({
    this.level,
    this.temp,
    this.fluidType,
    this.capacity,
    this.instance,
    this.calibrated,
    this.version,
    this.hwRev,
  });

  /// Parst `STAT;L=73.5;T=23.45;F=1;C=150;I=0;CAL=1;V=1.2.3-dev;HW=1000`.
  /// Zerlegt die Zeile ab `STAT` an `;` in `Schlüssel=Wert`-Paare, sodass auch
  /// nicht-numerische Werte (z. B. `V=1.2.3-dev`) vollständig erhalten bleiben.
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

/// Erkennt die Antwort auf das Kommando `PIN nnnnnn`:
/// true = `OK PIN` (bei Änderung trennt der Sensor danach die Verbindung,
/// alle Kopplungen werden gelöscht), false = `ERR PIN`, null = andere Zeile.
bool? parsePinAck(String line) {
  if (line.contains('OK PIN')) return true;
  if (line.contains('ERR PIN')) return false;
  return null;
}

/// Prüft eine Bluetooth-PIN: genau 6 Ziffern (BLE-Static-Passkey-Format).
bool isValidBlePin(String pin) => RegExp(r'^[0-9]{6}$').hasMatch(pin);

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
