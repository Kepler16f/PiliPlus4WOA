import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:PiliPlus/services/windows_smtc_service.dart';

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
    service = WindowsSmtcAudioService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('piliplus/windows_smtc'),
      null,
    );
  });

  test('setMediaItem formats and invokes setMediaItem method', () async {
    await service.setMediaItem(
      SetMediaItemRequest(
        mediaItem: MediaItemMessage(
          id: 'test_1',
          title: 'Test Video',
          artist: 'Test UP',
          album: 'Test Album',
          duration: const Duration(seconds: 120),
          extras: {'artCacheFile': r'C:\cache\art.jpg'},
        ),
      ),
    );

    expect(methodCalls, hasLength(1));
    final call = methodCalls.first;
    expect(call.method, 'setMediaItem');
    expect(call.arguments['title'], 'Test Video');
    expect(call.arguments['artist'], 'Test UP');
    expect(call.arguments['album'], 'Test Album');
    expect(call.arguments['durationMs'], 120000);
    expect(call.arguments['artCacheFile'], r'C:\cache\art.jpg');
    expect(call.arguments['isLive'], false);
  });

  test('setState maps playback state and control capabilities', () async {
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
            MediaControlMessage(
              androidIcon: 'ic_next',
              label: 'Next',
              action: MediaActionMessage.skipToNext,
            ),
          ],
          systemActions: const {MediaActionMessage.seek},
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
    expect(call.arguments['canSkipToNext'], true);
    expect(call.arguments['canSeek'], true);
  });

  test('stopService invokes clear method', () async {
    await service.stopService(const StopServiceRequest());
    expect(methodCalls, hasLength(1));
    expect(methodCalls.first.method, 'clear');
  });

  test('handles native onButtonPressed and onSeekRequested callbacks', () async {
    final fakeCallbacks = _FakeAudioHandlerCallbacks();
    service.setHandlerCallbacks(fakeCallbacks);

    // Simulate native platform calls
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('piliplus/windows_smtc');

    final playCall = channel.codec.encodeMethodCall(const MethodCall('onButtonPressed', 'play'));
    await messenger.handlePlatformMessage('piliplus/windows_smtc', playCall, (data) {});
    expect(fakeCallbacks.playCalled, isTrue);

    final pauseCall = channel.codec.encodeMethodCall(const MethodCall('onButtonPressed', 'pause'));
    await messenger.handlePlatformMessage('piliplus/windows_smtc', pauseCall, (data) {});
    expect(fakeCallbacks.pauseCalled, isTrue);

    final seekCall = channel.codec.encodeMethodCall(const MethodCall('onSeekRequested', 45000));
    await messenger.handlePlatformMessage('piliplus/windows_smtc', seekCall, (data) {});
    expect(fakeCallbacks.seekPosition, const Duration(seconds: 45));
  });
}
