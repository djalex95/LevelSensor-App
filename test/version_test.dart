import 'package:flutter_test/flutter_test.dart';
import 'package:fuellstand_app/github_releases.dart';

void main() {
  group('isNewerVersion', () {
    test('einfacher Patch-Sprung', () {
      expect(isNewerVersion('1.2.5', '1.2.4'), isTrue);
      expect(isNewerVersion('1.2.4', '1.2.5'), isFalse);
    });

    test('gleiche Version ist nicht neuer', () {
      expect(isNewerVersion('1.2.4', '1.2.4'), isFalse);
    });

    test('dev-Suffix zählt wie die Basisversion', () {
      expect(isNewerVersion('1.2.4-dev', '1.2.4'), isFalse);
      expect(isNewerVersion('1.2.5', '1.2.4-dev'), isTrue);
    });

    test('mehrstellige Segmente werden numerisch verglichen', () {
      expect(isNewerVersion('1.10.0', '1.9.9'), isTrue);
    });

    test('fehlende Segmente gelten als 0', () {
      expect(isNewerVersion('2.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.2', '1.2.0'), isFalse);
    });
  });

  FirmwareAsset asset(String name, {int? hwv}) => FirmwareAsset(
        version: '1.2.10',
        releaseName: 'v1.2.10',
        assetName: name,
        url: '',
        size: 1,
        hwVariant: hwv ?? hwvFromAssetName(name),
      );

  group('hwvFromAssetName', () {
    test('neue Namensform mit Kennung', () {
      expect(hwvFromAssetName('Fuellstandsensor_v1.2.10_hwv1003.bin'), 1003);
      expect(hwvFromAssetName('Fuellstandsensor_v1.2.10_HWV1001.bin'), 1001);
    });

    test('alte Namensform ohne Kennung', () {
      expect(hwvFromAssetName('Fuellstandsensor_v1.2.9.bin'), isNull);
    });
  });

  group('assetsForVariant', () {
    final alt = asset('Fuellstandsensor_v1.2.9.bin');
    final a1001 = asset('Fuellstandsensor_v1.2.10_hwv1001.bin');
    final a1003 = asset('Fuellstandsensor_v1.2.10_hwv1003.bin');
    final alle = [a1003, a1001, alt];

    test('V2-Sensor sieht nur die eigene Variante', () {
      expect(assetsForVariant(alle, 1003), [a1003]);
      expect(assetsForVariant(alle, 1001), [a1001]);
    });

    test('V1-Sensor sieht nur die alte Linie ohne Kennung', () {
      expect(assetsForVariant(alle, 1000), [alt]);
    });

    test('Sensor ohne HWV-Meldung wird wie V1 behandelt', () {
      expect(assetsForVariant(alle, null), [alt]);
    });

    test('unbekannte kuenftige Variante sieht nichts Falsches', () {
      expect(assetsForVariant(alle, 1002), isEmpty);
    });
  });
}
