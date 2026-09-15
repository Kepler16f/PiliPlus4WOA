enum BottomControlType {
  playOrPause,
  pre,
  next,
  time,
  episode,
  fit,
  subtitle,
  speed,
  fullscreen,
  viewPoints,
  superResolution,
  dmChart,
  qa,
  aiTranslate,

  /// 「窗口全屏」= 把窗口最大化（保留标题栏，占满屏幕），
  /// 与 [fullscreen]（无边框原生全屏）区分。
  /// 追加在末尾：这个枚举不落盘（只用 .name / switch），但保持既有值不动更安全。
  windowFullscreen,
}
