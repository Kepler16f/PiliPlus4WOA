import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class BottomControl extends StatelessWidget {
  const BottomControl({
    super.key,
    required this.maxWidth,
    required this.isFullScreen,
    required this.controller,
    required this.buildBottomControl,
    required this.videoDetailController,
  });

  final double maxWidth;
  final bool isFullScreen;
  final PlPlayerController controller;
  final ValueGetter<Widget> buildBottomControl;
  final VideoDetailController videoDetailController;

  void onDragStart(ThumbDragDetails duration) {
    feedBack();
    controller
      ..position.value = duration.seconds
      ..isSeeking.value = true;
  }

  void onDragUpdate(ThumbDragDetails duration) {
    if (!controller.isFileSource && controller.showSeekPreview) {
      controller.updatePreviewIndex(duration.seconds);
    }
    controller.position.value = duration.seconds;
  }

  void onSeek(int milliseconds) {
    controller
      ..onSeekEnd()
      ..seekTo(Duration(milliseconds: milliseconds), isSeek: false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final primary = colorScheme.isLight
        ? colorScheme.inversePrimary
        : colorScheme.primary;
    final thumbGlowColor = primary.withAlpha(80);
    final bufferedBarColor = primary.withValues(alpha: 0.4);

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
            child: Obx(
              () => Offstage(
                offstage: !controller.showControls.value,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.bottomCenter,
                  children: [
                    Obx(
                      () => ProgressBar(
                        progress: controller.position.value,
                        buffered: controller.buffered.value,
                        total: controller.duration.value,
                        progressBarColor: primary,
                        baseBarColor: const Color(0x33FFFFFF),
                        bufferedBarColor: bufferedBarColor,
                        thumbColor: primary,
                        thumbGlowColor: thumbGlowColor,
                        barHeight: 3.5,
                        thumbRadius: 7,
                        thumbGlowRadius: 25,
                        onDragStart: onDragStart,
                        onDragUpdate: onDragUpdate,
                        onSeek: onSeek,
                      ),
                    ),
                    if (controller.enableBlock &&
                        videoDetailController.segmentProgressList.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 5.25,
                        child: SegmentProgressBar(
                          segments: videoDetailController.segmentProgressList,
                        ),
                      ),
                    if (controller.showViewPoints &&
                        videoDetailController.viewPointList.isNotEmpty &&
                        videoDetailController.showVP.value)
                      Padding(
                        padding: const .only(bottom: 8.75),
                        child: ViewPointSegmentProgressBar(
                          segments: videoDetailController.viewPointList,
                          onSeek: PlatformUtils.isDesktop
                              ? (position) =>
                                    controller.seekTo(position, isSeek: false)
                              : null,
                        ),
                      ),
                    if (videoDetailController.showDmTrendChart.value)
                      if (videoDetailController.dmTrend.value?.dataOrNull
                          case final list?)
                        buildDmChart(primary, list, videoDetailController, 4.5),
                  ],
                ),
              ),
            ),
          ),
          buildBottomControl(),
        ],
      ),
    );
  }
}

/// ARM64 修改版：视频画面区的加载指示。
///
/// 为什么需要它：播放中途出现卡死时，恢复动作之一是「从当前位置重开」
/// （`_reloadAtCurrentPosition`），重开必然要重新缓冲；而恢复的另一条路径是
/// 「重建视频输出表面」。这两段时间里**声音和画面都会短暂停住、弹幕照常跑**，
/// 用户完全看不出是在自愈，只觉得播放器又坏了。
/// 这里把控制器的 `isBuffering` 直接映射成一个转圈 + 文案，让自愈过程可感知。
///
/// 只在**确实在播放**时显示：用户主动暂停不该弹加载圈
/// （暂停时 `isBuffering` 也可能是 true，语义完全不同）。
class PlPlayerLoadingIndicator extends StatelessWidget {
  const PlPlayerLoadingIndicator({super.key, required this.controller});

  final PlPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final visible =
          controller.isBuffering.value && controller.playerStatus.isPlaying;
      if (!visible) {
        return const SizedBox.shrink();
      }
      return const IgnorePointer(
        child: ColoredBox(
          // 压住画面：否则用户会盯着那张静止的旧帧，以为又卡死了。
          color: Color(0x66000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
                Text(
                  '正在恢复播放…',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
