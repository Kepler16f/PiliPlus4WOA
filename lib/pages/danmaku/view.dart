import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_pip_policy.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 传入播放器控制器，监听播放进度，加载对应弹幕
class PlDanmaku extends StatefulWidget {
  final int cid;
  final PlPlayerController playerController;
  final bool isPipMode;
  final bool isFullScreen;
  final bool isFileSource;
  final Size size;

  const PlDanmaku({
    super.key,
    required this.cid,
    required this.playerController,
    this.isPipMode = false,
    required this.isFullScreen,
    required this.isFileSource,
    required this.size,
  });

  @override
  State<PlDanmaku> createState() => _PlDanmakuState();

  bool get notFullscreen => !isFullScreen || isPipMode;
}

class _PlDanmakuState extends State<PlDanmaku> {
  PlPlayerController get playerController => widget.playerController;

  late final PlDanmakuController _plDanmakuController;
  DanmakuController<DanmakuExtra>? _controller;
  int latestAddedPosition = -1;

  @override
  void initState() {
    super.initState();
    _plDanmakuController = PlDanmakuController(
      widget.cid,
      playerController,
      widget.isFileSource,
    );
    if (playerController.enableShowDanmaku.value) {
      if (widget.isFileSource) {
        _plDanmakuController.initFileDmIfNeeded();
      } else {
        _plDanmakuController.queryDanmaku(
          DmUtils.calcSegment(playerController.positionInMilliseconds),
        );
      }
    }
    playerController
      ..addStatusLister(playerListener)
      ..addPositionListener(videoPositionListen);
  }

  @override
  void didUpdateWidget(PlDanmaku oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPipMode != widget.isPipMode ||
        (oldWidget.notFullscreen != widget.notFullscreen &&
            !DanmakuOptions.sameFontScale)) {
      _controller?.updateOption(
        DanmakuOptions.get(
          notFullscreen: widget.notFullscreen,
          isPipMode: widget.isPipMode,
          speed: playerController.playbackSpeed,
        ),
      );
    }
  }

  // 播放器状态监听
  void playerListener(PlayerStatus status) {
    if (_controller case final controller?) {
      if (status.isPlaying) {
        controller.resume();
      } else {
        controller.pause();
      }
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void videoPositionListen(Duration position) {
    if (_controller == null || !playerController.enableShowDanmaku.value) {
      return;
    }

    if (!playerController.showDanmaku && !widget.isPipMode) {
      return;
    }

    if (!playerController.playerStatus.isPlaying) {
      return;
    }

    int currentPosition = position.inMilliseconds;
    currentPosition -= currentPosition % 100; //取整百的毫秒数
    if (currentPosition == latestAddedPosition) {
      return;
    }
    latestAddedPosition = currentPosition;

    List<DanmakuElem>? currentDanmakuList = _plDanmakuController
        .getCurrentDanmaku(currentPosition);
    if (currentDanmakuList != null) {
      final blockColorful = DanmakuOptions.blockColorful;
      final danmakuWeight = DanmakuOptions.danmakuWeight;
      final isPip = widget.isPipMode || playerController.isPipMode;
      // 限制单个 100ms 桶内的新增弹幕上限，避免整秒扎堆弹幕在同一帧内触发大量
      // toImageSync 离屏 FBO 分配导致 PiP / 高密弹幕画面卡顿。
      final maxAddPerTick = DanmakuPipPolicy.maxAddPerTick(isPipMode: isPip);
      final static2Scroll = DanmakuOptions.danmakuStatic2Scroll;
      final massiveMode = !isPip && DanmakuOptions.danmakuMassiveMode;
      int addedCount = 0;
      int scrollRejects = 0;
      bool staticFull = false;
      for (DanmakuElem e in currentDanmakuList) {
        if (e.weight < danmakuWeight) continue;
        final isSelf = e.isSelf;
        if (!isSelf && addedCount >= maxAddPerTick) {
          continue;
        }
        if (e.mode == 7) {
          try {
            if (_controller!.addDanmaku(
              SpecialDanmakuContentItem.fromList(
                DmUtils.decimalToColor(e.color),
                e.fontsize.toDouble(),
                jsonDecode(e.content.replaceAll('\n', '\\n')),
                extra: VideoDanmaku(
                  id: e.id.toInt(),
                  mid: e.midHash,
                  like: e.likeCount.toInt(),
                ),
              ),
            )) {
              addedCount++;
            }
          } catch (_) {}
        } else {
          final dmType = DmUtils.getPosition(e.mode);
          if (!isSelf) {
            if (dmType == DanmakuItemType.scroll) {
              if (!massiveMode && scrollRejects >= 3) continue;
            } else if (staticFull &&
                (!static2Scroll || (!massiveMode && scrollRejects >= 3))) {
              continue;
            }
          }
          final added = _controller!.addDanmaku(
            DanmakuContentItem(
              e.content,
              color: blockColorful
                  ? Colors.white
                  : DmUtils.decimalToColor(e.color),
              type: dmType,
              isColorful:
                  playerController.showVipDanmaku &&
                  e.colorful == DmColorfulType.VipGradualColor,
              count: e.count > 1 ? e.count : null,
              selfSend: isSelf,
              extra: VideoDanmaku(
                id: e.id.toInt(),
                mid: e.midHash,
                like: e.likeCount.toInt(),
              ),
            ),
          );
          if (added) {
            addedCount++;
            if (dmType == DanmakuItemType.scroll) {
              scrollRejects = 0;
            }
          } else if (!isSelf) {
            if (dmType == DanmakuItemType.scroll) {
              scrollRejects++;
            } else {
              staticFull = true;
            }
          }
        }
      }
    }
  }

  @override
  void dispose() {
    playerController
      ..removePositionListener(videoPositionListen)
      ..removeStatusLister(playerListener);
    _plDanmakuController.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = DanmakuOptions.get(
      notFullscreen: widget.notFullscreen,
      isPipMode: widget.isPipMode,
      speed: playerController.playbackSpeed,
    );
    return Obx(
      () {
        final show = playerController.enableShowDanmaku.value;
        final opacity = playerController.danmakuOpacity.value;
        return AnimatedOpacity(
          opacity: show && opacity > 0 ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 100),
          child: DanmakuScreen<DanmakuExtra>(
            createdController: (e) {
              playerController.danmakuController = _controller = e;
            },
            option: option,
            size: widget.size,
            opacity: opacity,
          ),
        );
      },
    );
  }
}
