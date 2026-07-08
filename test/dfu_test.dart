import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuellstand_app/dfu.dart';

/// Baut ein minimales "App-Image": Vektortabelle (SP, Reset-Vektor) + Füllung.
Uint8List fakeImage({
  int sp = 0x20010000,
  int pc = 0x08008101, // ungerade = Thumb, im App-Bereich
  int length = 4096,
}) {
  final b = Uint8List(length);
  final bd = ByteData.view(b.buffer);
  bd.setUint32(0, sp, Endian.little);
  bd.setUint32(4, pc, Endian.little);
  return b;
}

void main() {
  group('dfuCrc32', () {
    test('Referenzwert "123456789" (IEEE/zlib Check-Wert)', () {
      // Muss identisch zu dfu_common.c (Firmware/Bootloader) sein.
      expect(dfuCrc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('leere Eingabe', () {
      expect(dfuCrc32(const []), 0x00000000);
    });
  });

  group('DFU-Pakete', () {
    test('DFUS: Tag + Größe + CRC (little endian)', () {
      expect(buildDfuStart(0x00010203, 0xA1B2C3D4), [
        ...ascii.encode('DFUS'),
        0x03, 0x02, 0x01, 0x00, // Größe LE
        0xD4, 0xC3, 0xB2, 0xA1, // CRC LE
      ]);
    });

    test('DFUD: Tag + Offset + Nutzdaten', () {
      expect(buildDfuData(0x100, [1, 2, 3]),
          [...ascii.encode('DFUD'), 0x00, 0x01, 0x00, 0x00, 1, 2, 3]);
    });

    test('DFUE: nur Tag', () {
      expect(buildDfuEnd(), ascii.encode('DFUE'));
    });
  });

  group('validateAppImage', () {
    test('plausibles App-Image wird akzeptiert', () {
      expect(validateAppImage(fakeImage()), isNull);
    });

    test('zu kleine Datei wird abgelehnt', () {
      expect(validateAppImage(Uint8List(100)), isNotNull);
    });

    test('zu große Datei wird abgelehnt', () {
      expect(validateAppImage(fakeImage(length: dfuAppMax + 8)), isNotNull);
    });

    test('Stackpointer außerhalb RAM wird abgelehnt', () {
      expect(validateAppImage(fakeImage(sp: 0x08000000)), isNotNull);
    });

    test('Bootloader-Image (Reset-Vektor vor 0x08008000) wird abgelehnt', () {
      expect(validateAppImage(fakeImage(pc: 0x08000199)), isNotNull);
    });

    test('gerader Reset-Vektor (kein Thumb) wird abgelehnt', () {
      expect(validateAppImage(fakeImage(pc: 0x08008100)), isNotNull);
    });

    test('Reset-Vektor hinter dem App-Bereich wird abgelehnt', () {
      expect(validateAppImage(fakeImage(pc: 0x0801E801)), isNotNull);
    });
  });
}
