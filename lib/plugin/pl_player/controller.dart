import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show HapticFeedback, DeviceOrientation;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type? type});

class PlPlayerController with BlockConfigMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  final playerStatus = PlPlayerStatus(.playing);

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress =>
      isSeeking.value && hoverDx == null ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;

  /// 当前是「窗口全屏」（应用内铺满窗口）而非「原生全屏」（无边框跳出窗口）。
  ///
  /// ARM64 修改版（2026-09-18）：这两种全屏原本共用一个 [isFullScreen] 布尔，
  /// 于是「窗口全屏 → 全屏」被 `isFullScreen.value == status` 提前 return 挡掉、
  /// 「全屏 → 窗口全屏」又会直接退到普通窗口 —— 两个按钮被绑在一起。
  /// 现在把形态拆出来单独记，两者可以互相切换：
  ///   - [isFullScreen] 仍然表示「处于某种全屏」（页面布局只看它，语义不变）；
  ///   - 本字段只在为真时才有意义，表示那种全屏是「窗口全屏」。
  final RxBool isWindowFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 「自愈重开」专属的进行中标记（见 [_reloadAtCurrentPosition]）。
  ///
  /// 为什么要和 [isBuffering] 分开（2026-09-17 修）：
  /// 画面区本来有两套加载指示 —— 常规缓冲指示（`PlVideoPlayer` 里那个
  /// 「加载中… / 已缓冲时长」转圈）和自愈指示（`PlPlayerLoadingIndicator`）。
  /// 两者都盯着 `isBuffering`，于是「拖动进度条 → 跳转要重新缓冲」与
  /// 「看门狗自愈重开」这两件完全不同的事会**同时**点亮两个指示，屏幕上出现
  /// 两个叠在一起的转圈（用户报的「两个动画重叠」）。
  /// 现在自愈指示只认这个旗标、常规指示排除它，两者从构造上互斥：
  /// 拖动进度条只会看到常规缓冲圈，自愈只会看到「正在恢复播放…」。
  final RxBool isRecovering = false.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  bool _pipTransitioning = false;
  Timer? _displayBoxDebounce;
  Rect? _lastWindowBounds;
  // 上游 2.1.6（#2997 画中画窗口记忆）：跨进入/退出记忆 PiP 窗口的位置与尺寸，
  // 让竖屏视频退出、再进横屏视频时，PiP 窗口按新比例就地调整而不是弹回默认尺寸。
  static Rect? _lastPipBounds;

  Rect _adjustPipBounds(Rect lastRect, Size size, double aspectRatio) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(
              lastSize.width,
              _lastWindowBounds?.size.height ?? size.height,
            );
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }
      return _lastPipBounds = Rect.fromLTWH(
        lastRect.left,
        lastRect.top,
        width,
        height,
      );
    }
    return _lastPipBounds = Rect.fromLTWH(
      lastRect.left,
      lastRect.top,
      lastSize.width,
      lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds() {
    if (isDesktopPip) {
      windowManager.getBounds().then((rect) {
        if (isDesktopPip) _lastPipBounds = rect;
      });
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() async {
    final bounds = _lastWindowBounds;
    // 诊断：确认按钮点击是否真的走到了这里、以及窗口恢复参数是否有效。
    // （用户报过「退出画中画按钮点击没反应」——若日志无此行，问题在点击层面；
    //   有此行但窗口没恢复，问题在这个函数里。）
    Utils.reportError('pip: exitDesktopPip bounds=$bounds', null);
    isDesktopPip = false;
    _pipTransitioning = true;
    _displayBoxDebounce?.cancel();
    final player = _videoPlayerController;
    if (player is NativePlayer) {
      try {
        player.setProperty('framedrop', 'vo');
      } catch (_) {}
    }
    try {
      if (showWindowTitleBar) {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
      await windowManager.setMinimumSize(const Size(400, 700));
      await windowManager.setAspectRatio(0);
      if (bounds != null) {
        await windowManager.setBounds(bounds);
      }
      await setAlwaysOnTop(false);
      Utils.reportError('pip: exitDesktopPip done', null);
    } catch (e) {
      Utils.reportError('pip: exitDesktopPip failed: $e', null);
    } finally {
      _pipTransitioning = false;
      unawaited(_applyVideoOutputSize());
    }
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    Utils.reportError('pip: enterDesktopPip', null);
    isDesktopPip = true;
    _pipTransitioning = true;
    _displayBoxDebounce?.cancel();
    final player = _videoPlayerController;
    if (player is NativePlayer) {
      try {
        player.setProperty('framedrop', 'no');
      } catch (_) {}
    }

    try {
      _lastWindowBounds = await windowManager.getBounds();

      if (showWindowTitleBar) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      }

      const shortSide = 280.0;
      const minShortSide = 160.0;
      final Size size;
      final Size minimumSize;
      final state = videoPlayerController!.state;
      int width = state.width;
      int height = state.height;
      if (width == 0) {
        width = this.width ?? 16;
      }
      if (height == 0) {
        height = this.height ?? 9;
      }
      final aspectRatio = width / height;
      if (height > width) {
        size = Size(shortSide, shortSide / aspectRatio);
        minimumSize = Size(minShortSide, minShortSide / aspectRatio);
      } else {
        size = Size(shortSide * aspectRatio, shortSide);
        minimumSize = Size(minShortSide * aspectRatio, minShortSide);
      }

      await windowManager.setMinimumSize(minimumSize);
      await setAlwaysOnTop(true);
      final pipBounds = _lastPipBounds;
      if (pipBounds != null) {
        await windowManager.setBounds(
          _adjustPipBounds(pipBounds, size, aspectRatio),
        );
      } else {
        await windowManager.setSize(size);
      }
      await windowManager.setAspectRatio(width / height);
    } finally {
      _pipTransitioning = false;
      unawaited(_applyVideoOutputSize());
    }
  }

  void toggleDesktopPip() {
    Utils.reportError('pip: toggleDesktopPip isDesktopPip=$isDesktopPip', null);
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  int? tmpSubtitlePaddingB;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableScrollVolume = Pref.enableScrollVolume;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    // 上游 fix #3323：窗口内边距变化后，之前为「控制条显示」临时抬高的字幕
    // 底部间距必须作废，否则字幕会一直停在抬高后的位置。
    tmpSubtitlePaddingB = null;
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    updateSubtitleStyle();
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  // 上游 #3315：这个回调是全局静态的，视频页与直播间会互相覆盖。加一个
  // 「归属标记」，页面就能判断当前回调是不是自己的（见 live_room 的
  // _onPopPopupRoute），避免误把别人的播放回调清掉。
  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;

  static PlayCallback? _playCallBack;

  // ARM64 修改版：断流兜底回调，由视频页注册（重新拉取播放链接）。
  static PlayCallback? _reloadCallBack;
  static void setReloadCallBack(PlayCallback? reloadCallBack) {
    _reloadCallBack = reloadCallBack;
  }

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  /// ARM64 修改版：让当前视频页重新拉取播放链接并续播。
  /// 返回回调的 Future，便于调用方（如自动重连）等待完成。
  static Future<void>? refreshPlayUrl() => _reloadCallBack?.call();

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus.value;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    if (controlsLock.value) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
          $Runnable(run: _onUserLeaveHint),
        );
      } else {
        _isAutoEnterPip = true;
      }
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  late final _audioNormalization = Pref.audioNormalization;
  late final enableAudioNormalization =
      Platform.isAndroid && _audioNormalization != '0';
  late final String _audioNormalizationParam =
      AudioNormalization.getParamFromConfig(_audioNormalization);

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
    int? rotate,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化视频倍速
      // _playbackSpeed.value = speed;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      // 换了片源 → 丢掉「长按持续后退」攒下来的目标位置（见 multiBackwardStart）。
      _multiBackwardTargetMs = null;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume, rotate);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }
      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      // 用 effectiveVideoSync 而不是 videoSync：桌面端会把 display-* 换成 audio，
      // 原因见 storage_pref.dart 里 effectiveVideoSync 的注释。
      'video-sync': Pref.effectiveVideoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
      'volume-max': (PlatformUtils.isDesktop ? 100.0 : kMaxVolume).toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    // ARM64 修改版：Windows 上兜底 keep-open/force-window（保持原有行为）。
    // 注：mpv 没有 'log-level' 选项（此前误加，已被 mpv 静默忽略，现移除）；
    // 日志等级由下方 PlayerConfiguration.logLevel 控制。
    if (Platform.isWindows) {
      opt['keep-open'] = 'yes';
      opt['force-window'] = 'no';
      opt['ao'] = 'wasapi';
      opt['audio-stream-silence'] = 'yes';
      opt['audio-exclusive'] = 'no';
      opt['audio-client-name'] = 'PiliPlus';
    }

    // ARM64 修改版：关闭解码器**帧线程**（frame threading），规避播放中闪退。
    //
    // 根因（2026-09，capstone 反汇编 libmpv-2.dll + 4 份崩溃 dump 逐帧回溯）：
    // 闪退点是 libmpv+0x50A2D4 的 `ldadd w9, w8, [x8]`（ARMv8.1 原子加），
    // 即 av_buffer_replace 内联的 av_buffer_ref 引用计数自增，而 buf->buffer
    // 已被释放（NULL）→ use-after-free。调用链：
    //   mpv 解码线程 → pthread_frame.c update_context_from_thread
    //   → h264_slice.c ff_h264_update_thread_context
    //   → h264_picture.c ff_h264_replace_picture
    //   → av_frame_replace → av_buffer_replace → 崩溃
    // 即 **H.264 帧线程上下文同步**时复制上一帧线程的 DPB，踩到已释放帧缓冲。
    // 实测关闭硬解（软解）后仍崩溃，说明与 D3D11VA 硬解无关。
    //
    // 关键：要关的是「帧线程」，不是「所有线程」。早先的做法是把解码线程数
    // 设为 1（vd-lavc-threads=1 + hwdec-threads=1），帧线程确实没了，但连
    // **切片线程/解码器内部线程**也一并没了 —— 软解退化成单线程，1080p 跟不上，
    // 表现就是「画面卡住、声音继续」（seek 回去重建解码器后短暂恢复）。
    // AV1 尤其致命：本平台 AV1 没有硬解（日志里 d3d11 / dxva2_vld / cuda 全部
    // 初始化失败），只能走 dav1d 软解，而 dav1d 的线程数取自 avctx->thread_count，
    // 设成 1 等于让 dav1d 单线程解 1080p。
    //
    // 正确做法：用 libavcodec 的 AVOption `thread_type=slice`（经 mpv 的
    // --vd-lavc-o 透传到 AVCodecContext，见 mpv vd_lavc.c 的 mp_set_avopts()，
    // 在 avcodec_open2 之前生效）。ff_validate_thread_parameters() 只有在
    // thread_type 含 FF_THREAD_FRAME 时才会走 ff_frame_thread_init()，因此
    // thread_type=slice 时帧线程被关掉（不含 FF_THREAD_FRAME），上面那条崩溃
    // 路径不存在；同时 thread_count 保持默认（多线程），切片线程/ dav1d
    // 内部线程照常工作，不会出现跑不动的单线程软解。
    // 注意不要设置 vd-lavc-threads / hwdec-threads，否则又会把线程数压到 1。
    // 若出现闪退可在「设置 → 视频」中重新打开该项（2026-10-14 起默认关闭：
    // 触发崩溃的帧线程 bug 属于 2026-09 期 libmpv 构建，现已升级）。
    if (Pref.disableFrameThreading) {
      opt['vd-lavc-o'] = 'thread_type=slice';
    }

    // 别让 mpv 因为几帧坏数据就把硬件解码器降级为软件解码。
    //
    // 与帧线程开关**解耦**（2026-10-14）：它过去长在同一个 if 里，于是「默认
    // 关闭帧线程禁用」会顺带把这条保护也关掉 —— 但它的目的和帧线程无关。
    //
    // mpv 默认在「连续 3 次解码失败」后判定硬解失效并切到下一个解码方式
    // （最终是软解），见 mpv vd_lavc.c: handle_err() 累加 hwdec_fail_count，
    // 达到 hwdec_opts->software_fallback（默认 3）即置 hwdec_failed 触发
    // force_fallback()。CDN 断流只要产生几帧坏数据（日志里的
    // Invalid NAL unit size / Error splitting the input into NAL units）
    // 就足以触发——实测的坏包会连续产生 3~6 个解码错误，正好踩线。
    // 放宽到 30（约 30fps 下 1 秒的连续错误）：偶发坏包不再触发降级，坏帧
    // 被丢弃、等到关键帧自然恢复；硬件解码器真的坏掉时（持续错误）仍会在
    // 约 1 秒后降级兜底。硬解在初始化阶段失败不受影响（那条路径正常回退）。
    opt['hwdec-software-fallback'] = '30';

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);
    _appliedSurfaceWidth = null;
    _appliedSurfaceHeight = null;
    _displayBox = null;

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        // GPU presentation is independent of hardware video decoding.
        enableHardwareAcceleration: Platform.isWindows || hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: Platform.isWindows ? (hwdec ?? 'no') : hwdec,
      ),
    );

    // ARM64 修改版（2026-09-14）：这里**曾经**在控制器建好后额外做一次
    //     player.setProperty('video-sync', Pref.effectiveVideoSync);
    // 现已删除，原因是它在实机上被证明有害无益：
    //
    //   1) 没有作用：实机 stall 日志里 `vsync-ratio=null`、`mistimed-frame-count=null`
    //      —— 这两个属性只在 `--video-sync=display-*` 下才有值，说明实际生效的
    //      同步方式**本来就不是 display-***（media_kit_video 原生 VideoOutput 构造里
    //      写死的 audio 已经赢了）。既然本来就不是 display-*，再"纠正"一次纯属多余。
    //   2) 有副作用：`video-sync` 是影响视频输出的选项，运行时改它可能让 mpv 重建
    //      VO/渲染上下文。而 media_kit_video 的 ANGLE 表面尺寸是在
    //      `CheckAndResize() → GetVideoWidth/GetVideoHeight` 里、通过读
    //      `video-out-params` 决定的，一旦这个时机 VO 没有有效的视频参数，
    //      `required_width < 1` 就直接 return，表面会停在初始的 1x1，客户端拿到的
    //      就是一张永远不变的黑图（画面上表现为「只有声音和弹幕、画面全黑」，
    //      而 mpv 侧可能连一次丢帧都没有 → 看门狗也看不见）。
    //      这正是本次用户报的两个新症状（前台全屏卡死且无日志 / 竖屏视频黑屏）
    //      在时间上与本次改动吻合的原因。
    //
    // 结论：不在运行时动 `video-sync`。选项值仍由 _initPlayer 里的
    // Pref.effectiveVideoSync 决定（见 storage_pref.dart 的注释），那是 loadfile
    // 之前设置，安全。

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
    int? rotate,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
      // 桌面端旋转画面（上游 9378093b0）：直接交给 mpv 的 video-rotate。
      if (rotate != null) 'video-rotate': rotate.toString(),
      // ARM64 修改版设计决策（2026-09）：禁用 ffmpeg 层断点续传自愈。
      //
      // 原因：CDN 断流后让 ffmpeg 在同一 demuxer 对象内无缝续传，会产生
      // 数据空洞（画面冻结、声音继续）并可能把坏数据灌进解码器；两次崩溃
      // dump 已证实（libmpv+0x50A2D4 / +0x507B94：同一函数、同一指令
      // str w8,[x8,x9,lsl#2]，[x20] 成员为 NULL 的确定性空指针写，两个不同
      // mpv 构建同址崩溃，且崩溃先于任何 mpv 错误日志）。坏态续命会把
      // 确定性崩溃喂给解码器，升级 libmpv 无法解决。
      //
      // 改为：断流干净失败 → 错误事件传导到 Dart → 自动重连模块重新拉取
      // 全新播放链接并全新 loadfile（全新 demuxer / 全新 decoder / 干净状态）。
      // 因此不再设置 stream-lavf-o 的 reconnect* 选项（reconnect_streamed
      // 等在上一个构建已验证会被拆成顶层选项，且自愈路径正是崩溃根源）。
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      if (enableAudioNormalization) {
        final String audioNormalization;
        if (volume != null && volume.isNotEmpty) {
          audioNormalization = _audioNormalizationParam.replaceFirstMapped(
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
          audioNormalization = _audioNormalizationParam.replaceFirst(
            loudnormRegExp,
            AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
          );
        }
        if (audioNormalization.isNotEmpty) {
          extras['lavfi-complex'] = '"[aid1] $audioNormalization [ao]"';
        }
      }
    }

    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      return ctr.open(
        ctr.current.last.copyWith(start: ctr.state.position),
        play: true,
      );
    }
    return null;
  }

  // ARM64 修改版：判断是否为「播放中途网络连接被重置/断流」类错误。
  // mpv 对这些错误的字符串前缀不固定（可能是 tls: / ffmpeg: tls: /
  // Error number -10054 / curl:），统一用 contains 匹配。
  //
  // 注意：禁用 ffmpeg 断点续传自愈后，这类错误会**干净地**传导到这里并
  // 触发自动重连（全新 URL + 全新 loadfile / 全新解码器），而非在坏态上
  // 崩溃。'transfer failed'（ffmpeg curlproto 的 CURLE_RECV_ERROR）是断流
  // 主报错信息，必须匹配，否则断流后会静默卡死。
  static bool _isNetworkResetError(String message) {
    return message.contains('tls: IO error') ||
        message.contains('Error number -10054') ||
        message.contains('Connection reset') ||
        message.contains('ffurl_read returned') ||
        message.contains('Stream ends prematurely') ||
        message.contains('transfer failed') ||
        message.contains('Invalid NAL unit size') ||
        message.contains('Error splitting the input into NAL units') ||
        message.contains('partial file') ||
        message.contains('missing picture in access unit');
  }

  static bool _isAudioError(String message) {
    return message.contains('AUDCLNT_E_') ||
        message.contains('Error initializing device') ||
        message.contains('Could not open/initialize audio device') ||
        message.contains('Failed to initialize audio driver') ||
        message.contains('Error decoding audio') ||
        message.contains('decode_band_types: Input buffer exhausted');
  }

  DateTime _lastAudioErrorRecoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _audioErrorRecoverCount = 0;

  void _onAudioStreamError(String message) {
    if (_playerCount == 0 || isRecovering.value || onlyPlayAudio.value) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAudioErrorRecoverAt) < const Duration(seconds: 4)) {
      return;
    }
    if (now.difference(_lastAudioErrorRecoverAt) >
        const Duration(seconds: 20)) {
      _audioErrorRecoverCount = 0;
    }
    _lastAudioErrorRecoverAt = now;
    _audioErrorRecoverCount++;
    Utils.reportError(
      'audio error recovery #$_audioErrorRecoverCount: $message',
      null,
    );
    _reloadAudioOutput();
  }

  // 是否已有一次自动重连在进行中（防止重连风暴/重复重连）
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  // 重连冷却：上次发起重连的时间。若距上次不足冷却期则忽略本次错误，
  // 避免 CDN 短时间反复断流时触发重连风暴（每次重连失败都会堆积泄漏）。
  DateTime _lastReconnectAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _reconnectCooldown = Duration(seconds: 10);
  // 用户是否主动暂停过。play() 清、pause() 置。

  // 已经下发过的视频输出表面尺寸，避免重复下发。
  int? _appliedSurfaceWidth;
  int? _appliedSurfaceHeight;

  /// 把视频输出（ANGLE 表面 + Flutter 纹理）的尺寸设成 mpv 报的显示尺寸。
  ///
  /// 这是**竖屏视频黑屏的修复**，机制如下（2026-09-14 由实机日志确认）：
  ///
  /// 实机证据：竖屏视频那张兜底日志 `video surface: rect not usable ...` 只对竖屏
  /// 触发、横屏从不触发，说明 `rect` 对竖屏始终无效；而 `rect` 是原生
  /// `VideoOutput::Resize()` 下发 `texture_update_callback_` 才有的 —— 也就是
  /// **`Resize()` 从未带着有效尺寸执行过**，ANGLE 表面一直停在构造时的初始尺寸。
  /// 于是 `VideoOutput::Render()` 里 `mpv_render_context_render()` 渲染到那个尺寸的
  /// FBO 里，Flutter 读到的共享 D3D 纹理是**未初始化内容 —— 实测就是 0x80 灰**，
  /// 正好对上用户描述的「竖屏灰色框、没有画面」。
  /// （注意不是旋转问题：日志里竖屏是 `rotate=0 / dw=1080 / dh=1920`，没有对调。）
  ///
  /// 为什么调用 setSize 能修：native 的 `SetSize()` 会直接给 `width_`/`height_` 赋值，
  /// 而 `GetVideoWidth()/GetVideoHeight()` 一旦发现 `width_` 有值就**直接返回它、
  /// 不再去查 `video-out-params`**。于是下一帧 `CheckAndResize()` 一定得到
  /// 「required != current」，必然执行 `Resize()` → 表面与纹理被重建为正确尺寸。
  /// 换句话说：这条路径**绕开了那个让 Resize 不发生的未知原因**。
  ///
  /// 代价最低的「恢复画面」手段也是它：整条路径**完全不动播放位置**，
  /// 所以即使误判（例如画面本来就是一帧静止画面）也只是白白重建一次表面。
  ///
  /// 尺寸选择（ARM64 修改版 2026-10-14）：**不再恒等于片源尺寸**，而是跟随
  /// 实际显示区域（[_displayBox]）按阶梯降采样。
  /// 实机证据（PiP 卡顿）：`rect=0,0,1920x1080` 而 PiP 窗口只有 280px —— 旧写法
  /// 让 mpv 每帧仍按 1080p 渲染，而 `hwdec-current=d3d11va-copy`（ANGLE/GL 输出
  /// 下拿不到零拷贝）意味着每帧还要 GPU→CPU 回读 + 上传，ARM64 上这份开销就是
  /// 「小窗/后台播放卡顿、与网络无关」的来源；帧级追踪也显示这段时间
  /// `draw/mark` 在涨而 `cb=0`（引擎根本没来取帧）。
  /// 阶梯量化（而非逐像素跟随）是为了：拖动窗口时不会每帧重建表面/纹理。
  /// 宽高比保持方式：两个维度乘同一个系数，只有取整带来的 ≤1px 误差 ——
  /// 绝不能各自独立取显示框的宽高，否则 mpv 会把画面画进错比例的 FBO（变形）。
  static const List<double> _surfaceScaleSteps = [
    1.0,
    0.75,
    0.5,
    0.35,
    0.25,
  ];
  Size? _displayBox;
  double _displayBoxDpr = 1.0;

  /// 由播放视图在 build 时回传「视频区域多大」。
  /// 只在真的变了时才重算并下发，避免每帧 build 引发表面重建。
  void setDisplayBox(Size box, double devicePixelRatio) {
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final old = _displayBox;
    if (old != null &&
        old.width == box.width &&
        old.height == box.height &&
        _displayBoxDpr == dpr) {
      return;
    }
    _displayBox = box;
    _displayBoxDpr = dpr;
    if (_pipTransitioning) {
      return;
    }
    if (_appliedSurfaceWidth == null || _appliedSurfaceHeight == null) {
      unawaited(_applyVideoOutputSize());
      return;
    }
    _displayBoxDebounce?.cancel();
    _displayBoxDebounce = Timer(const Duration(milliseconds: 150), () {
      if (_playerCount != 0) {
        unawaited(_applyVideoOutputSize());
      }
    });
  }

  /// 目标倍率：显示区域所需的倍率，**向上**取整到阶梯里不小于它的最小一档
  /// （保证表面 ≥ 显示像素，不糊），并且永远 ≤ 1.0（不用小窗去放大片源）。
  double _targetSurfaceScale(int dw, int dh) {
    final box = _displayBox;
    if (box == null || box.width < 1 || box.height < 1) return 1.0;
    final needed = min(
      box.width * _displayBoxDpr / dw,
      box.height * _displayBoxDpr / dh,
    );
    if (needed >= 1.0) return 1.0;
    // 升序找第一个 >= needed 的档位（阶梯是降序声明的，所以反向遍历）。
    for (final step in _surfaceScaleSteps.reversed) {
      if (step >= needed) return step;
    }
    return 1.0;
  }

  Future<void> _applyVideoOutputSize() async {
    final ctr = _videoController;
    if (ctr == null) return;
    var srcW = _intProp('video-out-params/dw');
    var srcH = _intProp('video-out-params/dh');
    if (srcW == null || srcH == null || srcW < 1 || srcH < 1) return;
    final rotate = _intProp('video-out-params/rotate');
    if (rotate == 90 || rotate == 270) {
      (srcW, srcH) = (srcH, srcW);
    }
    final scale = _targetSurfaceScale(srcW, srcH);
    // 偶数化：D3D/ANGLE 对纹理尺寸有对齐要求，mpv 侧也按偶数处理更稳。
    int even(double v) {
      final r = v.round() & ~1;
      return r < 2 ? 2 : r;
    }

    final w = even(srcW * scale);
    final h = even(srcH * scale);
    if (_appliedSurfaceWidth == w && _appliedSurfaceHeight == h) {
      return;
    }
    try {
      final applied = ctr.setSize(width: w, height: h);
      if (applied != null) await applied;
      if (identical(ctr, _videoController)) {
        _appliedSurfaceWidth = w;
        _appliedSurfaceHeight = h;
      }
    } catch (error, stack) {
      Utils.reportError('video surface resize failed: $error', stack);
    }
  }

  // 网络断连自动重连（含多次尝试）
  void _scheduleReconnect() {
    if (_reconnecting) return;
    final now = DateTime.now();
    if (now.difference(_lastReconnectAt) < _reconnectCooldown) return;
    _lastReconnectAt = now;
    _reconnecting = true;
    _reconnectAttempts = 0;
    _tryReconnect();
  }

  // 读取 mpv 属性（判定/诊断用）。读不到返回 null。
  String? _mpvProp(String name) {
    final player = _videoPlayerController;
    if (player is! NativePlayer) return null;
    try {
      final v = player.getProperty(name);
      return v.isEmpty ? null : v;
    } catch (_) {
      // 播放器已释放等
      return null;
    }
  }

  // 读取 mpv 的整数属性（判定/诊断用）。读不到或非整数返回 null。
  int? _intProp(String name) {
    final raw = _mpvProp(name);
    return raw == null ? null : int.tryParse(raw);
  }

  /// 给 mpv 发一条命令（自愈用）。失败/播放器已释放时静默忽略。
  ///
  /// 与 [setProperty] 的分工：这里只用于**命令**（如 `audio-reload`），
  /// 属性读写走 `_mpvProp` / [setProperty]。
  void _mpvCommand(List<String> args) {
    final player = _videoPlayerController;
    if (player is! NativePlayer) return;
    try {
      unawaited(player.command(args));
    } catch (_) {
      // 播放器已释放等
    }
  }

  /// 音频输出停摆时的最轻恢复：让 mpv 重建音频输出（AO）。
  void _reloadAudioOutput() {
    final player = _videoPlayerController;
    if (player is NativePlayer) {
      try {
        final device = _mpvProp('audio-device');
        player
          ..setProperty(
            'audio-device',
            (device == null || device.isEmpty) ? 'auto' : device,
          )
          ..setProperty('aid', 'no');
        _mpvCommand(const ['ao-reload']);
      } catch (_) {}
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_playerCount == 0) return;
        try {
          final device = _mpvProp('audio-device');
          player
            ..setProperty(
              'audio-device',
              (device == null || device.isEmpty) ? 'auto' : device,
            )
            ..setProperty('aid', 'auto');
          _mpvCommand(const ['ao-reload']);
        } catch (_) {}
      });
    }
  }

  Future<void> _tryReconnect() async {
    if (_playerCount == 0) {
      _reconnecting = false;
      return;
    }
    _reconnectAttempts++;
    // 播放已恢复则不再继续。注意不能只看 playerStatus.isPlaying：画面冻结时
    // 音频照常播放、状态仍是 playing，旧写法会把这类重连直接丢弃（等于完全
    // 放弃自愈）。这里要求「画面也在推进」才算恢复。
    // 自愈重开正在进行：它自己会把播放拉起来，这里再插一次 open 只会互相
    // 打断（确认窗口 4s→12s 后这段重合时间明显变长，更容易撞上）。
    // 让出这一次并清旗标，之后仍可再重连。
    if (playerStatus.isPlaying && !isBuffering.value) {
      _reconnecting = false;
      return;
    }
    // 前两次快速重连（从当前进度续播，仅重开当前 URL）
    if (_reconnectAttempts <= 2) {
      await Future.delayed(const Duration(milliseconds: 1500));
      if (_playerCount == 0) {
        _reconnecting = false;
        return;
      }
      refreshPlayer();
      _reconnecting = false;
      return;
    }
    // 快速重连无效 → 让当前视频页重新拉取播放链接（CDN URL 可能已失效），
    // 由 queryVideoUrl → setDataSource 在现有播放器实例上换源续播。
    // 不再手动 dispose/重建 mpv：与异步返回的 queryVideoUrl 存在竞态
    // （双播放器互相覆盖，泄漏 mpv/ANGLE/D3D 资源并导致画面冻结）。
    await refreshPlayUrl();
    _reconnecting = false;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();
    // if (_looping) {
    //   await setLooping(_looping);
    // }

    // 跳转播放
    // if (seekTo != Duration.zero) {
    //   await this.seekTo(seekTo);
    // }

    // 自动播放
    if (_autoPlay) {
      _startPlayback();
      // await play(duration: duration);
    }
  }

  // ARM64 修改版：真正把播放跑起来。
  //
  // 为什么不能只调 playIfExists()：`_playCallBack` 是一个**全局静态**回调，
  // 由视频页/直播间各自注册，并且会在页面退出时被 `setPlayCallBack(null)` 清掉
  // （见 onPopInvokedWithResult / dispose / 直播间 dispose）。一旦清理动作
  // 晚于新页面的 initState 执行（旧 State 的 dispose/回调晚一拍很常见），
  // 新页面注册的回调就被旧页面清成了 null —— 此后 playIfExists() 变成空操作，
  // **视频永远不开始播放**；而 seek 不经过这个回调，所以「拖动进度条能跳画面、
  // 就是不播」正好是这个症状。
  //
  // 所以这里优先用回调（它会顺带补注册监听器），回调缺失时直接操作播放器兜底。
  Future<void> _startPlayback() async {
    if (_playCallBack == null) {
      await play();
    } else {
      await playIfExists();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus.value,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();
          // ARM64 修改版：播放成功恢复，重置重连冷却/计数，允许下次断流重新计时。
          _reconnecting = false;
          _reconnectAttempts = 0;
          _lastReconnectAt = DateTime.fromMillisecondsSinceEpoch(0);
          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
          playerStatus.value = .playing;
        } else {
          _startWakeLockTimer();
          _disableAutoEnterPip();
          playerStatus.value = .paused;
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus.value = .completed;
          _stopWakeLockTimer();
          _updatePlaybackState();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          if (!isSeeking.value) {
            this.position.value = posInSeconds;
          }

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen(updateDuration),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        _updatePlaybackState();
      }),
      stream.log.listen(((PlayerLog log) {
        if (log.level == 'error' || log.level == 'fatal') {
          final logMsg = '${log.prefix}: ${log.text}';
          // 网络断连类错误也走自动重连（log 通道前缀可能是 ffmpeg: tls: IO error）
          if (_isNetworkResetError(logMsg)) {
            _scheduleReconnect();
            return;
          }
          if (_isAudioError(logMsg)) {
            _onAudioStreamError(logMsg);
            return;
          }
          if (logMsg.contains('EDL: Could not open source file')) {
            _scheduleReconnect();
            return;
          }
          Utils.reportError(
            '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
            null,
          );
        } else if (kDebugMode) {
          debugPrint(log.toString());
        }
      })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (_isNetworkResetError(event) ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == 0) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (_isNetworkResetError(event)) {
          // 播放中途网络连接被重置（WSAECONNRESET），从当前进度自动重连续播，
          // 避免播放器卡死。10 秒节流防止频繁重连风暴。
          _scheduleReconnect();
        } else if (_isAudioError(event)) {
          _onAudioStreamError(event);
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    Future<void> seek() async {
      if (isSeek) {
        /// 拖动进度条调节时，不等待第一帧，防止抖动
        await _videoPlayerController?.stream.buffer.first;
      }
      danmakuController?.clear();
      try {
        await _videoPlayerController?.seek(position);
      } catch (e) {
        if (kDebugMode) debugPrint('seek failed: $e');
      }
    }

    if (duration.value != 0) {
      seek();
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek();
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    // 上游 2.1.6（#3112）：直播间固定 1 倍速，别把直播的 1.0 写进记忆倍速，
    // 否则「看直播 → 回到视频」会被拉回 1 倍速。
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      // await seekTo(Duration.zero);
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus.value = PlayerStatus.playing;
    // screenManager.setOverlays(false);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.value = PlayerStatus.paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling && hoverDx == null) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekEnd() {
    if (seekToPos != null) {
      feedBack();
    }
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    _updatePlaybackState();
    // ARM64 修改版（2026-09-17）：记下「用户刚拖过进度条」的时刻。
    // 拖动松手后播放器要重新缓冲、位置也要重新对齐，这段时间画面本来就可能不动；
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  double get maxVolume => PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (!volume.isFinite) return;
    volume = volume.clamp(0.0, maxVolume);
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  // ARM64 修改版：改走本控制器自己的 play()/pause()，而不是直接对 media_kit
  // 的 player 调 playOrPause()。原因：暂停/播放的「用户意图」必须被记录下来
  // （_userPaused / _userPaused 由 play() 清、pause() 置），否则画面卡死看门狗
  // 无法区分「用户就是想暂停」和「播放器卡住了」，会把用户按下的暂停又给按回去。
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      await play();
    } else if (playerStatus.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  // 长按左方向键持续后退（上游 #3379）。
  //
  // 上游用一个 seekPosition 累加器：按住不放时每 200ms 一拍，把目标位置往后
  // 挪一个 fastForBackwardDuration，松手时一次性跳到累计位置；轻点一下（还没
  // 攒到一拍）仍然只退固定步长。
  //
  // 本地没有那个累加器（播放进度直接取 mpv 的 position），所以自己记一个
  // 「目标位置」：第一拍从当前进度开始，之后每拍在上一拍的基础上再退一段。
  int? _multiBackwardTargetMs;

  void multiBackwardStart([_]) {
    final base =
        _multiBackwardTargetMs ??
        (videoPlayerController?.state.position.inMilliseconds ??
            positionInMilliseconds);
    final target = base - fastForBackwardDuration.inMilliseconds;
    _multiBackwardTargetMs = target < 0 ? 0 : target;
    // 标记成「正在跳转」：看门狗在 isSeeking 为 true 时不判定画面冻结，
    // 否则按住不放的这几秒会被误判成卡死而触发自愈重开。
    isSeeking.value = true;
  }

  void multiBackwardEnd() {
    final target = _multiBackwardTargetMs;
    _multiBackwardTargetMs = null;
    if (target == null) {
      // 没攒到一拍 → 只是一次轻点，退固定步长。
      onBackward(fastForBackwardDuration);
      return;
    }
    isSeeking.value = false;
    onForwardBackward(Duration(milliseconds: target));
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val, {bool inAppFullScreen = false}) {
    isFullScreen.value = val;
    // 只在处于全屏时才有「是哪种全屏」可言；退出时一并归零。
    isWindowFullScreen.value = val && inAppFullScreen;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;

  /// 当前生效的全屏形态。用来判断一次 [triggerFullScreen] 是否真是「切换」。
  ///
  /// ARM64 修改版（2026-09-18）：原来用 `isFullScreen.value == status` 判重，
  /// 而两种全屏都让 isFullScreen 为真，于是
  ///   - 窗口全屏时按「全屏」→ status=true == isFullScreen(true) → 直接 return，
  ///     升不到原生全屏；
  ///   - 原生全屏时按「窗口全屏」→ 它传的 status = !isFullScreen = false →
  ///     直接退出全屏，回不到窗口全屏。
  /// 现在按「形态」判重，两条路径都能走通。
  /// 当前是否处于「原生全屏」（无边框跳出窗口），相对「窗口全屏」而言。
  /// UI 上「全屏」按钮的图标/提示语看它；两种全屏可以互相切换。
  bool get isNativeFullScreen =>
      isFullScreen.value && !isWindowFullScreen.value;

  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    // 目标形态是否与当前一致 → 无需动作。
    if (status) {
      if (isFullScreen.value && isWindowFullScreen.value == inAppFullScreen) {
        return;
      }
    } else if (!isFullScreen.value) {
      return;
    }

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          // 桌面端：窗口全屏 = 应用内铺满（不碰原生窗口，见 enterDesktopFullScreen
          // 的 inAppFullScreen 分支）；原生全屏 = 无边框跳出窗口。
          //
          // 从原生全屏切到窗口全屏时**必须**先退掉原生全屏，否则窗口还是无边框
          // 跳出的状态，「窗口全屏」就成了空操作。
          if (inAppFullScreen) {
            await exitDesktopFullScreen();
          } else {
            await enterDesktopFullScreen();
          }
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          // 任何一种全屏退出时都要退掉原生全屏（窗口全屏时它是 no-op）。
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status, inAppFullScreen: inAppFullScreen);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint?.release();
      AndroidHelper$ToDart.onUserLeaveHint = null;
    }
    _timer?.cancel();
    _displayBoxDebounce?.cancel();
    _displayBoxDebounce = null;
    _stopWakeLockTimer();
    // 自愈重开收尾定时器与进行中旗标一并清掉（对抗验证补充）：
    // dispose 本身不等待 _reloadAtCurrentPosition 的 finally，若恰好在这里
    // 被 dispose（_playerCount 归零），别让 isRecovering 残留。
    isRecovering.value = false;
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    if (playerStatus.isPlaying) {
      WakelockPlus.disable();
    }
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  double? hoverDx;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      final index = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
      if (previewIndex.value != index) {
        previewIndex.value = index;
      } else if (hoverDx != null) {
        previewIndex.refresh();
      }
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final time = DurationUtils.formatDuration(
      positionInMilliseconds / 1000,
    ).replaceAll(':', '-');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗保存截图');
      final dispose = await showDialog<bool>(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            Get.back(result: false);
            final bytes = await image.toByteData(format: .png);
            image.dispose();
            if (bytes != null) {
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (dispose ?? true) image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
