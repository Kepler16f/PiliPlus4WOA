import 'dart:async' show Timer;
import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:window_manager/window_manager.dart';

/// 桌面窗口的集中管理：位置/尺寸记忆、最小化与隐藏到托盘、关闭、透明度。
///
/// ARM64 修改版：窗口后端已从 window_manager 0.5.x 的经典 API 迁到
/// nativeapi（window_manager 0.6.0 直接 re-export nativeapi 的 Window /
/// WindowManager）。本类保留了迁移前的行为语义：
///   - 进后台（最小化 / 隐藏到托盘）时按「最小化时暂停 || 没开后台播放」
///     决定是否暂停播放，并用自己的标记位记住「这次暂停是为进后台而暂停的」，
///     避免恢复时把用户手动按下的暂停又按回去；
///   - Windows 上隐藏窗口前先置 0 透明度（leanflutter/window_manager#571）。
class WindowController {
  WindowController._();
  static WindowController get instance => _instance;
  static final WindowController _instance = WindowController._();

  nativeapi.Window? _window;
  nativeapi.Window? get window => _window;

  double? _opacity;

  final _setting = GStorage.setting;
  bool _isMaximized = false;
  set windowMaximizedPref(bool value) {
    _setting.put(SettingBoxKey.isWindowMaximized, value);
  }

  Timer? _moveTimer;
  Timer? _resizeTimer;
  static const _kDuration = Duration(milliseconds: 200);

  late bool minimizeOnExit = Pref.minimizeOnExit;
  late bool pauseOnMinimize = Pref.pauseOnMinimize;

  /// 「本次暂停是为了进后台」标记。
  ///
  /// 不用一次性布尔量，因为它有两个坑：
  ///   - 恢复播放后从不清零，于是「最小化→还原→用户手动暂停→从托盘菜单
  ///     显示窗口」会把用户刚按下的暂停又按回去；
  ///   - 已暂停时再隐藏一次会被覆盖成 false（窗口最小化时仍是 IsWindowVisible，
  ///     此时点托盘图标走的是隐藏分支），之后再还原就不会续播。
  bool _pausedForBackground = false;

  void init() {
    assert(_window == null);

    final window = WindowManager.instance.getCurrent();
    if (window == null) return;
    _window = window;
    _windowId = window.addListener(_windowListener);
    _isMaximized = window.isMaximized;
  }

  nativeapi.ListenerId? _windowId;

  void _windowListener(WindowEvent event) {
    switch (event) {
      case WindowFocusedEvent():
        // https://github.com/leanflutter/window_manager/issues/571
        _setOpacityOnWindows(1.0);
        break;
      case WindowBlurredEvent():
        break;
      case WindowMinimizedEvent():
        _pauseIfNeeded();
        break;
      case WindowMaximizedEvent():
        windowMaximizedPref = _isMaximized = true;
        break;
      case WindowRestoredEvent():
        if (_isMaximized) {
          windowMaximizedPref = _isMaximized = false;
        }
        _playIfNeeded();
        break;
      case WindowMovedEvent():
        _moveTimer?.cancel();
        _moveTimer = Timer(_kDuration, onWindowMoved);
        break;
      case WindowResizedEvent():
        _resizeTimer?.cancel();
        _resizeTimer = Timer(_kDuration, onWindowResized);
        break;
      case WindowCreatedEvent():
        break;
      case WindowClosedEvent():
        break;
      case WindowEnteredFullScreenEvent():
        break;
      case WindowExitedFullScreenEvent():
        break;
      case WindowCloseRequestedEvent():
        event.request.cancel();
        if (TrayController.instance.showTrayIcon && minimizeOnExit) {
          _hide();
        } else {
          onClose();
        }
        break;
      case WindowPropertyChangedEvent():
        break;
      case WindowOcclusionChangedEvent():
        break;
      case nativeapi.WindowDockedEvent():
        break;
      case nativeapi.WindowUndockedEvent():
        break;
    }
  }

