import 'dart:math' show max, min;

/// Pure PiP danmaku sizing & throttling policy (kept free of storage/UI imports
/// so it can be unit-tested standalone without patched Flutter SDK symbols).
abstract final class DanmakuPipPolicy {
  /// Maximum non-self danmaku accepted per 100ms bucket in PiP mode vs normal.
  static int maxAddPerTick({required bool isPipMode}) => isPipMode ? 4 : 10;

  /// Effective danmaku font size: scales down proportionally in PiP so tracks
  /// remain legible in a compact 280px window while cutting texture pixel area.
  static double effectiveFontSize({
    required bool notFullscreen,
    required double fontScale,
    required double fontScaleFS,
    required bool isDesktop,
    bool isPipMode = false,
  }) {
    final scale = notFullscreen ? fontScale : fontScaleFS;
    if (isPipMode) {
      final pipFactor = isDesktop ? 0.75 : 0.85;
      return max(12.0, 15.0 * scale * pipFactor);
    }
    return 15.0 * scale;
  }

  /// Effective stroke width: capped at 2.0 in PiP to reduce outline overhead
  /// on smaller text.
  static double effectiveStrokeWidth({
    required double strokeWidth,
    bool isPipMode = false,
  }) {
    return isPipMode ? min(strokeWidth, 2.0) : strokeWidth;
  }

  /// Disable massive-mode overlap stacking in PiP windows.
  static bool effectiveMassiveMode({
    required bool massiveMode,
    bool isPipMode = false,
  }) {
    return isPipMode ? false : massiveMode;
  }
}
