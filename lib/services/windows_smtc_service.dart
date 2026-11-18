import 'dart:async';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows 平台系统媒体传输控件（SMTC / Windows 控制中心）后端实现。
class WindowsSmtcAudioService extends AudioServicePlatform {
  static const MethodChannel _channel = MethodChannel('piliplus/windows_smtc');
  AudioHandlerCallbacks? _callbacks;
  int _durationMs = 0;

  WindowsSmtcAudioService() {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    final callbacks = _callbacks;
    if (callbacks == null) return;
    switch (call.method) {
      case 'onButtonPressed':
        final button = call.arguments as String?;
        switch (button) {
          case 'play':
            await callbacks.play(const PlayRequest());
            break;
          case 'pause':
            await callbacks.pause(const PauseRequest());
            break;
          case 'stop':
            await callbacks.stop(const StopRequest());
            break;
          case 'next':
            await callbacks.skipToNext(const SkipToNextRequest());
            break;
          case 'previous':
            await callbacks.skipToPrevious(const SkipToPreviousRequest());
            break;
          case 'fastForward':
            await callbacks.fastForward(const FastForwardRequest());
            break;
          case 'rewind':
            await callbacks.rewind(const RewindRequest());
            break;
        }
        break;
      case 'onSeekRequested':
        final positionMs = call.arguments as int?;
        if (positionMs != null) {
          await callbacks.seek(
            SeekRequest(position: Duration(milliseconds: positionMs)),
          );
        }
        break;
    }
  }

  @override
  Future<void> configure(ConfigureRequest request) {
    return SynchronousFuture(null);
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    _callbacks = callbacks;
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final item = request.mediaItem;
    _durationMs = item.duration?.inMilliseconds ?? 0;
    String? artCacheFile = item.extras?['artCacheFile'] as String?;
    if (artCacheFile == null && item.artUri?.isScheme('file') == true) {
      try {
        artCacheFile = item.artUri!.toFilePath();
      } catch (_) {}
    }
    try {
      await _channel.invokeMethod('setMediaItem', {
        'title': item.title,
        'artist': item.artist ?? '',
        'album': item.album ?? '',
        'durationMs': _durationMs,
        'artCacheFile': artCacheFile ?? '',
        'isLive': item.isLive ?? false,
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService setMediaItem error: $e');
      }
    }
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    final state = request.state;
    final canPlay =
        state.controls.any((c) => c.action == MediaActionMessage.play);
    final canPause =
        state.controls.any((c) => c.action == MediaActionMessage.pause);
    final canStop =
        state.controls.any((c) => c.action == MediaActionMessage.stop);
    final canFf =
        state.controls.any((c) => c.action == MediaActionMessage.fastForward);
    final canRewind =
        state.controls.any((c) => c.action == MediaActionMessage.rewind);
    final canNext =
        state.controls.any((c) => c.action == MediaActionMessage.skipToNext);
    final canPrev = state.controls
        .any((c) => c.action == MediaActionMessage.skipToPrevious);
    final canSeek = state.systemActions.contains(MediaActionMessage.seek);

    try {
      await _channel.invokeMethod('setState', {
        'playing': state.playing,
        'processingState': state.processingState.index,
        'positionMs': state.updatePosition.inMilliseconds,
        'durationMs': _durationMs,
        'speed': state.speed,
        'canPlay': canPlay,
        'canPause': canPause,
        'canStop': canStop,
        'canSeek': canSeek,
        'canFastForward': canFf,
        'canRewind': canRewind,
        'canSkipToNext': canNext,
        'canSkipToPrevious': canPrev,
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService setState error: $e');
      }
    }
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    _durationMs = 0;
    try {
      await _channel.invokeMethod('clear');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService stopService error: $e');
      }
    }
  }

  @override
  Future<void> setQueue(SetQueueRequest request) => SynchronousFuture(null);

  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) =>
      SynchronousFuture(null);

  @override
  Future<void> notifyChildrenChanged(NotifyChildrenChangedRequest request) =>
      SynchronousFuture(null);

  @override
  Future<void> setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest request) =>
      SynchronousFuture(null);
}
