import 'dart:async' show StreamSubscription, Timer;
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
  late Rect _lastWindowBounds;

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

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
      'video-sync': Pref.videoSync,
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
  // 连续这么多个窗口都超标才判定卡死（约 4s），避免偶发抖动误判。
  static const int _stallWindowThreshold = 2;
  int _stallWatchdogCount = 0;
  int? _stallWatchdogLastDrops;
  // 上一窗口的 time-pos（毫秒）。用于检测「本应播放但位置纹丝不动」
  // （例如打开后一直 paused / paused-for-cache、或播放器根本没起播）。
  int _stallWatchdogLastPosMs = -1;
  // 本次卡死开始时的累计丢帧数（只用于日志里给出「本段丢了多少帧」）。
  int? _stallEpisodeDrops;
  // 当前是否处于「画面卡住」状态。看门狗写入、_tryReconnect 读取，
  // 用于区分「真的恢复了」和「音频在放但画面卡住」。
  bool _videoStalled = false;
  // 同一次卡死里已按「代价从低到高」尝试过几级恢复；画面恢复正常后清零。
  int _stallRecoveryAttempts = 0;
  // 用户是否主动暂停过。看门狗据此区分「本该播放却起不来」和「用户就是想暂停」，
  // 避免自动恢复把用户按下的暂停又给按回去。play() 清、pause() 置。
  bool _userPaused = false;

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

  // 启动/维持画面卡死看门狗。幂等：已有实例则复用。
  // 仅在 Windows 且非本地文件时启用（WOA 为目标平台）。
  void _ensureStallWatchdog() {
    if (!Platform.isWindows || dataSource is FileSource) return;
    _stallWatchdog ??= Timer.periodic(_stallWatchdogPeriod, (_) {
      if (_playerCount == 0 || dataSource is FileSource) {
        _cancelStallWatchdog();
        return;
      }
      // 正在跳转、页面已切走（vo=libmpv 由渲染请求驱动解码，切走后 mpv 会
      // 停止解码）、应用不在前台时本来就不该有进展，不参与判定。
      // 前台判定很重要：窗口最小化/切到后台时播放本来就是被有意暂停的
      // （continuePlayInBackground 关闭时），此时不能去自动恢复。
      // 注意 **不能**在这里直接按 !isPlaying / isBuffering 退出：形态 C
      // （本该播放却起不来）恰恰就长这个样子。
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (isSeeking.value ||
          !_isCurrVideoPage ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
        _resetStallWatchdogProgress();
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
      final playing = playerStatus.isPlaying;
      final buffering = isBuffering.value;
      final pos = positionInMilliseconds;
      final posFrozen =
          _stallWatchdogLastPosMs >= 0 && pos == _stallWatchdogLastPosMs;
      _stallWatchdogLastPosMs = pos;
      // 三种互相独立的卡死形态：
      //   A. 在播 + VO 丢帧快速攀升（旧症状：声音在放、画面卡住，渲染端没交帧）
      //   B. 在播 + time-pos 纹丝不动
      //   C. 本该播放却没在播（新症状：打开视频根本起不来；用户主动暂停、或
      //      未开启自动播放时不算，避免跟用户抢控制权）
      // A/B 在缓冲中不判定（解复用暂时没数据是正常的）；C 不受 buffering 影响，
      // 因为「一直缓冲着起不来」正是要治的形态。
      final dropping = playing && !buffering && drops - last >= _stallDropDelta;
      final frozenPlaying = playing && !buffering && posFrozen;
      final notPlayingStuck = !playing && !_userPaused && _autoPlay;

      if (dropping || frozenPlaying || notPlayingStuck) {
        _stallWatchdogCount++;
      } else {
        // 这一窗口既没丢帧、位置也在推进 → 已恢复正常，恢复手段从最轻一级重新开始。
        _stallWatchdogCount = 0;
        _videoStalled = false;
        _stallRecoveryAttempts = 0;
      }
      if (_stallWatchdogCount >= _stallWindowThreshold) {
        // 判定画面卡死（或根本没起播）。之后每个窗口都会走到这里，
        // 真正的恢复动作由 _onVideoStalled 内的冷却（_lastReconnectAt）节流。
        if (!_videoStalled) {
          _videoStalled = true;
          _stallEpisodeDrops = drops;
        }
        _onVideoStalled(
          drops,
          kind: notPlayingStuck
              ? _StallKind.notPlaying
              : dropping
              ? _StallKind.dropping
              : _StallKind.frozen,
        );
      }
    });
  }

  void _resetStallWatchdogProgress() {
    _stallWatchdogCount = 0;
    _stallWatchdogLastDrops = null;
    _stallWatchdogLastPosMs = -1;
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
  // 之后各级相同：
  //   2 级：重开当前 URL 从当前位置续播（refreshPlayer，不重新拉链接）。
  //   3 级起：让视频页重新拉取播放链接（refreshPlayUrl，最重、依赖网络）。
  // 每一级由 _lastReconnectAt + _reconnectCooldown 节流；画面恢复正常
  // （某窗口既没丢帧、位置也在推进、或在正常播放）后 _stallRecoveryAttempts 归零。
  void _onVideoStalled(int drops, {required _StallKind kind}) {
    final now = DateTime.now();
    if (now.difference(_lastReconnectAt) < _reconnectCooldown) return;
    _lastReconnectAt = now;
    _reconnecting = true;
    _stallRecoveryAttempts++;

    final start = _stallEpisodeDrops ?? drops;
    // 诊断：把 mpv 侧关键状态一次性记下。已知的稳定特征见字段块注释
    // （decoder-drop=0、vo-delayed=0、hwdec 正常 → 是渲染端没交帧）。
    Utils.reportError(
      'video stalled (recovery#$_stallRecoveryAttempts, '
      '${kind.name}, VO dropped ${drops - start} frames): '
      'time-pos=${positionInMilliseconds ~/ 1000}s '
      'hwdec=${_mpvProp('hwdec-current')} vo=${_mpvProp('current-vo')} '
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
      'state=${playerStatus.value} buffering=${isBuffering.value} '
      'duration=${duration.value}s userPaused=$_userPaused autoPlay=$_autoPlay '
      'callBackNull=${_playCallBack == null} '
      // mpv 侧直接读的暂停/空闲/片尾状态：区分「mpv 被暂停」和「解码/渲染停摆」
      'mpv-pause=${_mpvProp('pause')} idle=${_mpvProp('idle-active')} '
      'eof=${_mpvProp('eof-reached')} seeking=${_mpvProp('seeking')}',
      null,
    );

    if (_stallRecoveryAttempts <= 1) {
      if (kind == _StallKind.dropping) {
        // 丢帧型 1 级：往回跳 1s（不足 1s 就跳到 0）。isSeek: false 避免等待缓冲。
        final ms = positionInMilliseconds - 1000;
        seekTo(Duration(milliseconds: ms < 0 ? 0 : ms), isSeek: false);
      } else {
        // 停滞型 / 起不来型 1 级：位置本来就没动，跳转没有意义 →
        // 先把播放跑起来（走 _startPlayback，回调缺失时也能兜底）。
        _startPlayback();
      }
      return;
    }
    if (_stallRecoveryAttempts == 2) {
      // 2 级：上一步没救回来 → 用当前 URL 从当前位置重开。
      refreshPlayer();
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
    hideTaskControls();
  }

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

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
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
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

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
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
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
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
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
    _cancelStallWatchdog();
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
}
