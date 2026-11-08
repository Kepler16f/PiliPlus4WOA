import 'package:PiliPlus/utils/desktop/window_bounds.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/rendering.dart' show Offset, Rect, Size;
import 'package:screen_retriever/screen_retriever.dart';

/// 桌面端窗口的最小尺寸。实际使用时会按当前显示器工作区收敛，
/// 见 [fitMinSizeToWorkArea]。
const Size kDesktopMinWindowSize = Size(400, 720);

/// 当前显示器的工作区（去掉任务栏等系统占位后的可用区域）。
///
/// 取不到时返回 null，调用方退回整屏尺寸。
Future<Rect?> calcWorkArea() async {
  final display = await _currentDisplay();
  if (display == null) return null;
  final visiblePosition = display.visiblePosition;
  final visibleSize = display.visibleSize;
  if (visiblePosition == null || visibleSize == null) {
    return Rect.fromLTWH(0, 0, display.size.width, display.size.height);
  }
  return Rect.fromLTWH(
    visiblePosition.dx,
    visiblePosition.dy,
    visibleSize.width,
    visibleSize.height,
  );
}

/// 最小窗口尺寸，按当前工作区收敛。
///
/// 写死的 400×720 在小屏（如 1024×640 的平板）上比整屏还高，会导致窗口
/// 无法收缩进屏幕内，标题栏与底栏一直留在屏幕之外。
Size calcDesktopMinSize(Rect? workArea) => workArea == null
    ? kDesktopMinWindowSize
    : fitMinSizeToWorkArea(kDesktopMinWindowSize, workArea);

/// 初始/恢复的窗口边界：尺寸收敛到工作区内，位置也落在工作区内。
Rect calcDesktopWindowBounds(Size windowSize, Rect? workArea) {
  if (workArea == null) {
    return Rect.fromLTWH(0, 0, windowSize.width, windowSize.height);
  }
  final saved = Pref.windowPosition;
  final savedPosition = (saved != null && saved.length >= 2)
      ? Offset(saved[0], saved[1])
      : null;
  return calcWindowBounds(
    windowSize: windowSize,
    workArea: workArea,
    savedPosition: savedPosition,
  );
}

Future<Display?> _currentDisplay() async {
  final displays = await screenRetriever.getAllDisplays();
  if (displays.isEmpty) return null;
  final cursorScreenPoint = await screenRetriever.getCursorScreenPoint();
  return displays.firstWhereOrNull((display) {
        final visiblePosition = display.visiblePosition;
        if (visiblePosition == null) return false;
        return (visiblePosition & display.size).contains(cursorScreenPoint);
      }) ??
      await screenRetriever.getPrimaryDisplay();
}
