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

  const SensorStatus({
    this.level,
    this.temp,
    this.fluidType,
    this.capacity,
    this.instance,
    this.calibrated,
    this.version,
  });

  /// Parst `STAT;L=73.5;T=23.45;F=1;C=150;I=0;CAL=1`. Gibt null bei anderer Zeile.
  /// Robust gegen führende Störzeichen und abweichende Trennzeichen: es werden
  /// einfach alle `Schlüssel=Wert`-Paare aus der Zeile extrahiert.
  static SensorStatus? parse(String line) {
    if (!line.contains('STAT')) return null;
    final map = <String, String>{};
    for (final m in RegExp(r'([A-Za-z]+)=(-?[0-9.]+)').allMatches(line)) {
      map[m.group(1)!.toUpperCase()] = m.group(2)!;
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
