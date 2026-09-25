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
  Rect? _lastWindowBounds;

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
    try {
      await Future.wait([
        if (showWindowTitleBar)
          windowManager.setTitleBarStyle(TitleBarStyle.normal),
        windowManager.setMinimumSize(const Size(400, 700)),
        if (bounds != null) windowManager.setBounds(bounds),
        setAlwaysOnTop(false),
        windowManager.setAspectRatio(0),
      ]);
      Utils.reportError('pip: exitDesktopPip done', null);
    } catch (e) {
      Utils.reportError('pip: exitDesktopPip failed: $e', null);
    }
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    Utils.reportError('pip: enterDesktopPip', null);
    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    final Size size;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) {
      width = this.width ?? 16;
    }
    if (height == 0) {
      height = this.height ?? 9;
    }
    if (height > width) {
      size = Size(280.0, 280.0 * height / width);
    } else {
      size = Size(280.0 * width / height, 280.0);
    }

    await windowManager.setMinimumSize(size);
    setAlwaysOnTop(true);
    windowManager
      ..setSize(size)
      ..setAspectRatio(width / height);
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
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(PlayCallback? playCallBack) {
    _playCallBack = playCallBack;
  }

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

  static Future<void> pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) async {
    if (_instance?.playerStatus.isPlaying ?? false) {
      await _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
  }

  static Future<void> seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) async {
    await _instance?.seekTo(position, isSeek: isSeek);
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
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
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
      // 换了片源 → 允许重新打一次管线快照（ready / t+6s）。
      _loggedPipelineReady = false;
      _pipelineReadyTicks = -1;
      _pictureFrozenDrops = null;
      _pictureFrozenCount = 0;
      _resetStallWatchdogProgress();
      // 换片源 → 重新开始「音频停摆」判定的宽限期（见 _audioStallGraceUntil）：
      // 新片源刚 open，AO 还没挂上、audio-pts 还是 null，不能当成停摆。
      _audioStallGraceUntil = DateTime.now().add(_audioStallGrace);
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
      await _createVideoController(dataSource, seekTo, volume);

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

      _ensureStallWatchdog();
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
      'volume-max': kMaxVolume.toString(),
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
    // 若出现卡顿可在「设置 → 视频」中关闭该项。
    if (Pref.disableFrameThreading) {
      opt['vd-lavc-o'] = 'thread_type=slice';
      // 关键配套：别让 mpv 因为几帧坏数据就把硬件解码器降级为软件解码。
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
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
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

  /// 重开当前 URL 从当前位置续播，并且**让播放真正跑起来、完成后自动收尾**。
  ///
  /// 为什么不能直接用 [refreshPlayer]（2026-09-17 修）：
  ///   - 它只调 `ctr.open(..., play: true)` 就返回。而 media_kit 的 `open()` 内部
  ///     会先 `await stop(open: true)` 并**把 pause 置回 true**，最后才按 `play`
  ///     参数解除暂停、再设 playlist-pos。这个链路上任何一步的时序抖动，都会
  ///     留下「画面在走、声音没了」或「声音在走、画面没了」这种半截状态 ——
  ///     正是用户报的现象之一。
  ///   - 它不需要用户手势，但重开确实要重新缓冲；用户看到的是一段静止画面，
  ///     所以必须配一个加载指示。
  ///
  /// 这里统一处理：置缓冲态 → 重开 → 显式恢复播放（[play] 会清 `_userPaused`）
  /// → 等 `stream.playing` 真的变 true（最多 [_reloadWaitTimeout]）→ 清缓冲态。
  ///
  /// 全程置 [isRecovering]，让自愈加载指示与常规缓冲指示**互斥**（见该字段注释）。
  Future<void> _reloadAtCurrentPosition() async {
    if (dataSource is FileSource) return;
    // 已经有一次重开在跑：叠加第二次只会互相把 open() 打断（表现为声音没了/画面没了）。
    if (isRecovering.value) return;
    final ctr = _videoPlayerController;
    if (ctr == null || ctr.current.isEmpty) return;
    if (_videoController == null) return;
    // 用户正在拖进度条：那是用户自己的操作，松手后由跳转流程接管，
    // 这时候插一次重开会和拖动打架（也正是「自愈动画与拖动动画叠在一起」的来源之一）。
    if (isSeeking.value) return;

    isRecovering.value = true;
    isBuffering.value = true;
    _reloadWatchdog?.cancel();
    // 重开期间 AO 会被拆掉重建，`current-ao` / `audio-pts` 会短暂缺失 ——
    // 重置宽限期，免得把「正在重建」判成「音频停摆」而再叠一次自愈。
    _audioStallGraceUntil = DateTime.now().add(_audioStallGrace);
    try {
      // 重开点**比当前位置往回一点**，不要正好停在当前位置（2026-09-18 按用户反馈改）。
      //
      // 为什么必须往回：卡死的本质是渲染链跟不上音频时钟、视频 pts 落在音频后面。
      // 如果从「当前位置」重开，新管线一上来就顶在音频时钟上、甚至还在它后面 ——
      // 一帧迟到就被丢，丢帧再让 pts 更落后，**刚刚重建完就立刻再次进入同一条
      // 雪崩**（这也解释了为什么重建有时看起来「没救回来」）。
      // 往回退一段等于给刚重建的管线一段缓冲，让它从从容的位置重新追上音频。
      // 回退量按倍速放大（高倍速下音频时钟走得更快，同样的秒数只相当于更少的缓冲），
      // 上限 8s：再大就不是「缓冲」而是明显倒退进度了。
      final rawRewind = (3000 * _speedFactor).round();
      final rewindMs = rawRewind < 3000 ? 3000 : (rawRewind > 8000 ? 8000 : rawRewind);
      final startPos = ctr.state.position - Duration(milliseconds: rewindMs);
      // open() 本身也套超时（2026-09-17 对抗验证补充）：如果 mpv 卡死，
      // media_kit 的 open 链（stop(open:true) → loadfile）可能永不返回 ——
      // 没有超时的话 finally 就永远不会执行，isRecovering/isBuffering 永久
      // 停在 true，所有自愈路径（看门狗、onPictureFrozen、重入保护）全被禁用，
      // 加载指示还会一直显示「正在恢复播放…」。超时后由 catch 清旗标，
      // 交给既有的看门狗继续救；mpv 若事后才响应，播放恢复照常。
      await ctr
          .open(
            ctr.current.last.copyWith(
              start: startPos < Duration.zero ? Duration.zero : startPos,
            ),
            play: true,
          )
          .timeout(_reloadWaitTimeout);
      // 显式再喊一次播放：
      //  - 兜住上面说的「open 内部留下 pause=true」；
      //  - _startPlayback 在全局回调被清空时也能落到本控制器的 play()。
      _startPlayback();
      // 等 playing 真的变 true。等不到就算了（超时后交给既有的
      // 断流/卡死看门狗继续救），无论如何都要把缓冲态清掉。
      //
      // 先读当前状态再决定要不要等（2026-09-17 补）：
      // `ctr.stream.playing` 是 broadcast stream，**不会**向新订阅者重放最近值，
      // `firstWhere` 只等订阅之后的下一次事件。如果 `open(play: true)` 返回时播放
      // 其实已经恢复（state.playing 已为 true），直接去等会白耗整段
      // _reloadWaitTimeout（6s），自愈加载指示也要多挂 6s 才消失 —— 而
      // isRecovering 正是这轮新加的指示，不能让它拖这么长。
      if (!ctr.state.playing) {
        await ctr.stream.playing
            .firstWhere((e) => e)
            .timeout(_reloadWaitTimeout);
      }
    } catch (e) {
      // 超时或播放器已释放：记一条，别让缓冲态卡住。
      Utils.reportError(
        'reload at current position did not confirm playing: $e',
        null,
      );
    } finally {
      if (_playerCount != 0) {
        isBuffering.value = false;
      }
      isRecovering.value = false;
      // 再补一次：`playing` 事件有时早于音频输出真正接上，
      // 形成「画面在走、声音没有」；这里延迟一点再喊一次播放，代价极低。
      // 已 dispose（_playerCount == 0）就不再挂这个定时器，免得 dispose 之后
      // 又冒出一个 1200ms 的空转定时器。
      if (_playerCount != 0) {
        _reloadWatchdog = Timer(const Duration(milliseconds: 1200), () {
          if (_playerCount == 0) return;
          if (playerStatus.isPlaying) return;
          _startPlayback();
        });
      }
    }
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

  // 是否已有一次自动重连在进行中（防止重连风暴/重复重连）
  bool _reconnecting = false;
  int _reconnectAttempts = 0;
  // 重连冷却：上次发起重连的时间。若距上次不足冷却期则忽略本次错误，
  // 避免 CDN 短时间反复断流时触发重连风暴（每次重连失败都会堆积泄漏）。
  DateTime _lastReconnectAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _reconnectCooldown = Duration(seconds: 10);
  // 画面卡死看门狗：某些故障不触发任何 mpv 错误事件（无日志可匹配），
  // 表现为「画面冻结、声音继续」。
  //
  // 为什么不能用 positionInMilliseconds（first attempt）：它对应 mpv 的
  // time-pos，而 time-pos 在有音频时由**音频时钟**驱动
  // （mpv player/command.c: get_current_time() 在 audio_status == STATUS_PLAYING
  // 时返回 playing_audio_pts()）。画面冻结时音频照常播放、time-pos 一直推进，
  // 比较 position 有没有变永远判不出来。
  //
  // 为什么也不能用 video-pts（second attempt）：本 mpv 构建（v0.41.0）的
  // 属性表里**没有** video-pts（只有 audio-pts；video-frame-info 也不含 pts，
  // 只有 picture-type / 各种 timecode）。上一版读的 video-pts 恒为空字符串，
  // 于是看门狗每次都走「属性读不到 → 不判定」分支，**实际从未运行过** ——
  // 崩溃日志里 0 条 'video stalled' 记录正好印证了这一点。
  //
  // 现在的判据：mpv 的 `frame-drop-count`（= vo_get_drop_count()）。已用实机日志
  // 验证（2026-09-12 17:06:43，构建 7c42591b6）：
  //   video stalled ... hwdec=d3d11va-copy vo=libmpv decoder-drop=0
  //   vo-drop=95 vo-delayed=0 core-idle=no paused-for-cache=no state=playing
  // 含义很明确：**解码器完全正常（decoder-drop=0），是渲染端没把帧画出来**。
  //
  // 出处是 mpv 自己的 vo_libmpv.c —— flip_page() 等客户端调用
  // mpv_render_context_render() 最多等 200ms，超时就丢掉这一帧并
  // vo_increment_drop_count(vo, 1)：
  //     int64_t until = mp_time_ns() + MP_TIME_MS_TO_NS(200);
  //     while (ctx->next_frame) { ... 超时 goto done ... }
  //   done:
  //     if (ctx->next_frame) { ...; vo_increment_drop_count(vo, 1); }
  // 即 media_kit 的 ANGLE 渲染路径（VideoOutput::Render() → ANGLESurfaceManager
  // ::Draw()，它与 Flutter 光栅线程里执行的 Read() 共用同一把内核 mutex）只要
  // 有一次超过 200ms 没把帧交给 mpv，mpv 就丢帧；而视频 pts 一旦落到音频后面，
  // 后续帧会持续「迟到」被丢，形成**不自愈的雪崩**（画面冻结、声音继续），直到
  // 一次跳转/重载把 pts 重新对齐才恢复。这正好解释了两个现象：
  //   - 「最小化窗口后更容易出现」：最小化/还原会让 Flutter 光栅线程停摆再恢复，
  //     渲染端与它抢同一把锁、最容易超过 200ms；
  //   - 「往回拖进度条就恢复」：跳转把视频 pts 重新对齐到音频，雪崩终止。
  // 所以恢复手段首选**跳转**（便宜、不依赖网络），而不是重拉播放链接。
  //
  // 每 2s 采样一次，单个窗口增量 ≥ _stallDropDelta 记一次超标，连续
  // _stallWindowThreshold 个窗口超标才判定卡死（约 4s，避免偶发抖动误判）。
  // 跳转（isSeeking）或计数回退（mpv 重建 VO）时直接重置，不参与判定。
  Timer? _stallWatchdog;
  static const Duration _stallWatchdogPeriod = Duration(seconds: 2);
  // 一个采样窗口（2s）内 VO 丢帧增量达到该值，即认为视频已经跟不上音频。
  static const int _stallDropDelta = 10;
  // 「最近 _stallWindowHistorySize 个窗口里有 _stallWindowThreshold 个异常」即判定卡死。
  //
  // ARM64 修改版（2026-09-14）：原来是「**连续** 2 个窗口异常」，已改成滑动窗口。
  // 原因：用户报的卡死是断续的 —— 某些采样窗口刚好一次丢帧都没有，连续的判据
  // 于是永远凑不齐，看门狗等于不存在（实测「最近一次卡住完全没有日志」就是它）。
  static const int _stallWindowThreshold = 2;
  static const int _stallWindowHistorySize = 3;
  // 卡死恢复过一次之后，多久没有复发才让恢复阶梯回到第 1 级。
  // 太短会让阶梯永远停在「往回跳 1s」上（每次卡→跳→好一个窗口→再卡→又从头开始），
  // 救不回来时升不到 refreshPlayer / refreshPlayUrl。
  static const Duration _stallEpisodeResetAfter = Duration(minutes: 2);
  // 最近若干个采样窗口的判定结果（true = 该窗口异常）。
  final List<bool> _stallWindowHistory = [];
  int? _stallWatchdogLastDrops;
  // 上一窗口的 time-pos（毫秒）。用于检测「本应播放但位置纹丝不动」
  // （例如打开后一直 paused / paused-for-cache、或播放器根本没起播）。
  int _stallWatchdogLastPosMs = -1;
  // 上一窗口的 mpv `audio-pts`（字符串，mpv 直接给的就是这个）。
  // 用于判「画面在走、声音没了」：音频时钟不再推进而画面照常 = 音频输出停摆。
  // 用字符串原样比较即可，不用解析成数字 —— 只要「这一个窗口里它有没有变」。
  String? _stallWatchdogLastAudioPts;
  // 「音频停摆」判定的宽限期截止时刻。
  //
  // 起播/重开后的一小段时间里，mpv 还没把 AO 挂上、audio-pts 还是 null，
  // 「AO 缺失 / 音轨读不到」的判据会**天然成立** —— 不加这段宽限，
  // 每次起播都会被当成音频停摆并触发一次自愈。
  // 由 setDataSource / _reloadAtCurrentPosition 重置为「现在 + _audioStallGrace」。
  DateTime _audioStallGraceUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _audioStallGrace = Duration(seconds: 8);
  // 本次卡死开始时的累计丢帧数（只用于日志里给出「本段丢了多少帧」）。
  int? _stallEpisodeDrops;
  // 当前是否处于「画面卡住」状态。看门狗写入、_tryReconnect 读取，
  // 用于区分「真的恢复了」和「音频在放但画面卡住」。
  bool _videoStalled = false;
  // 同一次卡死里已按「代价从低到高」尝试过几级恢复；画面恢复正常后清零。
  int _stallRecoveryAttempts = 0;
  // 卡死恢复自己的冷却（**不**共用 _reconnectCooldown）。
  //
  // 原来的实现让 _onVideoStalled 和 _scheduleReconnect 共用 _lastReconnectAt：
  // 一次网络重连会顺带把接下来 10s 的卡死恢复一起压掉（反之亦然），
  // 而断流与卡死本来就是两件独立的事、没有理由互相节流。
  DateTime _lastStallRecoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _stallCooldown = Duration(seconds: 4);

  // ── 倍速因子（ARM64 修改版，2026-09-17）─────────────────────────────────
  //
  // 用户报「三倍速播放长视频仍然画面卡死、声音继续」。倍速与卡死正相关的原因
  // 早就确认过：倍速由音频时钟驱动，3 倍速时 mpv 必须每秒呈现 3 倍的帧，而
  // WOA 上这条渲染链（hwdec=d3d11va-copy 的 GPU→CPU 回拷 + ANGLE 重新上传 +
  // glFinish）本来就吃紧 —— 负载成正比上升，卡死概率也随之上升。
  //
  // 所以下面几处判定/恢复的节流都按倍速缩放，而不是用固定值：
  //   - 卡死恢复的冷却缩到一半（3 倍速下 6s 的冷却 = 用户眼里的 18s 视频时间）；
  //   - 冻结判定的冷却与升级阶梯提前（见 onPictureFrozen）；
  //   - 第一级「往回跳」的回退量按倍速放大（1 倍速下 2s 的缓冲，在 3 倍速下
  //     只相当于 0.67s，实测不足以脱离「帧持续迟到」的区间）。
  double get _speedFactor {
    final s = playbackSpeed;
    return (s.isFinite && s > 1.0) ? s : 1.0;
  }

  /// 当前生效的卡死恢复冷却。倍速播放时缩短，让恢复动作更快接上。
  Duration get _stallCooldownNow =>
      _speedFactor >= 2.0 ? const Duration(seconds: 2) : _stallCooldown;
  // 用户是否主动暂停过。看门狗据此区分「本该播放却起不来」和「用户就是想暂停」，
  // 避免自动恢复把用户按下的暂停又给按回去。play() 清、pause() 置。
  bool _userPaused = false;

  // 自动重开的收尾定时器（见 _reloadAtCurrentPosition）。
  Timer? _reloadWatchdog;
  static const Duration _reloadWaitTimeout = Duration(seconds: 4);

  // ── 管线诊断（ARM64 修改版，2026-09-14）────────────────────────────────
  // 为什么需要它：上一轮用户报「最近一次画面卡住完全没有日志」。原因很直接 ——
  // 原来的日志**只在判定卡死成立时才写**，而判定本身依赖的判据一旦不成立
  // （例如画面停住却一次丢帧都没有），就什么证据都不剩。
  // 现在改成「不管判不判得出来，先把管线状态记下来」：
  //   ready  ：纹理首次就绪的瞬间（每个视频一次）
  //   t+6s   ：就绪 6s 后再记一条（能看到帧率/丢帧是否正常流动）
  //   suspect：指标出现异常迹象（按 20s 节流）
  // 这三条一起，能直接区分下面这些完全不同的病因：
  //   - texture-id 一直是 null / rect 一直是 1x1 → 渲染端压根没建立（黑屏）
  //   - vf-fps 塌到 ~0 而 core-idle=no → 输出链停摆（无声丢帧的卡死）
  //   - frame-drop-count 攀升 → 渲染端来不及（经典丢帧卡死）
  //   - width/height/rotate 异常 → 尺寸/旋转元数据问题
  bool _loggedPipelineReady = false;
  int _pipelineReadyTicks = -1;
  DateTime _lastPipelineSuspicionAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _pipelineSuspicionCooldown = Duration(seconds: 20);
  // 固定时间线：与「指标异常」无关，在播时定期记一条。
  //
  // 为什么必须无条件：实测那种「画面卡死」在 mpv 侧**完全没有信号** ——
  // frame-drop-count 不涨、estimated-vf-fps 照常等于 container-fps、decoder-drop=0。
  // 任何「按指标异常触发」的日志都抓不到它（上一版就是这么漏掉的，构建 5349 的日志里
  // suspect/hidden-playing/texture-lost 一条都没有）。只有固定时间线才能事后比对出
  // 「卡死发生在哪一刻、当时各指标是什么」。
  DateTime _lastTimelineAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _pipelineTimelinePeriod = Duration(seconds: 30);
  // 已经下发过的视频输出表面尺寸，避免重复下发。
  int? _appliedSurfaceWidth;
  int? _appliedSurfaceHeight;
  // 「画面冻结」判定的状态（见 onPictureFrozen）。
  DateTime _lastPictureResyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  // 冻结判定的基础冷却（2026-09-18：10s → 6s → 4s）。用户两次反馈「卡死重建
  // 时间有点长」；像素采样已经把探测压到 ~4s，冷却再长就等于把感知时间又拉回去。
  // 倍速播放时还会在 onPictureFrozen 里再压短（≥2x 为 2s、>1.5x 为 3s）。
  static const Duration _pictureResyncCooldown = Duration(seconds: 4);
  // 短时间内连续冻结算同一次事故；隔久了重新计数。
  int _pictureFrozenCount = 0;
  // 本段事故里「整链重建」（_reloadAtCurrentPosition）已经做过几次。
  // 每做一次就按倍数拉长下一次的冷却间隔 —— 否则在倍速播放下渲染链持续吃紧时，
  // 会变成「刚重开完又冻结 → 又重开」的抖动，比卡住更难用。
  int _pictureReloadCount = 0;
  // 上一次冻结时的 vo-drop，用来判断「像素不变」到底是真冻结（在丢帧）
  // 还是视频里本来就有静止画面（不丢帧 → 绝不能动播放位置）。
  int? _pictureFrozenDrops;

  // Rect 在 AOT 下 toString() 会打成 "Instance of 'Rect'"，所以自己拼数值。
  static String _rectDesc(ui.Rect? r) => r == null
      ? 'null'
      : '${r.left.toInt()},${r.top.toInt()},'
            '${r.width.toInt()}x${r.height.toInt()}';

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
  Future<void> _applyVideoOutputSize({bool force = false}) async {
    final ctr = _videoController;
    if (ctr == null) return;
    final w = _intProp('video-out-params/dw');
    final h = _intProp('video-out-params/dh');
    if (w == null || h == null || w < 1 || h < 1) return;
    if (!force && _appliedSurfaceWidth == w && _appliedSurfaceHeight == h) {
      return;
    }
    _appliedSurfaceWidth = w;
    _appliedSurfaceHeight = h;
    try {
      if (force) {
        // dart 侧 setSize 有「与上次相同就跳过」的缓存，先置空强制下发一次，
        // 这样原生一定收到一次真实的尺寸变化并触发 Resize()。
        final cleared = ctr.setSize();
        if (cleared != null) await cleared;
      }
      final applied = ctr.setSize(width: w, height: h);
      if (applied != null) await applied;
    } catch (_) {}
  }

  /// 由画面像素采样发现「画面不再变化」时调用（见 PlVideoPlayer 的采样器）。
  ///
  /// 为什么必须靠像素：构建 5350 的实机日志证明，卡死时
  /// `estimated-vf-fps` 照常 30、`decoder-drop=0`、`core-idle=no`、
  /// `paused-for-cache=no`，demuxer 缓存稳定在 ~15s（= cache-secs 16，**没有溢出**）。
  /// mpv 侧一切正常，唯一暴露它的信号就是「屏幕像素不再变化」。
  ///
  /// 关键旁证：用户反馈卡死时**弹幕照常跑**。弹幕是 Flutter 自己渲染的，
  /// 说明光栅线程与合成器都健康 —— 断点只可能在「视频纹理这一条链路」上
  /// （GpuSurfaceTexture 回调 → 共享句柄拷贝 → 引擎上传），而不是整个 UI 停摆，
  /// 也不是解复用/缓存问题。
  ///
  /// 两种冻结在数据上完全不同，恢复手段也不同：
  ///  A. vo-drop **持平**、vf-fps 正常：mpv 认为一切正常、帧也在出，只有屏幕不动
  ///     → 断点在上述纹理链路，靠**重建表面**能救。
  ///     实机 20:06:38 那次就是这样（vo-drop 停在 40 不动，冻结持续数分钟）。
  ///  B. vo-drop 仍在**增长**：视频 pts 真在落后音频 → 跳转重新对齐即可。
  ///
  /// 恢复阶梯（每级有冷却，长时间不再冻则计数归零），**必须保证能收敛**：
  ///   1 级：重建视频输出表面/纹理（不动播放位置）
  ///   2 级：再叠一次「对齐到音频时钟的当前位置」（不是往回跳，音频不动，
  ///         所以即使误判也只是原地重跳，不丢进度）
  ///   3 级起：`_reloadAtCurrentPosition()` 重建整条解码+渲染链，然后计数归零
  /// 之前这里 3 级以后会**永远**重复「重建表面 + 原地重跳」而从不升级，
  /// 遇到真正被钉死的状态就会无限空转 —— 这是本次修的缺陷。
  ///
  /// 倍速播放（ARM64 修改版，2026-09-17）：阶梯整体提前、冷却缩短。
  /// 实测「3 倍速播长视频仍会冻结」，而原阶梯在 3 倍速下要走
  /// 10s 冷却 × 4 级 ≈ 40s 才升到整链重建 —— 用户在这 40s 里看的是一张死图，
  /// 3 倍速下又相当于 120s 的视频时间。现在 >1.5 倍速时第 2 次冻结就直接
  /// 整链重建。
  /// 2026-09-18 再次提速：采样探测 ~4s（见 view.dart 的采样器）、1x 冷却 10s→6s、
  /// 1x 升级门槛 4→3，正常倍速下一次完整冻结到整链重建 ≈ 16s 内收敛。
  void onPictureFrozen() {
    if (_playerCount == 0) return;
    // 已经在自愈重开中：这次「像素没变」正是重开导致的，不要叠加动作。
    if (isRecovering.value) return;
    final now = DateTime.now();
    // 用户刚拖完进度条：画面本来就要重新缓冲、位置也在重对齐，
    // 这时插一次自愈重开会把用户拖到的位置冲掉（也会让两个加载指示叠在一起）。
    if (now.difference(_lastUserSeekAt) < _userSeekGrace) return;
    final sinceLast = now.difference(_lastPictureResyncAt);
    // 冷却按倍速与已重开次数缩放：base（1x=4s / 1.5x 以上=3s / 2x 以上=2s）
    // × (1 + 本段已整链重建次数)，上限 4 倍。下限不低于采样周期（2s），
    // 否则会在同一个采样窗口里反复触发。
    final baseCooldown = _speedFactor >= 2.0
        ? 2
        : (_speedFactor > 1.5 ? 3 : _pictureResyncCooldown.inSeconds);
    final reloads = _pictureReloadCount > 3 ? 3 : _pictureReloadCount;
    final cooldown = Duration(seconds: baseCooldown * (1 + reloads));
    if (sinceLast < cooldown) return;
    _lastPictureResyncAt = now;

    // 距离上次很久 → 新的一次事故，重新计数。
    if (sinceLast > _stallEpisodeResetAfter) {
      _pictureFrozenCount = 0;
      _pictureReloadCount = 0;
    }
    _pictureFrozenCount++;

    final drops = _intProp('frame-drop-count') ?? 0;
    final prevDrops = _pictureFrozenDrops;
    final dropsGrowing = prevDrops != null && drops > prevDrops;
    _pictureFrozenDrops = drops;

    // 整链重建的门槛：倍速播放时前移。
    // 2026-09-18 再降：1x 也从 3 降到 2 —— 第 1 次先重建表面，第 2 次就整链重建，
    // 配合 4s 冷却，一次冻结大约 8s 内就能走到最重的那一级。
    final escalateAt = _speedFactor > 1.5 ? 1 : 2;
    if (_pictureFrozenCount >= escalateAt || (dropsGrowing && _pictureFrozenCount > 2)) {
      _pictureFrozenCount = 0;
      _pictureReloadCount++;
      // next-cooldown 必须用自增后的 reloads（对抗验证抓到的 off-by-one）：
      // 这次重开之后，下一次冻结的冷却间隔是按新计数算的。
      final nextReloads = _pictureReloadCount > 3 ? 3 : _pictureReloadCount;
      Utils.reportError(
        'picture frozen: escalating to reloadAtCurrentPosition '
        '(vo-drop=$prevDrops->$drops vf-fps=${_mpvProp('estimated-vf-fps')} '
        'decoder-drop=${_mpvProp('decoder-frame-drop-count')} '
        'speed=${playbackSpeed}x reloads=$_pictureReloadCount '
        'next-cooldown=${baseCooldown * (1 + nextReloads)}s '
        'time-pos=${positionInMilliseconds ~/ 1000}s)',
        null,
      );
      _logPipelineSnapshot('picture-frozen');
      unawaited(_reloadAtCurrentPosition());
      return;
    }

    Utils.reportError(
      'picture frozen #$_pictureFrozenCount: pixels unchanged '
      '(vo-drop=$prevDrops->$drops vf-fps=${_mpvProp('estimated-vf-fps')} '
      'decoder-drop=${_mpvProp('decoder-frame-drop-count')} '
      'core-idle=${_mpvProp('core-idle')} '
      'demuxer-cache-time=${_mpvProp('demuxer-cache-time')} '
      'speed=${playbackSpeed}x '
      'time-pos=${positionInMilliseconds ~/ 1000}s '
      'lifecycle=${WidgetsBinding.instance.lifecycleState?.name}) '
      '-> ${_pictureFrozenCount < 2 ? 'refresh video surface' : 'refresh surface + resync video pts'}',
      null,
    );
    _logPipelineSnapshot('picture-frozen');

    // 第 1、2 次：重建视频输出表面与纹理 —— 不动播放位置。
    // 这条路径绕开「Resize 没发生 / 纹理内容陈旧」这一类断点。
    _applyVideoOutputSize(force: true);

    // 第 2 次（1x 下不会到 3 次就升级）再叠一次「对齐到音频时钟当前位置」：
    // 对付 B 类（视频 pts 真在落后音频）比单纯重建表面更有针对性；
    // 音频不动，所以即使误判也只是原地重跳，不丢进度。
    if (_pictureFrozenCount >= 2) {
      seekTo(
        Duration(milliseconds: positionInMilliseconds),
        isSeek: false,
      );
    }
  }

  // 记一条管线快照。tag 用于区分触发时机（见上面的说明）。
  void _logPipelineSnapshot(String tag) {
    Utils.reportError(
      'pipeline[$tag]: '
      // 实际生效的同步方式 / 解码方式 / 输出模块
      'video-sync=${_mpvProp('video-sync')} '
      'hwdec-current=${_mpvProp('hwdec-current')} '
      'vo=${_mpvProp('current-vo')} '
      // 帧率三件套：片源帧率、滤镜链产出帧率、显示器刷新率
      'container-fps=${_mpvProp('container-fps')} '
      'vf-fps=${_mpvProp('estimated-vf-fps')} '
      'display-fps=${_mpvProp('display-fps')} '
      'est-display-fps=${_mpvProp('estimated-display-fps')} '
      // 计数类：丢帧 / 延迟帧 / 解码器丢帧
      'vo-drop=${_mpvProp('frame-drop-count')} '
      'vo-delayed=${_mpvProp('vo-delayed-frame-count')} '
      'decoder-drop=${_mpvProp('decoder-frame-drop-count')} '
      'mistimed=${_mpvProp('mistimed-frame-count')} '
      // 尺寸与旋转：竖屏黑屏的关键证据。
      // mpv 的 width/height 是解码尺寸，video-out-params/dw|dh 是显示尺寸，
      // video-out-params/rotate 是旋转元数据 —— media_kit_video 原生侧正是拿
      // 这三个值（dw/dh/rotate）算 ANGLE 表面尺寸的（rotate 为 90/270 时把 dw/dh
      // 对调），所以这里必须照抄它的读法，才能判断出是不是那里算错了。
      'mpv-width=${_mpvProp('width')} mpv-height=${_mpvProp('height')} '
      'dw=${_mpvProp('video-out-params/dw')} dh=${_mpvProp('video-out-params/dh')} '
      'rotate=${_mpvProp('video-out-params/rotate')} '
      // 应用侧：纹理与矩形（null / 1x1 就说明渲染端没建立起来）
      'texture-id=${_videoController?.id.value} '
      'rect=${_rectDesc(_videoController?.rect.value)} '
      // 应用侧：竖屏判定、画面适配方式、片源尺寸
      'isVertical=$_isVertical videoFit=${videoFit.value.name} '
      'src=${width}x$height '
      // 视频轨是否被关掉 —— 「只有声音和弹幕、画面全黑」最直接的两个嫌疑：
      //   唯一的「听视频」开关（onlyPlayAudio=true 时直接把音轨当片源打开），
      //   以及 mpv 的 vid 属性（'no' 就表示视频轨被禁用）。
      'onlyPlayAudio=${onlyPlayAudio.value} vid=${_mpvProp('vid')} '
      'track-count=${_mpvProp('track-list/count')} '
      // 播放状态与上下文
      'state=${playerStatus.value} buffering=${isBuffering.value} '
      // 用户报过「声音没有正常恢复，画面继续播放」。
      // 下面这组就是专治这个的判据（2026-09-19 起还接了自愈，见 _StallKind.audioStalled）：
      //   aid=no            → 当前选中的音频轨不存在
      //   audio-pts 不动     → 音频时钟停了（画面还在走）
      //   ao=no/null        → mpv 没挂上音频输出
      'aid=${_mpvProp('aid')} audio-pts=${_mpvProp('audio-pts')} '
      // 只记**存在**的属性：`audio-out-pts` / `last-audio-err` 在 mpv 0.41 的
      // 属性表里根本没有（前者实测一直是 null），记它们只会污染日志 ——
      // 与当年 `video-pts` 是同一个坑。改用有据可查的 current-ao / audio-device
      // / audio-params：它们能回答「AO 还在不在、用的是哪个设备、格式对不对」。
      'ao=${_mpvProp('current-ao')} '
      'audio-device=${_mpvProp('audio-device')} '
      'audio-params=${_mpvProp('audio-params')} '
      'core-idle=${_mpvProp('core-idle')} '
      'paused-for-cache=${_mpvProp('paused-for-cache')} '
      'demuxer-cache-time=${_mpvProp('demuxer-cache-time')} '
      'lifecycle=${WidgetsBinding.instance.lifecycleState?.name}',
      null,
    );
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

  /// 当前片源**是否有音轨**（而不是「音频轨此刻是否可用」）。
  ///
  /// 用 mpv 的 `track-list` 判断：只要存在 type=audio 的轨道就返回 true。
  /// 为什么要单独判它 —— `aid` 属性在「当前选中的音频轨不存在」时返回 `no`，
  /// 而**片源本身没有音轨**（纯静音视频）时同样恒为 `no`。两者在 aid 上长得
  /// 一模一样，但含义完全相反：前者要自愈，后者（静音视频）绝不能碰。
  /// `track-list` 才能区分它们。
  ///
  /// 读不到 track-list、或它的字符串形态里根本没有 `type=` 字段时返回 true：
  /// 宁可让判据保留，也不因为读不到属性而把一整类问题静默压掉
  /// —— 与 core-idle 用 `!= yes` 同一个取向。
  bool _hasAudioTrack() {
    final list = _mpvProp('track-list');
    if (list == null || !list.contains('type=')) return true;
    return list.contains('type=audio');
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
  ///
  /// 2026-09-19：对应「画面继续播放、声音没了」。
  ///   - `audio-reload`：重载音频轨（实现上是卸载再重新加入），会把解码器与
  ///     AO 一起重建（见 mpv input.rst 的 `audio-reload`，语义同 `sub-reload`）；
  ///   - 再把 `audio-device` 写回当前值：手册（input.rst）明确写「写入该属性会
  ///     把音频输出**调度为重载**」，是让 AO 重新初始化的官方途径。
  ///     注意它「在 AO 未激活时不会自动启用音频」—— 所以两者都发，
  ///     单靠后者救不了「AO 根本没挂上」的情况。
  ///
  /// 两者都**完全不动播放位置**，所以误判的代价只是一次无声的 AO 重建。
  void _reloadAudioOutput() {
    final device = _mpvProp('audio-device');
    _mpvCommand(const ['audio-reload']);
    if (device != null && device.isNotEmpty && device != 'auto') {
      final player = _videoPlayerController;
      if (player is NativePlayer) {
        try {
          player.setProperty('audio-device', device);
        } catch (_) {}
      }
    }
  }

  // 启动/维持画面卡死看门狗。幂等：已有实例则复用。
  // 仅在 Windows 且非本地文件时启用（WOA 为目标平台）。
  void _ensureStallWatchdog() {
    if (!Platform.isWindows || dataSource is FileSource) return;
    _stallWatchdog ??= Timer.periodic(_stallWatchdogPeriod, (_) {
      if (_playerCount == 0 || dataSource is FileSource) {
        _cancelStallWatchdog();
        return;
      }
      // 管线快照：纹理就绪的瞬间记一条，6s 后再记一条。
      // 放在各种 return 之前 —— 黑屏时页面状态可能很"正常"，
      // 而这些门一旦先 return 就什么证据都不剩了。
      _pipelineTickDiagnostics();

      // 正在跳转、页面已切走（vo=libmpv 由渲染请求驱动解码，切走后 mpv 会
      // 停止解码）、应用没有任何可见视图时本来就不该有进展，不参与判定。
      //
      // ⚠️ 这里**曾经**写成 `lifecycle != AppLifecycleState.resumed` 就退出，
      // 那是「前台播放也会卡住」的直接原因（2026-09-13 修）：
      // Flutter 文档对 `inactive` 的定义就是「至少有一个视图可见，但都没有输入
      // 焦点」，并明确写了 **On non-web desktop platforms, this corresponds to an
      // application that is not in the foreground, but still has visible windows**
      // （见 sky_engine/lib/ui/platform_dispatcher.dart 的 AppLifecycleState 文档）。
      // 也就是说：只要用户没有把焦点留在播放器窗口上（点了别的窗口、点了任务栏、
      // 打开了托盘右键菜单……），生命周期就是 inactive，看门狗**每个 tick 都直接
      // 返回并清零进度**，于是画面真的卡住时没有任何自愈动作。而窗口最小化/隐藏时
      // 播放本来就已经被 _pauseOnEnterBackground 暂停，看门狗自己要的 playing 条件
      // 就不成立，不需要再用生命周期去挡。
      //
      // 所以现在只排除「一个可见视图都没有」（hidden/paused/detached）这一种情况。
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final noVisibleView =
          lifecycle == AppLifecycleState.hidden ||
          lifecycle == AppLifecycleState.paused ||
          lifecycle == AppLifecycleState.detached;
      if (isSeeking.value || !_isCurrVideoPage || noVisibleView) {
        _resetStallWatchdogProgress();
        return;
      }
      // ARM64 修改版（2026-09-17）：自愈重开（isRecovering）进行中时**只跳过判定、
      // 不清零升级阶梯**。这是对抗验证抓到的收敛性缺陷：
      //   - `_reloadAtCurrentPosition` 会把 isRecovering 一直置到重开结束
      //     （open + 最多 6s 的 playing 确认），期间看门狗每 2s 跳过一次；
      //   - 若把 isRecovering 和上面几项一起走 _resetStallWatchdogProgress()，
      //     _stallRecoveryAttempts 会在重开失败（CDN URL 失效、6s 确认超时）时
      //     被反复清零 → 阶梯永远卡在 1→2→重开→清零 的循环里，
      //     升不到 3 级 refreshPlayUrl，且检测基线也被一起清掉。
      //   所以这里单独 return，既不动阶梯、也不动检测基线；
      //   重开结束后，下一 tick 从上次的状态继续判定。
      if (isRecovering.value) {
        return;
      }
      final drops = _intProp('frame-drop-count');
      if (drops == null) {
        // 属性读不到（播放器已释放等）→ 不做判定。
        _resetStallWatchdogProgress();
        return;
      }
      final last = _stallWatchdogLastDrops;
      _stallWatchdogLastDrops = drops;
      // 首次采样，或计数回退（mpv 重建了 VO）→ 重新起算。
      if (last == null || drops < last) {
        _resetStallWatchdogProgress();
        return;
      }
      final now = DateTime.now();
      final playing = playerStatus.isPlaying;
      final buffering = isBuffering.value;
      final pos = positionInMilliseconds;
      final posFrozen =
          _stallWatchdogLastPosMs >= 0 && pos == _stallWatchdogLastPosMs;
      _stallWatchdogLastPosMs = pos;
      final dropDelta = drops - last;

      // 音频侧：用于判 E（画面在走、声音没了）。与下面那些视频判据共用同一次采样。
      final audioPts = _mpvProp('audio-pts');
      final ao = _mpvProp('current-ao');
      final audioPosFrozen = audioPts != null &&
          _stallWatchdogLastAudioPts != null &&
          audioPts == _stallWatchdogLastAudioPts;
      _stallWatchdogLastAudioPts = audioPts;
      // 音频输出去哪了。只认 mpv 明确给出的字面量：手册（input.rst）记
      // `aid` 在「找不到该轨道」时返回字面量 `no`，`current-ao` 同族。
      // **不把「读不到（null）」算成缺失** —— 读不到是属性不可用，属于
      // 「没有证据」，不能当成「有问题的证据」（与 core-idle 用 `!= yes`
      // 同一个取向：宁可漏判，不可误判）。
      final aoMissing = ao == 'no' || ao == 'null';
      final aid = _mpvProp('aid');
      final audioTrackMissing = aid == 'no';

      // 帧率类指标：管线各段的产出速率。
      final vfFps = double.tryParse(_mpvProp('estimated-vf-fps') ?? '');
      final containerFps = double.tryParse(_mpvProp('container-fps') ?? '');
      final coreIdle = _mpvProp('core-idle');

      // 四种互相独立的卡死形态：
      //   A. 在播 + VO 丢帧快速攀升（经典：声音在放、画面卡住，渲染端没交帧）
      //   B. 在播 + time-pos 纹丝不动
      //   C. 本该播放却没在播（打开视频根本起不来；用户主动暂停、或未开启
      //      自动播放时不算，避免跟用户抢控制权）
      //   D. 在播 + **输出链停摆**：mpv 自称没空闲（core-idle=no）、片源帧率正常
      //      （container-fps ≥ 20），但滤镜链/输出在这个窗口里几乎没有产出
      //      （estimated-vf-fps 塌到 ≤1 帧/秒）。
      //      D 是本次新增，专门覆盖「画面停住却一次丢帧都没有」的形态 ——
      //      帧根本没走到 VO 时 frame-drop-count 不会涨，A/B/C 全都不成立，
      //      用户报的「最近一次卡住完全没有日志」就是这种。
      // A/B/D 在缓冲中不判定（解复用暂时没数据是正常的）；C 不受 buffering 影响，
      // 因为「一直缓冲着起不来」正是要治的形态。
      final dropping = playing && !buffering && dropDelta >= _stallDropDelta;
      // 注意 coreIdle 用的是「不是 yes」而不是「== no」：读不到（null）时
      // 不应该反而把判据压掉；只有明确 idle 才排除。
      final outputStalled =
          playing &&
          !buffering &&
          coreIdle != 'yes' &&
          containerFps != null &&
          containerFps >= 20 &&
          vfFps != null &&
          vfFps <= 1.0;
      final frozenPlaying = playing && !buffering && posFrozen;
      final notPlayingStuck = !playing && !_userPaused && _autoPlay;

      // E. 在播 + 画面照常推进，但**音频输出停摆**（2026-09-19 新增，用户报的
      //    「视频画面继续播放而声音不动」）。
      //
      //    这是前四种形态的镜像，四条判据全都要求「画面出问题」，所以这种一次都
      //    判不出来。判据必须**只依赖音频侧**，且不能碰 time-pos ——
      //    time-pos 在 video-sync=audio 下由音频时钟驱动，音频一停它也就停了，
      //    但用户看到的是「画面还在走」，所以真正能区分的是：
      //      (a) 音频时钟自己不动了：连续两个采样窗口 audio-pts 完全相同；
      //      (b) 更硬的证据：mpv 根本没挂上 AO（current-ao 为 null/no），
      //          或者选中的音频轨不存在了（aid=no）。
      //
      //    ⚠️ 两个必须有的护栏，否则会误判：
      //      1) `_hasAudioTrack()`：**片源本身没有音轨**（纯静音视频）时
      //         aid 恒为 no、AO 也不会挂，条件 (b) 永远成立 —— 不加这条就会
      //         对静音视频无限触发自愈，还会一路升级到整链重建。
      //         只有「轨道存在却没在出声」才算异常。
      //      2) `_audioStallGraceUntil`：起播/重开后 mpv 还没把 AO 挂上、
      //         audio-pts 还是 null 的那几秒同样满足 (b)。给一段宽限期，
      //         避免把「还没起来」当成「停摆了」。
      //
      //    也不在 buffering 里判：缓冲时音频本来就停着，那是正常的。
      //
      //    ⚠️ 还必须要求 `!posFrozen`（画面在推进）。两个理由：
      //      1) 这才是用户报的形状 ——「画面继续播放而声音不动」；
      //      2) 在 video-sync=audio 下 time-pos 由音频时钟驱动，音频真停了
      //         time-pos 多半也停 → 那种情况应该走 frozenPlaying 那条线
      //         （它的阶梯最后会整链重建，音频自然一起重建），不该被这里抢走，
      //         否则会把一次「渲染链停摆」误诊成「AO 问题」而白费一级。
      final audioStalled = playing &&
          !buffering &&
          !posFrozen &&
          !onlyPlayAudio.value &&
          !now.isBefore(_audioStallGraceUntil) &&
          _hasAudioTrack() &&
          (aoMissing || audioTrackMissing || audioPosFrozen);

      // 证据优先：还没到判定阈值、或判据没覆盖到，只要指标有异常迹象，
      // 也按 20s 节流记一条快照。用户感知到的卡死必须在日志里留下痕迹。
      if (playing &&
          !buffering &&
          (dropDelta > 0 || outputStalled || audioStalled) &&
          now.difference(_lastPipelineSuspicionAt) >
              _pipelineSuspicionCooldown) {
        _lastPipelineSuspicionAt = now;
        _logPipelineSnapshot('suspect');
      }

      // 注：这里**没有**再按 `avsync` 判定卡死，只把它记进诊断日志。
      //
      // 曾经想加一条「|avsync| 持续偏大 ⇒ A/V 失步 ⇒ 需要跳转重新对齐」的判据，
      // 因为它看起来比数丢帧更直接。但它没有通过可信度检查，故未采纳：
      //   1) mpv 手册记 `avsync` 在不可用时为 **-1**，而 -1 的绝对值恰好落在
      //      判定区间内 —— 起播初期/状态未就绪时会**误判成卡死**并触发多余的跳转；
      //   2) 更要命的是语义：`avsync` 是「最后一次音视频同步差值」，由视频帧交给
      //      VO 的那一刻算出。渲染端真停摆时不会再有帧交出去，这个值很可能**冻在
      //      最后一次的结果上**，而不是持续漂大 —— 那就又犯了本项目已经踩过的坑
      //      （见 ② 的注释：用 time-pos / video-pts 判断画面冻结都失败，因为它们
      //      由音频时钟或消费端驱动，画面停了它们照旧/不更新）；
      //   3) 误判的代价是可见的：无故往回跳。
      // 所以 `avsync` 只进日志，不参与判定（见 _logPipelineSnapshot / stall 日志）。
      final bad =
          dropping || outputStalled || frozenPlaying || notPlayingStuck || audioStalled;
      _stallWindowHistory.add(bad);
      while (_stallWindowHistory.length > _stallWindowHistorySize) {
        _stallWindowHistory.removeAt(0);
      }
      final badCount = _stallWindowHistory.where((e) => e).length;

      if (badCount == 0) {
        // 最近 _stallWindowHistorySize 个窗口全都干净 → 认为已经恢复。
        _videoStalled = false;
        // 但不是马上把恢复阶梯清回第 1 级：刚恢复过又卡说明「往回跳」救不了，
        // 应当让阶梯继续往上升级。只有安静了 _stallEpisodeResetAfter 才复位。
        if (now.difference(_lastStallRecoverAt) > _stallEpisodeResetAfter) {
          _stallRecoveryAttempts = 0;
        }
      }
      if (badCount >= _stallWindowThreshold) {
        // 判定画面卡死（或根本没起播）。之后每个窗口都会走到这里，
        // 真正的恢复动作由 _onVideoStalled 内的冷却节流。
        if (!_videoStalled) {
          _videoStalled = true;
          _stallEpisodeDrops = drops;
        }
        _onVideoStalled(
          drops,
          // D（输出链停摆）同样靠「跳转重新对齐」恢复，归到 dropping 一档。
          // E（音频停摆）走自己的分支（见 _onVideoStalled）。
          kind: notPlayingStuck
              ? _StallKind.notPlaying
              : audioStalled && !(dropping || outputStalled)
              ? _StallKind.audioStalled
              : (dropping || outputStalled)
              ? _StallKind.dropping
              : _StallKind.frozen,
        );
      }
    });
  }

  // 每个采样窗口调用一次：管线快照的打点，以及主动校正视频输出尺寸。
  void _pipelineTickDiagnostics() {
    if (_videoController?.id.value != null) {
      if (!_loggedPipelineReady) {
        _loggedPipelineReady = true;
        _pipelineReadyTicks = 0;
        _logPipelineSnapshot('ready');
      } else if (_pipelineReadyTicks >= 0 && ++_pipelineReadyTicks >= 3) {
        _pipelineReadyTicks = -1;
        _logPipelineSnapshot('t+6s');
      }
    } else if (_loggedPipelineReady) {
      // 纹理 id 又变回 null（渲染端重建/掉线）→ 值得记一条。
      _loggedPipelineReady = false;
      _pipelineReadyTicks = -1;
      _logPipelineSnapshot('texture-lost');
    }

    // 主动把视频输出尺寸校正成 mpv 报的显示尺寸。
    // 竖屏视频靠这一步才能出现画面（详见 _applyVideoOutputSize 的注释）；
    // 一旦 dw/dh 变化（换分辨率/切片源）会再下发一次。
    _applyVideoOutputSize();

    // 固定时间线：在播时每 30s 无条件记一条，供事后比对卡死前后的状态。
    if (playerStatus.isPlaying &&
        DateTime.now().difference(_lastTimelineAt) > _pipelineTimelinePeriod) {
      _lastTimelineAt = DateTime.now();
      _logPipelineSnapshot('tick');
    }

    // 「后台播放」开着 + 窗口被隐藏/最小化：播放仍在继续，但下面各种判定会
    // 因为「一个可见视图都没有」而停止 —— 这种组合下丢帧会静默累积，
    // 等用户还原窗口时看到的就已经是卡死的画面，而日志里什么都没有
    // （用户反馈的「开启后台播放时仍然卡死、且日志里没有记录」正是这个形状）。
    // 这里至少按 20s 节流留一条证据，把这条路径从"不可观测"变成"可观测"。
    final lc = WidgetsBinding.instance.lifecycleState;
    final noVisibleView =
        lc == AppLifecycleState.hidden ||
        lc == AppLifecycleState.paused ||
        lc == AppLifecycleState.detached;
    if (noVisibleView &&
        playerStatus.isPlaying &&
        !isBuffering.value &&
        DateTime.now().difference(_lastPipelineSuspicionAt) >
            _pipelineSuspicionCooldown) {
      _lastPipelineSuspicionAt = DateTime.now();
      _logPipelineSnapshot('hidden-playing');
    }
  }

  void _resetStallWatchdogProgress() {
    _stallWindowHistory.clear();
    _stallWatchdogLastDrops = null;
    _stallWatchdogLastPosMs = -1;
    _stallWatchdogLastAudioPts = null;
    _stallEpisodeDrops = null;
    _videoStalled = false;
    _stallRecoveryAttempts = 0;
  }

  void _cancelStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _resetStallWatchdogProgress();
  }

  // 画面卡死 / 根本没起播：按「代价从低到高」逐级恢复，每次动作都记一条诊断。
  //   dropping（丢帧型，旧症状：声音在放、画面卡住）
  //     1 级：往回跳 1s —— 把视频 pts 重新对齐到音频，终止丢帧雪崩。
  //           这正是用户手动「往回拖进度条」所做的事，不需要网络、代价最低。
  //   frozen（停滞型，在播但位置不动）
  //     1 级：再显式 play() 一次，很多情况下只是播放在某处被暂停了。
  //   notPlaying（本该播放却没在播，新症状：打开视频根本起不来）
  //     1 级：同上，先把播放状态拉起来（位置本来就没动，跳转没有意义）。
  //   audioStalled（画面在走、声音没了，2026-09-19 新增）
  //     1 级：重建音频输出（_reloadAudioOutput）—— 不动播放位置，
  //           这一档的病根在 AO/音频解码器，跳转与重开都治不到。
  // 之后各级相同：
  //   2 级：重开当前 URL 从当前位置续播（refreshPlayer，不重新拉链接）。
  //   3 级起：让视频页重新拉取播放链接（refreshPlayUrl，最重、依赖网络）。
  // 每一级由 _lastStallRecoverAt + _stallCooldown（自己的、与网络重连分开）节流；
  // 画面恢复正常（某窗口既没丢帧、也没落后音频、位置也在推进、或在正常播放）后
  // _stallRecoveryAttempts 归零。
  void _onVideoStalled(int drops, {required _StallKind kind}) {
    final now = DateTime.now();
    // 用自己的冷却，不共用网络重连的 _lastReconnectAt / _reconnectCooldown。
    // 冷却按倍速缩短（见 _stallCooldownNow）：3 倍速下 6s 的等待相当于
    // 用户眼里的 18s 视频时间，太慢。
    if (now.difference(_lastStallRecoverAt) < _stallCooldownNow) return;
    _lastStallRecoverAt = now;
    _stallRecoveryAttempts++;

    final start = _stallEpisodeDrops ?? drops;
    // 诊断：把 mpv 侧关键状态一次性记下。已知的稳定特征见字段块注释
    // （decoder-drop=0、vo-delayed=0、hwdec 正常 → 是渲染端没交帧）。
    Utils.reportError(
      'video stalled (recovery#$_stallRecoveryAttempts, '
      '${kind.name}, VO dropped ${drops - start} frames): '
      'time-pos=${positionInMilliseconds ~/ 1000}s '
      'hwdec=${_mpvProp('hwdec-current')} vo=${_mpvProp('current-vo')} '
      // avsync = mpv 的「最后一次音视频同步差值」（秒）。这里只记不判：画面冻结
      // 而声音继续时它**可能**是一个越来越大的负值，也可能是冻住不动的旧值
      // （渲染端停摆后不再有帧交给 VO，值就不再更新），而且 mpv 手册记它在不可用
      // 时为 -1 —— 用它做判据会误判，所以先收集实机数据再定。
      'avsync=${_mpvProp('avsync')} '
      // 实际生效的 video-sync 与刷新率信息：用来回答「display-* 到底有没有生效」。
      'video-sync=${_mpvProp('video-sync')} '
      'display-fps=${_mpvProp('display-fps')} '
      'estimated-display-fps=${_mpvProp('estimated-display-fps')} '
      'decoder-drop=${_mpvProp('decoder-frame-drop-count')} '
      'vo-drop=$drops '
      'vo-delayed=${_mpvProp('vo-delayed-frame-count')} '
      'mistimed=${_mpvProp('mistimed-frame-count')} '
      'vsync-ratio=${_mpvProp('vsync-ratio')} '
      'vf-fps=${_mpvProp('estimated-vf-fps')} '
      'container-fps=${_mpvProp('container-fps')} '
      'core-idle=${_mpvProp('core-idle')} '
      'paused-for-cache=${_mpvProp('paused-for-cache')} '
      'demuxer-cache-time=${_mpvProp('demuxer-cache-time')} '
      'cache-buffering=${_mpvProp('cache-buffering-state')} '
      'texture-id=${_videoController?.id.value} '
      'rect=${_videoController?.rect.value} '
      // 尺寸/旋转：竖屏视频相关的关键证据（见 _logPipelineSnapshot 的注释）
      'dw=${_mpvProp('video-out-params/dw')} dh=${_mpvProp('video-out-params/dh')} '
      'rotate=${_mpvProp('video-out-params/rotate')} '
      'isVertical=$_isVertical videoFit=${videoFit.value.name} '
      // lifecycle 用来区分「窗口可见但没焦点（inactive）」和「真的不可见
      // （hidden/paused）」——前台卡死这条线里它是关键判据。
      'lifecycle=${WidgetsBinding.instance.lifecycleState?.name} '
      'state=${playerStatus.value} buffering=${isBuffering.value} '
      'duration=${duration.value}s userPaused=$_userPaused autoPlay=$_autoPlay '
      'callBackNull=${_playCallBack == null} '
      // mpv 侧直接读的暂停/空闲/片尾状态：区分「mpv 被暂停」和「解码/渲染停摆」
      'mpv-pause=${_mpvProp('pause')} idle=${_mpvProp('idle-active')} '
      'eof=${_mpvProp('eof-reached')} seeking=${_mpvProp('seeking')}',
      null,
    );

    // 顺手再记一条完整管线快照（含 audio-pts 之外的全部管线指标），
    // 方便和上面的 stall 行对照出「哪个指标变了」。
    _logPipelineSnapshot('stall#$_stallRecoveryAttempts');

    // ⚠️ 这里**不能**置 `_reconnecting = true`（曾经这么做）。
    // `_reconnecting` 只由 _scheduleReconnect 检查、由 stream.playing 在收到
    // playing==true **状态变化**时清除；而画面卡死时音频照常播放、playing 状态
    // 压根没变过，于是没有任何事件来清除它 —— 一次卡死恢复之后
    // _scheduleReconnect() 会**永久**变成空操作，后面的断流再也没人重连。
    // 卡死恢复与断流重连是两条独立通道，各自的并发保护要分开。
    if (_stallRecoveryAttempts <= 1) {
      if (kind == _StallKind.dropping) {
        // 丢帧型 / 输出停摆型 1 级：往回跳，把视频 pts 重新对齐到音频，
        // 终止「帧持续迟到被丢」的雪崩。这正是用户手动「往回拖进度条」做的事，
        // 不需要网络、代价最低。
        //
        // 回退量按倍速放大（2s × speed，上限 8s）：
        //   - 1 倍速时 2s 的缓冲，在 2 倍速下只相当于 1s、3 倍速下相当于 0.67s，
        //     实测不足以脱离「帧持续迟到」的区间（用户反馈倍速时更容易卡）。
        //   - 上限 8s：再大就不是「对齐」而是明显倒退进度了。
        final rawBackOff = (2000 * _speedFactor).round();
        final backOffMs = rawBackOff < 2000
            ? 2000
            : (rawBackOff > 8000 ? 8000 : rawBackOff);
        final ms = positionInMilliseconds - backOffMs;
        seekTo(Duration(milliseconds: ms < 0 ? 0 : ms), isSeek: false);
      } else if (kind == _StallKind.audioStalled) {
        // 音频停摆型 1 级：重建音频输出。病根在 AO / 音频解码器，
        // 跳转（dropping 的做法）与显式 play（frozen/notPlaying 的做法）都治不到，
        // 而重建 AO 完全不动播放位置，误判代价最低。
        _reloadAudioOutput();
      } else {
        // 停滞型 / 起不来型 1 级：位置本来就没动，跳转没有意义 →
        // 先把播放跑起来（走 _startPlayback，回调缺失时也能兜底）。
        _startPlayback();
      }
      return;
    }
    if (_stallRecoveryAttempts == 2) {
      // 2 级：上一步没救回来 → 重开当前 URL 从当前位置续播。
      // 用 _reloadAtCurrentPosition 而不是 refreshPlayer：它把「重开 → 显式恢复
      // 播放 → 等 playing 确认 → 清缓冲」这条链闭合，内部还会置 isRecovering
      // 点亮自愈加载指示（见该方法的注释）。
      unawaited(_reloadAtCurrentPosition());
      return;
    }
    // 3 级起：重新拉取播放链接（CDN URL 可能已失效）。
    PlPlayerController.refreshPlayUrl();
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
    if (playerStatus.isPlaying && !isBuffering.value && !_videoStalled) {
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
    if (isLive) {
      await setPlaybackSpeed(1.0);
    } else {
      if (_videoPlayerController?.state.rate != _playbackSpeed.value) {
        await setPlaybackSpeed(_playbackSpeed.value);
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
  void _startPlayback() {
    if (_playCallBack == null) {
      play();
    } else {
      playIfExists();
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        WakelockPlus.toggle(enable: playing);
        if (playing) {
          // ARM64 修改版：播放成功恢复，重置重连冷却/计数，允许下次断流重新计时。
          _reconnecting = false;
          _reconnectAttempts = 0;
          _lastReconnectAt = DateTime.fromMillisecondsSinceEpoch(0);
          _resetStallWatchdogProgress();
          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
          playerStatus.value = .playing;
          _ensureStallWatchdog();
        } else {
          _disableAutoEnterPip();
          playerStatus.value = .paused;
        }
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          isBuffering.value,
          isLive,
        );

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
          if (!isSeeking.value) {
            this.position.value = posInSeconds;
          }

          videoPlayerServiceHandler?.onPositionChange(position);

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
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          buffering,
          isLive,
        );
      }),
      stream.log.listen(((PlayerLog log) {
        if (log.level == 'error' || log.level == 'fatal') {
          // 网络断连类错误也走自动重连（log 通道前缀可能是 ffmpeg: tls: IO error）
          if (_isNetworkResetError('${log.prefix}: ${log.text}')) {
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

    if (speed == _videoPlayerController?.state.rate) {
      return;
    }

    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
    if (danmakuController != null) {
      try {
        DanmakuOption currentOption = danmakuController!.option;
        double defaultDuration = currentOption.duration * lastPlaybackSpeed;
        double defaultStaticDuration =
            currentOption.staticDuration * lastPlaybackSpeed;
        DanmakuOption updatedOption = currentOption.copyWith(
          duration: defaultDuration / speed,
          staticDuration: defaultStaticDuration / speed,
        );
        danmakuController!.updateOption(updatedOption);
      } catch (_) {}
    }
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 这是「想要播放」的意图，看门狗据此不再把当前状态当成卡死。
    _userPaused = false;
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
    // 记录「主动暂停」意图：看门狗据此不会把暂停状态当成卡死，
    // 避免自动恢复把用户按下的暂停又按回去。
    _userPaused = true;
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
      if (!isSeeking.value && !tripling) {
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
    // ARM64 修改版（2026-09-17）：记下「用户刚拖过进度条」的时刻。
    // 拖动松手后播放器要重新缓冲、位置也要重新对齐，这段时间画面本来就可能不动；
    // 冻结恢复如果这时插进来，就会和用户自己的拖动打架（自愈重开会把用户拖到的
    // 位置冲掉），加载指示也会叠在一起。给一个宽限期（见 _userSeekGrace）。
    _lastUserSeekAt = DateTime.now();
    hideTaskControls();
  }

  /// 用户最近一次拖动进度条的时刻。
  DateTime _lastUserSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  // 拖动松手后的宽限期：这段时间内不做画面冻结恢复。
  // 8s 是「跳转 + 重新缓冲 + 音频重新对齐」在慢 CDN 下也需要的时间量级。
  static const Duration _userSeekGrace = Duration(seconds: 8);

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
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
    _reloadWatchdog?.cancel();
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
    _cancelStallWatchdog();
    // 自愈重开收尾定时器与进行中旗标一并清掉（对抗验证补充）：
    // dispose 本身不等待 _reloadAtCurrentPosition 的 finally，若恰好在这里
    // 被 dispose（_playerCount 归零），别让 isRecovering 残留。
    _reloadWatchdog?.cancel();
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
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
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
      showDialog(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
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
      ).whenComplete(image.dispose);
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

/// 画面卡死 / 起不来的形态（供看门狗判定与诊断日志使用）。
enum _StallKind {
  /// 正在播放，但 VO 持续丢帧（声音在放、画面冻结）。
  dropping,

  /// 正在播放，但播放位置不再推进。
  frozen,

  /// 本该播放却没有在播（打开视频后一直起不来）。
  notPlaying,

  /// 正在播放、画面照常推进，但**音频输出停摆**（声音没了）。
  ///
  /// 2026-09-19 新增。这是上面三种形态的镜像：整个看门狗原本都是围绕
  /// 「画面冻结、声音继续」建的，四条判据（dropping / outputStalled /
  /// frozenPlaying / notPlayingStuck）**全部要求画面出问题**，所以
  /// 「画面在走、声音没了」一次都判不出来，也就完全没有自愈 —— 用户报的正是这个。
  audioStalled,
}
