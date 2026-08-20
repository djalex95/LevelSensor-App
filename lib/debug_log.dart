import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Verbindungsprotokoll mit echter Uhrzeit, das den App-Neustart uebersteht.
///
/// Die Konsole im Entwicklermodus zeigt nur, was seit dem letzten App-Start
/// passiert ist. Fehler, die erst nach Stunden auftreten - etwa eine
/// Kopplung, die sich ueber Nacht verabschiedet - sind damit nicht zu
/// fassen: bis man hinschaut, ist die App laengst neu gestartet. Deshalb
/// schreibt dieses Protokoll jede Zeile zusaetzlich in eine Datei.
///
/// Bewusst schmal gehalten: aufgezeichnet wird, was mit der Verbindung und
/// der Kopplung passiert, nicht der Nutzdatenverkehr.
class DebugLog {
  DebugLog._();

  /// So viele Zeilen bleiben erhalten. Bei ein paar Ereignissen je
  /// Verbindungsversuch reicht das fuer mehrere Tage Betrieb.
  static const int _maxLines = 500;
  static const String _fileName = 'verbindungen.log';

  static File? _file;
  static final List<String> _lines = <String>[];
  static Future<void> _queue = Future<void>.value();
  static int _appended = 0;

  /// Zaehlt jede Aenderung hoch, damit die Anzeige sich auffrischen kann.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Beim App-Start aufrufen: liest den bisherigen Stand aus der Datei.
  static Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_fileName');
      _file = f;
      if (await f.exists()) {
        final all = (await f.readAsString())
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        _lines
          ..clear()
          ..addAll(all.length > _maxLines
              ? all.sublist(all.length - _maxLines)
              : all);
        if (all.length > _maxLines) {
          await f.writeAsString('${_lines.join('\n')}\n');
        }
      }
    } catch (_) {
      /* Ohne Datei laeuft alles wie bisher, nur ohne Gedaechtnis. */
    }
    add('--- App gestartet ---');
  }

  /// Eine Zeile anhaengen. Schreibt im Hintergrund und wirft nie.
  static void add(String text) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final line = '${n.year}-${two(n.month)}-${two(n.day)} '
        '${two(n.hour)}:${two(n.minute)}:${two(n.second)}  $text';

    _lines.add(line);
    while (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
    revision.value++;

    final f = _file;
    if (f == null) return;
    _queue = _queue.then((_) async {
      try {
        if (++_appended >= 100) {
          /* Ab und zu die ganze Datei neu schreiben, sonst waechst sie
           * endlos weiter, waehrend die Anzeige nur den Schwanz zeigt. */
          _appended = 0;
          await f.writeAsString('${_lines.join('\n')}\n');
        } else {
          await f.writeAsString('$line\n', mode: FileMode.append);
        }
      } catch (_) {}
    });
  }

  static List<String> get lines => List<String>.unmodifiable(_lines);

  static String get text => _lines.join('\n');

  static Future<void> clear() async {
    _lines.clear();
    _appended = 0;
    revision.value++;
    final f = _file;
    if (f == null) return;
    _queue = _queue.then((_) async {
      try {
        await f.writeAsString('');
      } catch (_) {}
    });
    await _queue;
  }
}
