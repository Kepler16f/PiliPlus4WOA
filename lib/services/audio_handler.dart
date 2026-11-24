import 'dart:io' show File, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
  bool canPrev,
  bool canNext,
);

typedef SkipHandlers = ({
  bool Function()? onSkipToPrevious,
  bool Function()? onSkipToNext,
  bool Function()? canSkipToPrevious,
  bool Function()? canSkipToNext,
});

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  final Map<String, MediaItem> _itemsByHeroTag = {};
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  bool Function()? isPlaying;
  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;

  final Map<String, SkipHandlers> _skipHandlers = {};
  final List<String> _heroTagStack = [];

  String? get _activeHeroTag =>
      _heroTagStack.isNotEmpty ? _heroTagStack.last : null;

  SkipHandlers? get _activeSkipHandlers =>
      _activeHeroTag != null ? _skipHandlers[_activeHeroTag!] : null;

  MediaItem? get _activeMediaItem =>
      _activeHeroTag != null ? _itemsByHeroTag[_activeHeroTag!] : null;

  void setSkipHandlers(
    String herotag, {
    bool Function()? onSkipToPrevious,
    bool Function()? onSkipToNext,
    bool Function()? canSkipToPrevious,
    bool Function()? canSkipToNext,
  }) {
    _skipHandlers[herotag] = (
      onSkipToPrevious: onSkipToPrevious,
      onSkipToNext: onSkipToNext,
      canSkipToPrevious: canSkipToPrevious,
      canSkipToNext: canSkipToNext,
    );
    _heroTagStack
      ..remove(herotag)
      ..add(herotag);
    refreshPlaybackState();
  }

  /// Re-activates an existing video page's metadata and playback controls when
  /// returning to it (e.g. via `didPopNext`).
  void activateHeroTag(String herotag) {
    if (!enableBackgroundPlay) return;
    _heroTagStack
      ..remove(herotag)
      ..add(herotag);
    final item = _itemsByHeroTag[herotag];
    if (item != null) {
      setMediaItem(item);
      refreshPlaybackState();
    }
  }

  void refreshPlaybackState() {
    final last = _lastConfig;
    if (!enableBackgroundPlay || _itemsByHeroTag.isEmpty || last == null) return;
    onUpdateState(
      last.$1,
      last.$2,
      last.$3,
      position: _lastPos ?? playbackState.value.updatePosition,
      speed: last.$4,
    );
  }

  @override
  Future<void> play() {
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> pause() {
    return onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null);
  }

  @override
  Future<void> seek(Duration position) {
    return onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position) ??
        Future.syncValue(null);
  }

  @override
  Future<void> skipToPrevious() async {
    if (!enableBackgroundPlay) return;
    _activeSkipHandlers?.onSkipToPrevious?.call();
  }

  @override
  Future<void> skipToNext() async {
    if (!enableBackgroundPlay) return;
    _activeSkipHandlers?.onSkipToNext?.call();
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
  }) {
    if (!enableBackgroundPlay || _itemsByHeroTag.isEmpty) {
      return;
    }

    if (onPlay != null && debugLabel == 'onVideoPaused') return;

    final canPrev = _activeSkipHandlers?.canSkipToPrevious?.call() ?? false;
    final canNext = _activeSkipHandlers?.canSkipToNext?.call() ?? false;
    final newConfig = (status, isBuffering, isLive, speed, canPrev, canNext);
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastPos = position;
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = false;
        processingState = .completed;
      case .playing:
        playing = true;
        processingState = isBuffering ? .buffering : .ready;
      case .paused:
        playing = isBuffering;
        processingState = isBuffering ? .buffering : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
      canPrev: canPrev,
      canNext: canNext,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
    bool canPrev = false,
    bool canNext = false,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
        controls: [
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: .rewind,
            ),
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (!isLive)
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
        ],
        playing: playing,
        systemActions: {
          .seek,
          if (canPrev) .skipToPrevious,
          if (canNext) .skipToNext,
        },
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  static Uri? _coverUri(String? cover) => (cover == null || cover.isEmpty)
      ? null
      : Uri.parse(ImageUtils.safeThumbnailUrl(cover));

  void _pushMediaItem(String herotag, MediaItem item) {
    _heroTagStack
      ..remove(herotag)
      ..add(herotag);
    _itemsByHeroTag[herotag] = item;
    setMediaItem(item);
    refreshPlaybackState();
  }

  /// Pushes immediately-available metadata (e.g. from route arguments or an
  /// episode item) before async detail endpoints return so system media
  /// controls (Windows SMTC) update without staying stuck on the previous video.
  void onVideoPreviewChange({
    required int cid,
    required String herotag,
    String? title,
    String? artist,
    String? album,
    String? cover,
    Duration? duration,
  }) {
    if (!enableBackgroundPlay) return;
    final cleanTitle = title?.trim() ?? '';
    final cleanCover = cover?.trim() ?? '';
    if (cleanTitle.isEmpty && cleanCover.isEmpty) return;

    _pushMediaItem(
      herotag,
      MediaItem(
        id: '$cid$herotag',
        title: cleanTitle,
        artist: artist,
        album: album,
        duration: duration,
        artUri: _coverUri(cleanCover),
      ),
    );
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (data == null) return;

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            album: data.title,
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: _coverUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: _coverUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: _coverUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: _coverUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: _coverUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: _coverUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : _coverUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }
    _pushMediaItem(herotag, mediaItem);
  }

  void onVideoDetailDispose(String herotag) {
    final wasActive = _activeHeroTag == herotag;
    _skipHandlers.remove(herotag);
    _heroTagStack.remove(herotag);
    _itemsByHeroTag.remove(herotag);
    if (!enableBackgroundPlay || !wasActive) return;

    final nextActive = _activeMediaItem;
    if (nextActive != null) {
      setMediaItem(nextActive);
      final canPrev = _activeSkipHandlers?.canSkipToPrevious?.call() ?? false;
      final canNext = _activeSkipHandlers?.canSkipToNext?.call() ?? false;
      playbackState.add(
        playbackState.value.copyWith(
          processingState: .ready,
          playing: false,
          systemActions: {
            .seek,
            if (canPrev) .skipToPrevious,
            if (canNext) .skipToNext,
          },
        ),
      );
    }
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) return;
    if (_itemsByHeroTag.isEmpty) clear();
  }

  void clear() {
    _skipHandlers.clear();
    _heroTagStack.clear();
    _itemsByHeroTag.clear();
    if (!enableBackgroundPlay) return;
    mediaItem.add(null);
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(PlaybackState(processingState: .idle));
  }
}
