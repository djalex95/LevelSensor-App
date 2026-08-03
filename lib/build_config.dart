/// Verteilungskanal dieses Builds.
///
/// Wird beim Bauen gesetzt:
///   flutter build apk       --release --flavor github --dart-define=APP_CHANNEL=github
///   flutter build appbundle --release --flavor play   --dart-define=APP_CHANNEL=play
///
/// Ohne Angabe gilt "github", damit lokale Builds sich wie bisher verhalten.
/// Die Werte sind const, deshalb entfernt der Compiler die abgeschalteten
/// Zweige beim Uebersetzen (Tree Shaking) - im Play-Build ist der Updater
/// also nicht nur unsichtbar, sondern gar nicht erst enthalten.
class BuildConfig {
  BuildConfig._();

  static const String channel =
      String.fromEnvironment('APP_CHANNEL', defaultValue: 'github');

  /// true im Build fuer den Google Play Store.
  static const bool isPlay = channel == 'play';

  /// In-App-Updater: neueste APK aus dem GitHub-Release laden und dem
  /// System-Installer uebergeben.
  ///
  /// Nur im GitHub-Build. Google Play verbietet Apps, die sich am
  /// Play-Update-Mechanismus vorbei selbst aktualisieren (Richtlinie
  /// "Geraete- und Netzwerkmissbrauch"); im Play-Build kommen App-Updates
  /// ueber den Store. Das Firmware-Update des Sensors (.bin ueber BLE)
  /// ist davon nicht betroffen und bleibt in beiden Builds aktiv.
  static const bool selfUpdate = !isPlay;
}
