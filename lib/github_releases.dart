import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Timeouts für die GitHub-Zugriffe: ohne sie hängt der (nicht schließbare)
/// Ladedialog bei zäher Verbindung beliebig lange.
const Duration _apiTimeout = Duration(seconds: 15);
const Duration _downloadTimeout = Duration(seconds: 120);

/// true, wenn Version [a] neuer ist als [b] (semantischer Vergleich x.y.z).
/// Tolerant gegenüber Suffixen wie "-dev": je Segment zählen die führenden
/// Ziffern ("1.2.4-dev" == 1.2.4).
bool isNewerVersion(String a, String b) {
  int seg(String s) {
    final m = RegExp(r'^\d+').firstMatch(s.trim());
    return m != null ? int.parse(m.group(0)!) : 0;
  }

  final pa = a.split('.').map(seg).toList();
  final pb = b.split('.').map(seg).toList();
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Eine herunterladbare Firmware-Datei (.bin) aus einem GitHub-Release.
class FirmwareAsset {
  final String version; // z. B. "1.2.0" (aus Tag/Dateiname extrahiert)
  final String releaseName; // Anzeigename bzw. Tag des Releases
  final String assetName; // Dateiname der .bin
  final String url; // direkter Download-Link
  final int size; // Bytes
  final DateTime? published;
  final int? hwVariant; // aus "_hwv1003" im Dateinamen; null = Release
  // der V1-Linie (bis v1.2.9), deren Dateinamen keine Kennung tragen

  FirmwareAsset({
    required this.version,
    required this.releaseName,
    required this.assetName,
    required this.url,
    required this.size,
    this.published,
    this.hwVariant,
  });

  /// Kurze Anzeige, z. B. "V 1.2.0".
  String get label => 'V $version';
}

/// Hardware-Variante aus einem Asset-Dateinamen, z. B.
/// "Fuellstandsensor_v1.2.10_hwv1003.bin" -> 1003. null, wenn der Name
/// keine hwv-Kennung traegt (Releases der V1-Linie bis v1.2.9).
int? hwvFromAssetName(String name) {
  final m = RegExp(r'hwv(\d+)', caseSensitive: false).firstMatch(name);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Filtert Release-Assets auf die zum Sensor passende Hardware-Variante.
///
/// Regeln:
/// - Asset MIT hwv-Kennung: nur anbieten, wenn sie exakt der vom Sensor
///   gemeldeten Variante entspricht.
/// - Asset OHNE Kennung (V1-Linie bis v1.2.9): nur fuer Sensoren der
///   Variante 1000 oder ohne HWV-Meldung (alte V1-Firmware) anbieten.
///
/// So bekommt ein Sensor nie eine Firmware der falschen Variante
/// angeboten - bei 1001 gegen 1003 fiele die nicht als Fehler auf,
/// sondern nur als zehnfach falscher Fuellstand.
List<FirmwareAsset> assetsForVariant(
    List<FirmwareAsset> assets, int? sensorHwVariant) {
  final legacySensor = sensorHwVariant == null || sensorHwVariant == 1000;
  return assets
      .where((a) =>
          a.hwVariant == null ? legacySensor : a.hwVariant == sensorHwVariant)
      .toList();
}

/// Liest die Releases eines öffentlichen GitHub-Repos und liefert deren
/// .bin-Assets. Ohne Token (Rate-Limit 60/h pro IP – für den Zweck genug).
class GithubReleases {
  final String owner;
  final String repo;

  const GithubReleases(this.owner, this.repo);

  Future<List<FirmwareAsset>> fetchBinAssets() async {
    final uri = Uri.parse(
        'https://api.github.com/repos/$owner/$repo/releases?per_page=100');
    final resp = await http.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
    }).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('GitHub-API HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(resp.body) as List<dynamic>;
    final verRe = RegExp(r'\d+\.\d+\.\d+');
    final result = <FirmwareAsset>[];
    for (final rel in data) {
      final relName =
          (rel['name'] as String?)?.trim().isNotEmpty == true
              ? rel['name'] as String
              : (rel['tag_name'] as String? ?? '');
      final published = DateTime.tryParse(rel['published_at'] as String? ?? '');
      final assets = (rel['assets'] as List<dynamic>?) ?? const [];
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        if (name.toLowerCase().endsWith('.bin')) {
          final version = verRe.firstMatch(relName)?.group(0) ??
              verRe.firstMatch(name)?.group(0) ??
              relName;
          result.add(FirmwareAsset(
            version: version,
            releaseName: relName,
            assetName: name,
            url: a['browser_download_url'] as String? ?? '',
            size: (a['size'] as num?)?.toInt() ?? 0,
            published: published,
            hwVariant: hwvFromAssetName(name),
          ));
        }
      }
    }
    return result;
  }

  /// Lädt eine Datei herunter (folgt Weiterleitungen des CDN).
  static Future<Uint8List> download(String url) async {
    final resp = await http.get(Uri.parse(url)).timeout(_downloadTimeout);
    if (resp.statusCode != 200) {
      throw Exception('Download HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
}

/// Info über die neueste App-Version (APK) im GitHub-Release.
class AppUpdateInfo {
  final String version; // z. B. "1.3.5"
  final String apkUrl;
  final int size;
  const AppUpdateInfo(
      {required this.version, required this.apkUrl, required this.size});
}

/// Fragt das neueste Release des App-Repos ab und liefert dessen APK.
class GithubAppUpdate {
  final String owner;
  final String repo;

  const GithubAppUpdate(this.owner, this.repo);

  Future<AppUpdateInfo?> fetchLatest() async {
    final uri =
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
    final resp = await http.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
    }).timeout(_apiTimeout);
    if (resp.statusCode != 200) return null;
    final rel = jsonDecode(resp.body) as Map<String, dynamic>;
    final tag = (rel['tag_name'] as String?) ??
        (rel['name'] as String?) ??
        '';
    final ver = RegExp(r'\d+\.\d+\.\d+').firstMatch(tag)?.group(0) ?? tag;
    final assets = (rel['assets'] as List<dynamic>?) ?? const [];
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        return AppUpdateInfo(
          version: ver,
          apkUrl: a['browser_download_url'] as String? ?? '',
          size: (a['size'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return null;
  }
}
