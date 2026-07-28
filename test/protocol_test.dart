import 'package:flutter_test/flutter_test.dart';
import 'package:fuellstand_app/protocol.dart';

void main() {
  group('SensorStatus.parse', () {
    test('vollständige STAT-Zeile', () {
      final s = SensorStatus.parse(
          'STAT;L=73.5;T=23.45;F=1;C=150;I=2;CAL=1;V=1.2.4;HW=1000');
      expect(s, isNotNull);
      expect(s!.level, closeTo(73.5, 0.001));
      expect(s.temp, closeTo(23.45, 0.001));
      expect(s.fluidType, 1);
      expect(s.capacity, 150);
      expect(s.instance, 2);
      expect(s.calibrated, isTrue);
      expect(s.version, '1.2.4');
      expect(s.hwRev, 1000);
    });

    test('toleriert Störzeichen vor STAT und dev-Version', () {
      final s = SensorStatus.parse('xxSTAT;L=5.0;CAL=0;V=1.2.4-dev');
      expect(s, isNotNull);
      expect(s!.level, 5.0);
      expect(s.calibrated, isFalse);
      expect(s.version, '1.2.4-dev'); // Suffix bleibt erhalten
    });

    test('negative Temperatur', () {
      final s = SensorStatus.parse('STAT;L=50.0;T=-5.25');
      expect(s!.temp, closeTo(-5.25, 0.001));
    });

    test('ohne L-Feld -> null', () {
      expect(SensorStatus.parse('STAT;T=20.0'), isNull);
    });

    test('keine STAT-Zeile -> null', () {
      expect(SensorStatus.parse('OK CAL100'), isNull);
    });
  });

  group('parseLin', () {
    test('gültige Kennlinie', () {
      expect(parseLin('LIN;0,10,20,30,40,50,60,70,80,90,100'),
          [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
    });

    test('toleriert führende Störzeichen', () {
      expect(parseLin('LIN;0,5,12,22,35,50,64,76,86,94,100'),
          [0, 5, 12, 22, 35, 50, 64, 76, 86, 94, 100]);
    });

    test('zu wenige Werte -> null', () {
      expect(parseLin('LIN;0,10,20'), isNull);
    });

    test('nicht-numerisch -> null', () {
      expect(parseLin('LIN;0,10,20,x,40,50,60,70,80,90,100'), isNull);
    });

    test('keine LIN-Zeile -> null', () {
      expect(parseLin('STAT;L=1'), isNull);
    });
  });

  group('parseName', () {
    test('gültiger Name', () {
      expect(parseName('NAME;Frischwasser Bug'), 'Frischwasser Bug');
    });

    test('leerer Name (noch nicht gesetzt)', () {
      expect(parseName('NAME;'), '');
    });

    test('toleriert führende Störzeichen', () {
      expect(parseName('xxNAME;Tank 2'), 'Tank 2');
    });

    test('OK NAME (Bestätigung) ist keine Namenszeile', () {
      expect(parseName('OK NAME'), isNull);
    });

    test('andere Zeilen -> null', () {
      expect(parseName('STAT;L=1'), isNull);
    });
  });

  group('parseFactoryResetAck', () {
    test('OK -> true', () {
      expect(parseFactoryResetAck('OK FACTORYRESET'), isTrue);
    });

    test('ERR -> false', () {
      expect(parseFactoryResetAck('ERR FACTORYRESET'), isFalse);
    });

    test('toleriert führende Störzeichen', () {
      expect(parseFactoryResetAck('xxOK FACTORYRESET'), isTrue);
    });

    test('andere Zeilen -> null', () {
      expect(parseFactoryResetAck('STAT;L=1'), isNull);
      expect(parseFactoryResetAck('OK CALRESET'), isNull);
    });
  });


  group('buildLinCommand', () {
    test('gültige Tabelle', () {
      expect(buildLinCommand([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]),
          'LIN 0,10,20,30,40,50,60,70,80,90,100');
    });

    test('falsche Anzahl wirft', () {
      expect(() => buildLinCommand([0, 50, 100]), throwsArgumentError);
    });

    test('Wert > 100 wirft', () {
      expect(
          () => buildLinCommand([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 101]),
          throwsArgumentError);
    });

    test('nicht monoton wirft', () {
      expect(
          () => buildLinCommand([0, 10, 20, 15, 40, 50, 60, 70, 80, 90, 100]),
          throwsArgumentError);
    });
  });

  group('hwVariantLabel', () {
    test('bekannte Variante mit Klartext und Nummer', () {
      expect(hwVariantLabel(1000), 'Drucksensor V1 (1000)');
      expect(hwVariantLabel(1002), 'Ultraschall (1002)');
    });

    test('unbekannte Variante bleibt als Zahl sichtbar', () {
      expect(hwVariantLabel(1234), '1234');
    });

    test('null -> Gedankenstrich', () {
      expect(hwVariantLabel(null), '–');
    });
  });

  group('parseCal', () {
    test('kalibrierter Sensor', () {
      final c = parseCal('CAL;1;41234');
      expect(c, isNotNull);
      expect(c!.calibrated, isTrue);
      expect(c.maxVal, 41234);
    });

    test('unkalibrierter Sensor', () {
      final c = parseCal('CAL;0;30000');
      expect(c!.calibrated, isFalse);
      expect(c.maxVal, 30000);
    });

    test('toleriert führende Störzeichen', () {
      expect(parseCal('xxCAL;1;500')!.maxVal, 500);
    });

    test('Quittungen matchen nicht', () {
      expect(parseCal('OK CAL 500'), isNull);
      expect(parseCal('OK CALRESET'), isNull);
      expect(parseCal('ERR CAL'), isNull);
    });

    test('unvollständige Zeile -> null', () {
      expect(parseCal('CAL;1'), isNull);
      expect(parseCal('CAL;1;abc'), isNull);
    });
  });

  group('SensorBackup', () {
    SensorBackup sample() => SensorBackup(
          created: DateTime.utc(2026, 7, 8, 12, 30),
          sourceName: 'Frischwasser Bug',
          firmware: '1.2.9',
          hwRev: 1000,
          hwVariant: 1000,
          calibrated: true,
          calValue: 41234,
          fluidType: 1,
          capacity: 150,
          instance: 2,
          name: 'Frischwasser Bug',
          curve: const [0, 8, 18, 29, 40, 50, 61, 72, 83, 92, 100],
        );

    test('Rundlauf über JSON erhält alle Werte', () {
      final b = SensorBackup.fromJson(sample().toJson());
      expect(b.calibrated, isTrue);
      expect(b.calValue, 41234);
      expect(b.fluidType, 1);
      expect(b.capacity, 150);
      expect(b.instance, 2);
      expect(b.name, 'Frischwasser Bug');
      expect(b.curve, [0, 8, 18, 29, 40, 50, 61, 72, 83, 92, 100]);
      expect(b.hwVariant, 1000);
      expect(b.hwRev, 1000);
      expect(b.firmware, '1.2.9');
      expect(b.created.toUtc(), DateTime.utc(2026, 7, 8, 12, 30));
    });

    test('fremde Datei wird abgelehnt', () {
      expect(() => SensorBackup.fromJson({'foo': 'bar'}),
          throwsA(isA<FormatException>()));
    });

    test('neueres Format wird abgelehnt', () {
      final j = sample().toJson();
      j['format'] = 99;
      expect(() => SensorBackup.fromJson(j), throwsA(isA<FormatException>()));
    });

    test('fehlender Konfigblock wird abgelehnt', () {
      expect(
          () => SensorBackup.fromJson(
              {'typ': 'levelsense-backup', 'format': 1}),
          throwsA(isA<FormatException>()));
    });

    test('Kennlinie mit falscher Länge wird abgelehnt', () {
      final j = sample().toJson();
      (j['konfig'] as Map)['kennlinie'] = [0, 50, 100];
      expect(() => SensorBackup.fromJson(j), throwsA(isA<FormatException>()));
    });

    test('fallende Kennlinie wird abgelehnt', () {
      final j = sample().toJson();
      (j['konfig'] as Map)['kennlinie'] = [
        0, 10, 5, 30, 40, 50, 60, 70, 80, 90, 100 //
      ];
      expect(() => SensorBackup.fromJson(j), throwsA(isA<FormatException>()));
    });

    test('Wert außerhalb des Bereichs wird abgelehnt', () {
      final j = sample().toJson();
      (j['konfig'] as Map)['instanz'] = 99;
      expect(() => SensorBackup.fromJson(j), throwsA(isA<FormatException>()));
    });

    test('unkalibrierte Sicherung bleibt unkalibriert', () {
      final j = sample().toJson();
      (j['konfig'] as Map)['kalibriert'] = false;
      expect(SensorBackup.fromJson(j).calibrated, isFalse);
    });

    test('fehlende optionale Felder sind erlaubt', () {
      final b = SensorBackup.fromJson({
        'typ': 'levelsense-backup',
        'format': 1,
        'erstellt': '2026-07-08T12:30:00.000Z',
        'konfig': {'kalibriert': false},
      });
      expect(b.curve, isNull);
      expect(b.calValue, isNull);
      expect(b.name, isNull);
    });
  });
}
