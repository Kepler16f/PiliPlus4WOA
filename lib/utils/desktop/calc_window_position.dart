import 'dart:ui' show Offset, Rect, Size;

import 'package:PiliPlus/utils/desktop/window_bounds.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:window_manager/window_manager.dart'
    show NativeSizeToSize, PointToOffset, RectangleToRect;

/// 桌面端窗口的最小尺寸。实际使用时会按当前显示器工作区收敛，
/// 见 [fitMinSizeToWorkArea]。
const nativeapi.Size kDesktopMinWindowSize = nativeapi.Size(
  width: 400,
  height: 720,
);

const _displayManager = nativeapi.DisplayManager.instance;

/// 初始/恢复的窗口边界与最小尺寸，二者都按当前显示器工作区收敛。
///
/// 工作区取自 nativeapi 的 [nativeapi.Display.workArea]（已排除任务栏等系统
/// 占位），比屏幕尺寸更贴近「窗口实际能放多大」。
(nativeapi.Size minSize, nativeapi.Rectangle bounds) calcWindowBounds() {
  final workArea = _currentWorkArea;

  final nativeapi.Size minSize;
  final nativeapi.Rectangle bounds;

  if (workArea == null) {
    minSize = kDesktopMinWindowSize;

    final windowSize = Pref.windowSize;
    bounds = nativeapi.Rectangle(
      x: 0,
      y: 0,
      width: windowSize.width,
      height: windowSize.height,
    );
  } else {
    minSize = _toNativeSize(
      fitMinSizeToWorkArea(
        Size(kDesktopMinWindowSize.width, kDesktopMinWindowSize.height),
        workArea,
      ),
    );

    final windowSize = fitWindowSizeToWorkArea(Pref.windowSize, workArea);
    final offset = calcWindowOffset(
      windowSize: windowSize,
      workArea: workArea,
      savedPosition: _savedWindowPosition,
    );
    bounds = nativeapi.Rectangle(
      x: offset.dx,
      y: offset.dy,
      width: windowSize.width,
      height: windowSize.height,
    );
  }

  return (minSize, bounds);
}

nativeapi.Size _toNativeSize(Size size) =>
    nativeapi.Size(width: size.width, height: size.height);

Rect? get _currentWorkArea => _currentDisplay?.workArea.toRect();

Offset? get _savedWindowPosition {
  final position = Pref.windowPosition;
  if (position == null || position.length < 2) return null;
  return Offset(position[0], position[1]);
}

nativeapi.Display? get _currentDisplay {
  final displays = _displayManager.getAll();
  final cursorPosition = _displayManager.getCursorPosition().toOffset();
  return displays.firstWhereOrNull(
        (display) => (display.position.toOffset() & display.size.toSize())
            .contains(cursorPosition),
      ) ??
      _displayManager.getPrimary();
}
