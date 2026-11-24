import 'dart:async';

import 'package:PiliPlus/services/windows_smtc_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAudioHandlerCallbacks implements AudioHandlerCallbacks {
  bool playCalled = false;
  bool pauseCalled = false;
  bool stopCalled = false;
  bool nextCalled = false;
  bool prevCalled = false;
  bool ffCalled = false;
  bool rewindCalled = false;
  Duration? seekPosition;

  @override
  Future<void> play(PlayRequest request) async {
    playCalled = true;
  }

  @override
  Future<void> pause(PauseRequest request) async {
    pauseCalled = true;
  }

  @override
  Future<void> stop(StopRequest request) async {
    stopCalled = true;
  }

  @override
  Future<void> skipToNext(SkipToNextRequest request) async {
    nextCalled = true;
  }

  @override
  Future<void> skipToPrevious(SkipToPreviousRequest request) async {
    prevCalled = true;
  }

  @override
  Future<void> fastForward(FastForwardRequest request) async {
    ffCalled = true;
  }

  @override
  Future<void> rewind(RewindRequest request) async {
    rewindCalled = true;
  }

  @override
  Future<void> seek(SeekRequest request) async {
    seekPosition = request.position;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pngBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2]);
  final jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);
  final webpBytes = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);

  late WindowsSmtcAudioService service;
  final List<MethodCall> methodCalls = [];

  setUp(() {
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('piliplus/windows_smtc'),
      (call) async {
        methodCalls.add(call);
        return null;
      },
    );
    service = WindowsSmtcAudioService(
      httpFallbackDelay: Duration.zero,
      thumbnailLoader: (artCacheFile, artUri) async => null,
      thumbnailNormalizer: (raw) async => pngBytes,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('piliplus/windows_smtc'),
      null,
    );
  });

  test('isJpegOrPng detects JPEG, PNG, and rejects WebP', () {
    expect(WindowsSmtcAudioService.isJpegOrPng(pngBytes), isTrue);
    expect(WindowsSmtcAudioService.isJpegOrPng(jpegBytes), isTrue);
    expect(WindowsSmtcAudioService.isJpegOrPng(webpBytes), isFalse);
    expect(WindowsSmtcAudioService.isJpegOrPng(Uint8List(0)), isFalse);
  });

  test('setMediaItem sends metadata and normalized thumbnailBytes and caches it', () async {
    int loadCount = 0;
    int normalizeCount = 0;
    service = WindowsSmtcAudioService(
      httpFallbackDelay: Duration.zero,
      thumbnailLoader: (artCacheFile, artUri) async {
        loadCount++;
        return webpBytes;
      },
      thumbnailNormalizer: (raw) async {
        normalizeCount++;
        return pngBytes;
      },
    );

    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'test_1',
          title: 'Test Video',
          artist: 'Test UP',
          album: 'Test Album',
          duration: const Duration(seconds: 120),
          artUri: Uri.parse('https://i0.hdslb.com/bfs/archive/test.jpg@1q.webp'),
          extras: const {'artCacheFile': r'C:\cache\art.webp'},
        ),
      ),
    );
    // Metadata call is sent immediately without blocking on thumbnail I/O.
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.arguments['mediaId'], 'test_1');
    expect(methodCalls.first.arguments['title'], 'Test Video');
    expect(methodCalls.first.arguments['artist'], 'Test UP');
    expect(methodCalls.first.arguments['album'], 'Test Album');
    expect(methodCalls.first.arguments['durationMs'], 120000);
    expect(methodCalls.first.arguments['thumbnailBytes'], isNull);

    await service.pendingThumbnailFuture;

    expect(loadCount, 1);
    expect(normalizeCount, 1);
    expect(methodCalls, hasLength(2));
    expect(methodCalls.last.arguments['mediaId'], 'test_1');
    expect(methodCalls.last.arguments['thumbnailBytes'], equals(pngBytes));

    // Duplicate callback for the same mediaId & cover does not re-send thumbnailBytes.
    methodCalls.clear();
    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'test_1',
          title: 'Test Video',
          artist: 'Test UP',
          artUri: Uri.parse('https://i0.hdslb.com/bfs/archive/test.jpg@1q.webp'),
          extras: const {'artCacheFile': r'C:\cache\art.webp'},
        ),
      ),
    );
    expect(loadCount, 1);
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.arguments['thumbnailBytes'], isNull);

    // Second item with the same artUri hits in-memory cache immediately
    methodCalls.clear();
    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'test_2',
          title: 'Part 2',
          artist: 'Test UP',
          artUri: Uri.parse('https://i0.hdslb.com/bfs/archive/test.jpg@1q.webp'),
        ),
      ),
    );
    expect(loadCount, 1);
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.arguments['thumbnailBytes'], equals(pngBytes));
  });

  test('refining metadata for same mediaId keeps in-flight thumbnail and applies latest fields', () async {
    final completer = Completer<Uint8List?>();
    int loadCount = 0;
    service = WindowsSmtcAudioService(
      httpFallbackDelay: Duration.zero,
      thumbnailLoader: (artCacheFile, artUri) {
        loadCount++;
        return completer.future;
      },
      thumbnailNormalizer: (raw) async => raw,
    );

    // Preview metadata arrives immediately on switch.
    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'vid_100',
          title: 'Preview Title',
          artUri: Uri.parse('https://example.com/cover100.jpg'),
        ),
      ),
    );
    // Full metadata arrives while thumbnail is still downloading.
    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'vid_100',
          title: 'Full Title',
          artist: 'Real UP',
          duration: const Duration(seconds: 180),
          artUri: Uri.parse('https://example.com/cover100.jpg'),
        ),
      ),
    );

    // Must not abort and restart the in-flight thumbnail download.
    expect(loadCount, 1);

    completer.complete(jpegBytes);
    await service.pendingThumbnailFuture;

    expect(methodCalls.last.arguments['mediaId'], 'vid_100');
    expect(methodCalls.last.arguments['title'], 'Full Title');
    expect(methodCalls.last.arguments['artist'], 'Real UP');
    expect(methodCalls.last.arguments['durationMs'], 180000);
    expect(methodCalls.last.arguments['thumbnailBytes'], equals(jpegBytes));
  });

  test('setMediaItem drops stale thumbnail when media switches mid-load', () async {
    final completer = Completer<Uint8List?>();
    service = WindowsSmtcAudioService(
      httpFallbackDelay: Duration.zero,
      thumbnailLoader: (artCacheFile, artUri) {
        if (artUri?.toString().contains('first') ?? false) {
          return completer.future;
        }
        return Future.value(jpegBytes);
      },
      thumbnailNormalizer: (raw) async => raw,
    );

    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'first',
          title: 'First Video',
          artUri: Uri.parse('https://example.com/first.jpg'),
        ),
      ),
    );
    final firstThumbFuture = service.pendingThumbnailFuture;

    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'second',
          title: 'Second Video',
          artUri: Uri.parse('https://example.com/second.jpg'),
        ),
      ),
    );
    await service.pendingThumbnailFuture;

    completer.complete(pngBytes);
    await firstThumbFuture;

    final staleFirstThumbCalls = methodCalls.where(
      (c) =>
          c.arguments['mediaId'] == 'first' &&
          c.arguments['thumbnailBytes'] != null,
    );
    expect(staleFirstThumbCalls, isEmpty);

    final secondThumbCalls = methodCalls.where(
      (c) =>
          c.arguments['mediaId'] == 'second' &&
          c.arguments['thumbnailBytes'] != null,
    );
    expect(secondThumbCalls, hasLength(1));
  });

  test('setState maps controls and systemActions skip/seek capabilities', () async {
    await service.setState(
      SetStateRequest(
        state: PlaybackStateMessage(
          playing: true,
          processingState: AudioProcessingStateMessage.ready,
          updatePosition: const Duration(seconds: 35),
          speed: 1.25,
          controls: const [
            MediaControlMessage(
              androidIcon: 'ic_play',
              label: 'Pause',
              action: MediaActionMessage.pause,
            ),
          ],
          systemActions: const {
            MediaActionMessage.seek,
            MediaActionMessage.skipToPrevious,
            MediaActionMessage.skipToNext,
          },
        ),
      ),
    );

    expect(methodCalls, hasLength(1));
    final call = methodCalls.first;
    expect(call.method, 'setState');
    expect(call.arguments['playing'], true);
    expect(call.arguments['positionMs'], 35000);
    expect(call.arguments['speed'], 1.25);
    expect(call.arguments['canPlay'], false);
    expect(call.arguments['canPause'], true);
    expect(call.arguments['canSkipToPrevious'], true);
    expect(call.arguments['canSkipToNext'], true);
    expect(call.arguments['canSeek'], true);
  });

  test('stopService invokes clear method', () async {
    await service.stopService(const StopServiceRequest());
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.method, 'clear');
  });

  test('stopService ignores stale clear during active session until idle', () async {
    await service.setMediaItem(
      const SetMediaItemRequest(
        mediaItem: MediaItemMessage(id: 'video-1', title: 'Test Video'),
      ),
    );
    await service.setState(
      SetStateRequest(
        state: PlaybackStateMessage(
          playing: true,
          processingState: AudioProcessingStateMessage.ready,
          updatePosition: Duration.zero,
          speed: 1.0,
          controls: const [],
          systemActions: const {},
        ),
      ),
    );
    methodCalls.clear();

    // Delayed stopService arriving while a new session is active must not wipe SMTC.
    await service.stopService(const StopServiceRequest());
    expect(methodCalls, isEmpty);

    // Once the state transitions to idle, stopService clears SMTC as expected.
    await service.setState(
      SetStateRequest(
        state: PlaybackStateMessage(
          playing: false,
          processingState: AudioProcessingStateMessage.idle,
          updatePosition: Duration.zero,
          speed: 1.0,
          controls: const [],
          systemActions: const {},
        ),
      ),
    );
    methodCalls.clear();

    await service.stopService(const StopServiceRequest());
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.method, 'clear');
  });

  test('handles native onButtonPressed (including next/previous) and onSeekRequested', () async {
    final fakeCallbacks = _FakeAudioHandlerCallbacks();
    service.setHandlerCallbacks(fakeCallbacks);

    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('piliplus/windows_smtc');

    for (final name in ['play', 'pause', 'next', 'previous']) {
      final msg = channel.codec.encodeMethodCall(MethodCall('onButtonPressed', name));
      await messenger.handlePlatformMessage('piliplus/windows_smtc', msg, (_) {});
    }
    expect(fakeCallbacks.playCalled, isTrue);
    expect(fakeCallbacks.pauseCalled, isTrue);
    expect(fakeCallbacks.nextCalled, isTrue);
    expect(fakeCallbacks.prevCalled, isTrue);

    final seekCall = channel.codec.encodeMethodCall(const MethodCall('onSeekRequested', 45000));
    await messenger.handlePlatformMessage('piliplus/windows_smtc', seekCall, (_) {});
    expect(fakeCallbacks.seekPosition, const Duration(seconds: 45));
  });
}
