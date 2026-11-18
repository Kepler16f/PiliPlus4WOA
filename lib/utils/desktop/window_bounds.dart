import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 判定上次保存的窗口位置是否还有效时，要求至少有多少像素留在工作区内
const double kWindowKeepVisible = 30.0;

/// 窗口尺寸不得超过工作区，避免恢复出一个比屏幕还大的窗口
Size fitWindowSizeToWorkArea(Size windowSize, Rect workArea) => Size(
  math.min(windowSize.width, workArea.width),
  math.min(windowSize.height, workArea.height),
);

/// 最小窗口尺寸不得超过工作区，否则小屏（如 1024×640）上窗口无法收缩到屏幕内
Size fitMinSizeToWorkArea(Size minSize, Rect workArea) => Size(
  math.min(minSize.width, workArea.width),
  math.min(minSize.height, workArea.height),
);

/// 计算窗口左上角坐标。
///
/// [savedPosition] 是上次退出时的位置：已经完全不在工作区内（换了显示器、
/// 换了分辨率）时重新居中；仍然可见时留在原处，但会被拉回工作区内。
Offset calcWindowOffset({
  required Size windowSize,
  required Rect workArea,
  Offset? savedPosition,
}) {
  if (savedPosition != null) {
    final dx = savedPosition.dx;
    final dy = savedPosition.dy;
    if (dx > workArea.left + kWindowKeepVisible &&
        dy > workArea.top + kWindowKeepVisible &&
        dx < workArea.right - kWindowKeepVisible &&
        dy < workArea.bottom - kWindowKeepVisible) {
      return Offset(dx, dy);
    }
  }

  return Offset(
    workArea.left + (workArea.width - windowSize.width) / 2,
    workArea.top + (workArea.height - windowSize.height) / 2,
  );
}

/// 计算窗口的初始/恢复边界：尺寸收敛到工作区内，位置落在工作区内。
Rect calcWindowBounds({
  required Size windowSize,
  required Rect workArea,
  Offset? savedPosition,
}) {
  final size = fitWindowSizeToWorkArea(windowSize, workArea);
  final offset = calcWindowOffset(
    windowSize: size,
    workArea: workArea,
    savedPosition: savedPosition,
  );
  return Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
}

/// 计算桌面画中画（PiP）的初始/恢复边界。
///
/// [savedPipBounds] 上次保存的 PiP 窗口边界。如果存在且合法（尺寸未异常超标且仍在屏幕范围内），
/// 则沿用该尺寸与位置（按视频 [aspectRatio] 适配对应边长）；若不存在或异常超大（如曾被误存为主窗口尺寸），
/// 则回退到 [targetSize] 并居右下角摆放。
///
/// 所有尺寸均收敛在 [minSize] 与 [workArea] 之间，且位置被强制限定在工作区边界内（保留安全边距）。
Rect calcPipBounds({
  required Size targetSize,
  required Size minSize,
  required double aspectRatio,
  required Rect workArea,
  Rect? savedPipBounds,
}) {
  final double width, height;
  if (savedPipBounds != null &&
      savedPipBounds.width >= minSize.width &&
      savedPipBounds.height >= minSize.height &&
      savedPipBounds.width <= 700.0 &&
      savedPipBounds.width <= workArea.width * 0.55 &&
      savedPipBounds.height <= workArea.height * 0.55) {
    // 具有合法的上次记忆尺寸：根据当前视频的横纵比调整高度
    final candidateWidth = math.min(savedPipBounds.width, workArea.width);
    final candidateHeight = candidateWidth / aspectRatio;
    if (candidateHeight <= workArea.height) {
      width = math.max(candidateWidth, minSize.width);
      height = math.max(candidateHeight, minSize.height);
    } else {
      height = math.min(savedPipBounds.height, workArea.height);
      width = math.max(height * aspectRatio, minSize.width);
    }
  } else {
    // 默认初始尺寸，受工作区与最小尺寸约束
    width = math.max(math.min(targetSize.width, workArea.width), minSize.width);
    height = math.max(math.min(targetSize.height, workArea.height), minSize.height);
  }

  // 坐标计算：优先保留 savedPipBounds 的位置，若未保存或已不在工作区内，则置于工作区右下角
  const double margin = 24.0;
  final double x, y;
  if (savedPipBounds != null &&
      savedPipBounds.left >= workArea.left - margin &&
      savedPipBounds.top >= workArea.top - margin &&
      savedPipBounds.right <= workArea.right + margin &&
      savedPipBounds.bottom <= workArea.bottom + margin) {
    x = savedPipBounds.left.clamp(workArea.left, math.max(workArea.left, workArea.right - width));
    y = savedPipBounds.top.clamp(workArea.top, math.max(workArea.top, workArea.bottom - height));
  } else {
    x = math.max(workArea.left, workArea.right - width - margin);
    y = math.max(workArea.top, workArea.bottom - height - margin);
  }

  return Rect.fromLTWH(x, y, width, height);
}