  void onWindowMoved() {
    final window = _window;
    if (window == null) return;
    // PiP 时不改主窗口记忆，只把 PiP 窗口当前位置记下来（#2997 窗口记忆）。
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    final position = window.position;
    _setting.put(SettingBoxKey.windowPosition, [position.x, position.y]);
  }

  void onWindowResized() {
    final window = _window;
    if (window == null) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    final bounds = window.bounds;
    _setting.putAll({
      SettingBoxKey.windowSize: [bounds.width, bounds.height],
      SettingBoxKey.windowPosition: [bounds.x, bounds.y],
    });
  }

  /// 进入后台（最小化 / 隐藏到托盘）时是否要暂停播放。
  ///
  /// 「后台播放」开关（continuePlayInBackground，默认关，即「进入后台不播」）
  /// 之前只在移动端的生命周期观察者里生效 —— Windows 上该观察者从不触发。
  /// 于是最小化后 mpv 仍在后台解码渲染，而 Flutter 光栅线程随窗口隐藏停摆；
  /// 还原时渲染线程与光栅线程争抢互斥锁、超过 vo 的丢帧上限，视频 pts 落后
  /// 音频、丢帧雪崩不自愈 —— 正是「最小化一段时间后画面卡死、声音正常」的
  /// 根因。在进入后台时暂停播放即可从源头避免累积丢帧。
  ///
  /// 判定：显式开了「最小化时暂停」，或没开「后台播放」，都应当暂停。只有用户
  /// 明确开了后台播放、且没开最小化暂停时，才继续在后台播放。
  bool get _pauseOnEnterBackground =>
      pauseOnMinimize || !Pref.continuePlayInBackground;

  void _playIfNeeded() {
    if (!_pausedForBackground) return;
    _pausedForBackground = false;
    PlPlayerController.instance?.play();
  }

  void _pauseIfNeeded() {
    if (!_pauseOnEnterBackground) return;
    final player = PlPlayerController.instance;
    if (player != null && player.playerStatus.isPlaying) {
      _pausedForBackground = true;
      // pause() 会置 PlPlayerController._userPaused，画面卡死看门狗据此区分
      // 「用户/后台有意暂停」和「播放器卡住」，不会把这里的暂停当卡死去恢复。
      player.pause();
    }
  }

  Future<void> onClose() async {
    await GStorage.compact();
    await GStorage.close();
    TrayController.instance.dispose();
    DeviceUtils.exitApp();
  }

  void _setOpacityOnWindows(double opacity) {
    if (Platform.isWindows && _opacity != opacity) {
      _opacity = opacity;
      _window?.opacity = opacity;
    }
  }

  void _hide() {
    _pauseIfNeeded();
    // https://github.com/leanflutter/window_manager/issues/571
    _setOpacityOnWindows(0.0);
    _window?.hide();
  }

  /// 显示窗口。
  ///
  /// 要注意 show() 在 Windows 上只做 ShowWindowAsync(SW_SHOW) +
  /// SetForegroundWindow，**不会**还原最小化的窗口：若此时就把播放拉起来，
  /// 又会回到「窗口没被真正呈现、mpv 却已在渲染」的原状。而 restore() 只
  /// 判断 showCmd != SW_NORMAL 就发 SC_RESTORE，会误伤**最大化**的窗口（把
  /// 用户拉成普通大小），所以仅在确实处于最小化时才还原。
  void show() {
    final window = _window;
    if (window == null) return;
    if (window.isMinimized) {
      window.restore();
    }
    window
      ..focus()
      ..show();
    _playIfNeeded();
  }

  /// 托盘图标点击：窗口可见则隐藏，不可见则显示。
  void toggleVisibility() {
    final window = _window;
    if (window == null) return;
    if (window.isVisible) {
      _hide();
    } else {
      show();
    }
  }

  void dispose() {
    _moveTimer?.cancel();
    _resizeTimer?.cancel();
    final id = _windowId;
    if (id != null) {
      _window?.removeListener(id);
    }
    _windowId = null;
    _window = null;
  }
}
