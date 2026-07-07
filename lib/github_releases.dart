import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Eine herunterladbare Firmware-Datei (.bin) aus einem GitHub-Release.
class FirmwareAsset {
  final String version; // z. B. "1.2.0" (aus Tag/Dateiname extrahiert)
  final String releaseName; // Anzeigename bzw. Tag des Releases
  final String assetName; // Dateiname der .bin
  final String url; // direkter Download-Link
  final int size; // Bytes
  final DateTime? published;

  FirmwareAsset({
    required this.version,
    required this.releaseName,
    required this.assetName,
    required this.url,
    required this.size,
    this.published,
  });

  /// Kurze Anzeige, z. B. "V 1.2.0".
  String get label => 'V $version';
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
    });
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
          ));
        }
      }
    }
    return result;
  }

  /// Lädt eine Datei herunter (folgt Weiterleitungen des CDN).
  static Future<Uint8List> download(String url) async {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Download HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
}
