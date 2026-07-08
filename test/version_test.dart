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
}
