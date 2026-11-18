import 'dart:async';
import 'dart:io' show File, HttpClient;
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef ThumbnailLoader = Future<Uint8List?> Function(
  String? artCacheFile,
  Uri? artUri,
);
typedef ThumbnailNormalizer = Future<Uint8List?> Function(Uint8List rawBytes);

/// Windows 平台系统媒体传输控件（SMTC / Windows 控制中心）后端实现。
class WindowsSmtcAudioService extends AudioServicePlatform {
  WindowsSmtcAudioService({
    this.thumbnailLoader,
    ThumbnailNormalizer? thumbnailNormalizer,
    this.httpFallbackDelay = const Duration(milliseconds: 350),
  }) : _thumbnailNormalizer =
            thumbnailNormalizer ?? defaultNormalizeThumbnailBytes {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('piliplus/windows_smtc');
  static const int _maxDirectImageBytes = 1500 * 1024;
  static const int _maxCachedThumbnails = 10;

  final ThumbnailLoader? thumbnailLoader;
  final ThumbnailNormalizer _thumbnailNormalizer;
  final Duration httpFallbackDelay;

  AudioHandlerCallbacks? _callbacks;
  int _durationMs = 0;
  String? _currentMediaId;
  int _artworkRequestToken = 0;
  final Map<String, Uint8List> _thumbnailCache = <String, Uint8List>{};

  static bool isJpegOrPng(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return true;
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return true;
    }
    return false;
  }

  /// Windows SMTC (ShellExperienceHost) 不稳定/不支持直接解码 WebP 缩略图。
  /// 若原始图片是 JPEG/PNG 且体积适中则直传；否则（例如 B 站 @1q.webp）用引擎解码并转码为 PNG。
  static Future<Uint8List?> defaultNormalizeThumbnailBytes(
    Uint8List rawBytes,
  ) async {
    if (rawBytes.isEmpty) return null;
    if (isJpegOrPng(rawBytes) && rawBytes.length <= _maxDirectImageBytes) {
      return rawBytes;
    }
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        rawBytes,
        targetWidth: 512,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService transcode thumbnail error: $e');
      }
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  Future<Uint8List?> _defaultLoadRawThumbnail(
    String? artCacheFile,
    Uri? artUri,
  ) async {
    if (artCacheFile != null && artCacheFile.isNotEmpty) {
      try {
        final file = File(artCacheFile);
        if (file.existsSync()) {
          return await file.readAsBytes();
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('WindowsSmtcAudioService read artCacheFile error: $e');
        }
      }
    }

    if (artUri != null && artUri.isScheme('file')) {
      try {
        final file = File.fromUri(artUri);
        if (file.existsSync()) {
          return await file.readAsBytes();
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('WindowsSmtcAudioService read file artUri error: $e');
        }
      }
    }

    if (artUri != null &&
        (artUri.isScheme('http') || artUri.isScheme('https'))) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(artUri);
        request.headers.set('referer', 'https://www.bilibili.com/');
        request.headers.set(
          'user-agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        );
        final response =
            await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response) {
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          if (bytes.isNotEmpty) {
            return bytes;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('WindowsSmtcAudioService http thumbnail fallback error: $e');
        }
      } finally {
        client.close(force: true);
      }
    }
    return null;
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

  void _cacheThumbnail(String key, Uint8List bytes) {
    _thumbnailCache.remove(key);
    _thumbnailCache[key] = bytes;
    if (_thumbnailCache.length > _maxCachedThumbnails) {
      _thumbnailCache.remove(_thumbnailCache.keys.first);
    }
  }

  Map<String, dynamic> _buildMediaPayload(
    MediaItemMessage item, {
    Uint8List? thumbnailBytes,
  }) {
    return <String, dynamic>{
      'mediaId': item.id,
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      'durationMs': _durationMs,
      'isLive': item.isLive ?? false,
      if (thumbnailBytes != null && thumbnailBytes.isNotEmpty)
        'thumbnailBytes': thumbnailBytes,
    };
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final item = request.mediaItem;
    _durationMs = item.duration?.inMilliseconds ?? 0;
    _currentMediaId = item.id;
    final token = ++_artworkRequestToken;

    String? artCacheFile = item.extras?['artCacheFile'] as String?;
    if (artCacheFile == null && item.artUri?.isScheme('file') == true) {
      try {
        artCacheFile = item.artUri!.toFilePath();
      } catch (_) {}
    }

    final cacheKey = (item.artUri?.toString().isNotEmpty ?? false)
        ? item.artUri!.toString()
        : artCacheFile;
    final cachedBytes = cacheKey != null ? _thumbnailCache[cacheKey] : null;

    try {
      await _channel.invokeMethod(
        'setMediaItem',
        _buildMediaPayload(item, thumbnailBytes: cachedBytes),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService setMediaItem error: $e');
      }
      return;
    }

    if (cachedBytes != null ||
        (cacheKey == null || cacheKey.isEmpty)) {
      return;
    }

    // AudioService 在网络封面未命中缓存时会先发一次不带 artCacheFile 的请求，
    // 并在后台下载完成后补发第二次；若 350ms 内未等到本地缓存文件，则用内部 Dio 兜底下载。
    final isLocalReady =
        (artCacheFile != null && artCacheFile.isNotEmpty) ||
        (item.artUri?.isScheme('file') ?? false);
    if (!isLocalReady && httpFallbackDelay > Duration.zero) {
      await Future<void>.delayed(httpFallbackDelay);
      if (token != _artworkRequestToken || _currentMediaId != item.id) {
        return;
      }
    }

    final rawBytes = thumbnailLoader != null
        ? await thumbnailLoader!(artCacheFile, item.artUri)
        : await _defaultLoadRawThumbnail(artCacheFile, item.artUri);
    if (rawBytes == null ||
        rawBytes.isEmpty ||
        token != _artworkRequestToken ||
        _currentMediaId != item.id) {
      return;
    }

    final normalized = await _thumbnailNormalizer(rawBytes);
    if (normalized == null ||
        normalized.isEmpty ||
        token != _artworkRequestToken ||
        _currentMediaId != item.id) {
      return;
    }

    _cacheThumbnail(cacheKey, normalized);

    try {
      await _channel.invokeMethod(
        'setMediaItem',
        _buildMediaPayload(item, thumbnailBytes: normalized),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('WindowsSmtcAudioService setThumbnail error: $e');
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
        state.controls.any((c) => c.action == MediaActionMessage.skipToNext) ||
        state.systemActions.contains(MediaActionMessage.skipToNext);
    final canPrev =
        state.controls
            .any((c) => c.action == MediaActionMessage.skipToPrevious) ||
        state.systemActions.contains(MediaActionMessage.skipToPrevious);
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
    _currentMediaId = null;
    _artworkRequestToken++;
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
