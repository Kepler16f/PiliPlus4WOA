import 'dart:io' show Platform;

import 'package:PiliPlus/models/video/play/url.dart' show Volume;
import 'package:PiliPlus/utils/player_volume_gain.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart' show Player;

enum AudioNormalization {
  disable('禁用'),
  // ref https://github.com/KRTirtho/spotube/commit/da10ab2e291d4ba4d3082b9a6ae535639fb8f1b7
  dynaudnorm('预设 dynaudnorm', 'dynaudnorm=g=5:f=250:r=0.9:p=0.5'),
  loudnorm('预设 loudnorm', 'loudnorm=I=-16:LRA=11:TP=-1.5'),
  custom('自定义参数'),
  ;

  final String title;
  final String param;
  const AudioNormalization(this.title, [this.param = '']);

  static String getTitleFromConfig(String config) => switch (config) {
    '0' => disable.title,
    '1' => dynaudnorm.title,
    '2' => loudnorm.title,
    _ => config,
  };

  static String getParamFromConfig(String config) => switch (config) {
    '0' => disable.param,
    '1' => dynaudnorm.param,
    '2' => loudnorm.param,
    _ => config,
  };

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  static String parse(Volume? volume, String param) {
    if (volume != null && volume.isNotEmpty) {
      return param.replaceFirstMapped(
        loudnormRegExp,
        (i) =>
            'loudnorm=${volume.format(
              Map.fromEntries(
                i.group(1)!.split(':').map((item) {
                  final parts = item.split('=');
                  return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                }),
              ),
            )}',
      );
    } else {
      return param.replaceFirst(
        loudnormRegExp,
        AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
      );
    }
  }
}

mixin AudioNormalizationMixin {
  late final _audioNormalization = Pref.audioNormalization;
  late final enableAudioNormalization =
      Platform.isAndroid && _audioNormalization != '0';
  late final _param = AudioNormalization.getParamFromConfig(
    _audioNormalization,
  );

  static const _kNormalizationKey = 'lavfi-complex';

  Map<String, String>? audioFilterExtras(
    Volume? volume, {
    Map<String, String>? map,
  }) {
    if (!enableAudioNormalization) return map;
    var audioNormalization = AudioNormalization.parse(volume, _param);
    if (audioNormalization.isEmpty) return map;
    audioNormalization = '"[aid1] $audioNormalization [ao]"';
    if (map != null) {
      map[_kNormalizationKey] = audioNormalization;
      return map;
    }
    return {_kNormalizationKey: audioNormalization};
  }
}

/// 桌面端 >100% 音量的防削波处理（上游 d7df91620）。
///
/// 单独成 mixin 而不并入 [AudioNormalizationMixin]：上游把两者放在同一个
/// mixin 里，但本 fork 的 [PlPlayerController] 没有 mix in
/// [AudioNormalizationMixin]（它自己内联了归一化逻辑），并进去会与同名成员
/// 冲突。音量增益本身与上游一致。
mixin PlayerVolumeMixin {
  /// 当前生效的 af 增益串
  String? _alimiter;

  /// 上一次设置 af 的 player，用来发现 player 被重建（af 属性随之丢失）
  Player? _alimiterPlayer;

  /// 设置音量，[volume] 为线性倍数，1.0 即 100%。
  ///
  /// mpv 的 volume 属性是三次方曲线（`player/audio.c` 的 `audio_get_gain()`：
  /// `gain = pow(volume / 100, 3)`），且这层增益由 ao 在 af 链**之后**施加，
  /// 直接放大会把越过 0dBFS 的样值硬削波，听感粗糙发闷。
  ///
  /// 这里让 mpv 的 volume 恒 <= 100，把 >100% 的增益挪进 af 滤镜链，用
  /// alimiter 的 level_in 放大、再限幅在 0dBFS 以内。增益按 mpv 原来的三次方
  /// 曲线换算（v^3，即 60*log10(v) dB），听感响度与旧版一致，只是不再破音。
  ///
  /// 只用 alimiter 是因为 libavfilter 的 volume 滤镜并非所有 libmpv 构建都编
  /// 进去了，引用它会导致整条音频链初始化失败（静音）。
  Future<void>? setVolumeCapped(Player? player, double volume) {
    assert(volume >= 0);
    if (player == null) return null;
    final boost = playerVolumeBoostAf(volume);
    if (boost == null) {
      if (_alimiter != null && _alimiterPlayer == player) {
        player.setProperty('af', '');
        _alimiter = null;
        _alimiterPlayer = null;
      }
      return player.setVolume(volume * 100);
    } else {
      // 拖动音量时增益连续变化，重建滤镜链开销偏大，
      // 增益按 0.5dB 取整，值未变化时跳过
      if (_alimiter != boost || _alimiterPlayer != player) {
        player.setProperty('af', boost);
        _alimiter = boost;
        _alimiterPlayer = player;
      }
      return player.setVolume(100);
    }
  }

}
