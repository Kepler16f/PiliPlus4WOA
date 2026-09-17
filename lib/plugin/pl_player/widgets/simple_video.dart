import 'dart:async';

import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// ARM64 修改版（2026-09-14）：自带的视频画面控件，替代 media_kit_video 的
/// `SimpleVideo`。
///
/// 为什么换掉 `SimpleVideo`
/// （media_kit_video/lib/src/video/simple_video_texture.dart）：
///
/// 它要**同时**满足三个条件才肯把画面画出来 ——
///   1. `controller.id != null`
///   2. `controller.rect != null`
///   3. `_visible`（由 `player.stream.size` 推出的「宽高都 > 0」）
/// 任何一条不成立就直接返回一个空的 `SizedBox()`。而它的外层是
/// `Container(color: 黑)`，于是「渲染端根本没建立起来」和「一切正常但画面是黑的」
/// 在视觉上完全无法区分 —— 用户看到的都是黑屏，日志里也什么都留不下。
///
/// 实测竖屏（height > width）视频**每一个都黑屏、横屏全部正常**，且已存在多个
/// 版本。这条路径正是最可疑的落点：只要 `rect` 因为 media_kit_video 原生侧
/// `GetVideoWidth/GetVideoHeight()` 的 rotate 分支（rotate 为 90/270 时把 mpv
/// 报的 `dw`/`dh` 对调）算出 <1 的值，`CheckAndResize()` 就会直接 return、
/// 连 `id` 都不会下发，画面自然永远不出现。
///
/// 本控件的做法：
///   - 只要 `id != null` 就绘制（不再要求 rect/visible）；
///   - 尺寸优先用 `rect`（与 SimpleVideo 完全一致），`rect` 不可用时退回到
///     调用方给的片源宽高比 —— 由于外层是 `FittedBox`，兜底时只有宽高比有意义，
///     所以用一个固定的基准高度即可；
///   - 把「rect 不可用」这件事记一条日志，使黑屏可诊断。
///
/// 注意：`rect` 正常时本控件的尺寸计算与 `SimpleVideo` **逐字一致**，
/// 因此不会改变横屏视频的既有表现。
class PlSimpleVideo extends StatefulWidget {
  const PlSimpleVideo({
    super.key,
    required this.controller,
    this.aspectRatio,
    this.sourceAspectRatio,
    this.filterQuality = FilterQuality.low,
  });

  /// 视频控制器（提供 texture id 与 rect）。
  final VideoController controller;

  /// 用户选择的画面比例（`VideoFitType.aspectRatio`），一般为 null。
  final double? aspectRatio;

  /// 兜底宽高比（片源 width / height）。`rect` 不可用时用它决定绘制框的形状。
  final double? sourceAspectRatio;

  final FilterQuality filterQuality;

  @override
  State<PlSimpleVideo> createState() => _PlSimpleVideoState();
}

class _PlSimpleVideoState extends State<PlSimpleVideo> {
  double _devicePixelRatio = 1.0;
  StreamSubscription<(int, int)>? _sizeSubscription;
  // 每个实例只记一次「rect 不可用」，避免刷屏。
  bool _reportedMissingRect = false;

  static const double _fallbackBaseHeight = 1000.0;

  @override
  void initState() {
    super.initState();
    // 不使用 stream.size 决定是否绘制（那正是 SimpleVideo 的毛病之一），
    // 只借它来触发一次重建，让 rect 更新后能及时反映出来。
    _sizeSubscription = widget.controller.player.stream.size.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sizeSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ratio = MediaQuery.devicePixelRatioOf(context);
    _devicePixelRatio = ratio <= 0 ? 1.0 : ratio;
  }

  @override
  Widget build(BuildContext context) {
    final ctr = widget.controller;
    return ListenableBuilder(
      listenable: Listenable.merge([ctr.id, ctr.rect]),
      builder: (context, _) {
        final id = ctr.id.value;
        if (id == null) {
          // 渲染端还没建立：给不出任何画面（外层 Container 的黑色会露出来）。
          // ⚠️ 必须是 shrink 不能是 expand：本控件在 FittedBox 里被以无界约束布局，
          // 返回无限尺寸会触发布局断言。
          return const SizedBox.shrink();
        }

        final rect = ctr.rect.value;
        final rectUsable =
            rect != null && rect.width > 1.0 && rect.height > 1.0;

        final double width;
        final double height;
        if (rectUsable) {
          // ↓ 与 SimpleVideo 的算法保持一致，横屏行为不变
          height = rect.height / _devicePixelRatio;
          width = widget.aspectRatio == null
              ? rect.width / _devicePixelRatio
              : height * widget.aspectRatio!;
        } else {
          // rect 不可用 —— 这时候 SimpleVideo 什么都不画（黑屏）。
          // 这里改用片源宽高比兜底：外层是 FittedBox，绝对尺寸无所谓，只有比例有意义。
          if (!_reportedMissingRect) {
            _reportedMissingRect = true;
            Utils.reportError(
              'video surface: rect not usable, drawing with source aspect as '
              'fallback (texture-id=$id rect=$rect '
              'sourceAspectRatio=${widget.sourceAspectRatio} '
              'aspectRatio=${widget.aspectRatio} dpr=$_devicePixelRatio)',
              null,
            );
            if (kDebugMode) {
              debugPrint('PlSimpleVideo: rect=$rect, falling back');
            }
          }
          final ratio =
              widget.aspectRatio ?? widget.sourceAspectRatio ?? (16 / 9);
          final safeRatio = ratio.isFinite && ratio > 0 ? ratio : 16 / 9;
          height = _fallbackBaseHeight;
          width = height * safeRatio;
        }

        return SizedBox(
          width: width,
          height: height,
          child: Texture(textureId: id, filterQuality: widget.filterQuality),
        );
      },
    );
  }
}
