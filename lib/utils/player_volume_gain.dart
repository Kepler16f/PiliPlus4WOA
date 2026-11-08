import 'dart:math' as math;

/// 桌面端 >100% 音量对应的防削波增益滤镜串；<=100% 返回 null。
///
/// mpv 的 volume 属性是三次方曲线（`player/audio.c` 的 `audio_get_gain()`：
/// `gain = pow(volume / 100, 3)`），等效分贝为 `20*log10(v^3) = 60*log10(v)`。
/// 这里把增益按 0.5dB 取整，重建滤镜链的开销更小，听感差异可忽略。
///
/// 滤镜串交给 alimiter：`level_in` 是输入增益，`limit=1` 即限幅在 0dBFS，
/// `level=0` 关闭 alimiter 的自动电平（不做归一化）。
///
/// [volume] 为线性倍数，1.0 即 100%。
String? playerVolumeBoostAf(double volume) {
  if (volume <= 1.0) return null;
  final db = (60 * math.log(volume) / math.ln10 * 2).round() / 2;
  final gain = math.pow(10, db / 20).toDouble();
  return 'alimiter=level_in=${gain.toStringAsFixed(3)}:limit=1:level=0';
}
