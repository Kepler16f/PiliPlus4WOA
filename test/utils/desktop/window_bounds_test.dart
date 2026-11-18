import 'dart:ui' show Offset, Rect, Size;

import 'package:PiliPlus/utils/desktop/window_bounds.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fitWindowSizeToWorkArea', () {
    test('keeps a size that already fits', () {
      expect(
        fitWindowSizeToWorkArea(const Size(800, 600), const Rect.fromLTWH(0, 0, 1024, 640)),
        const Size(800, 600),
      );
    });

    test('shrinks a size larger than the work area', () {
      expect(
        fitWindowSizeToWorkArea(const Size(1180, 720), const Rect.fromLTWH(0, 0, 1024, 640)),
        const Size(1024, 640),
      );
    });
  });

  group('fitMinSizeToWorkArea', () {
    test('keeps the default minimum size on a large screen', () {
      expect(
        fitMinSizeToWorkArea(const Size(400, 720), const Rect.fromLTWH(0, 0, 1920, 1080)),
        const Size(400, 720),
      );
    });

    test('clamps the minimum height on a short screen', () {
      expect(
        fitMinSizeToWorkArea(const Size(400, 720), const Rect.fromLTWH(0, 0, 1024, 640)),
        const Size(400, 640),
      );
    });
  });

  group('calcWindowOffset', () {
    test('keeps a saved position that is still visible', () {
      expect(
        calcWindowOffset(
          windowSize: const Size(800, 600),
          workArea: const Rect.fromLTWH(0, 0, 1024, 640),
          savedPosition: const Offset(100, 100),
        ),
        const Offset(100, 100),
      );
    });

    test('recenters a saved position outside the work area', () {
      expect(
        calcWindowOffset(
          windowSize: const Size(800, 600),
          workArea: const Rect.fromLTWH(0, 0, 1024, 640),
          savedPosition: const Offset(2000, 2000),
        ),
        const Offset(112, 20),
      );
    });

    test('recenters a saved position that is only barely visible', () {
      // 只剩 20px 露在工作区内（小于 kWindowKeepVisible）时视为失效。
      expect(
        calcWindowOffset(
          windowSize: const Size(800, 600),
          workArea: const Rect.fromLTWH(0, 0, 1024, 640),
          savedPosition: const Offset(1004, 320),
        ),
        const Offset(112, 20),
      );
    });

    test('respects a work area with a non-zero origin', () {
      expect(
        calcWindowOffset(
          windowSize: const Size(800, 600),
          workArea: const Rect.fromLTWH(-1920, 100, 1024, 640),
        ),
        const Offset(-1808, 120),
      );
    });
  });

  group('calcWindowBounds', () {
    test('clamps both size and position into the work area', () {
      final bounds = calcWindowBounds(
        windowSize: const Size(1180, 720),
        workArea: const Rect.fromLTWH(0, 0, 1024, 640),
      );
      expect(bounds.size, const Size(1024, 640));
      expect(bounds.topLeft, Offset.zero);
    });
  });

  group('calcPipBounds', () {
    const workArea = Rect.fromLTWH(0, 0, 1920, 1080);
    const targetSize = Size(497.7, 280.0);
    const minSize = Size(284.4, 160.0);
    const aspectRatio = 16 / 9;

    test('uses default target size placed at bottom-right when no saved bounds', () {
      final bounds = calcPipBounds(
        targetSize: targetSize,
        minSize: minSize,
        aspectRatio: aspectRatio,
        workArea: workArea,
      );
      expect(bounds.width, closeTo(497.7, 0.1));
      expect(bounds.height, closeTo(280.0, 0.1));
      expect(bounds.right, closeTo(1920 - 24.0, 0.1));
      expect(bounds.bottom, closeTo(1080 - 24.0, 0.1));
    });

    test('rejects corrupted/oversized saved bounds and falls back to targetSize', () {
      // 模拟误存主窗口尺寸（1093.5 x 720）时的场景
      const corruptedSaved = Rect.fromLTWH(100, 100, 1093.5, 720.0);
      final bounds = calcPipBounds(
        targetSize: targetSize,
        minSize: minSize,
        aspectRatio: aspectRatio,
        workArea: workArea,
        savedPipBounds: corruptedSaved,
      );
      expect(bounds.width, closeTo(497.7, 0.1));
      expect(bounds.height, closeTo(280.0, 0.1));
    });

    test('preserves valid saved size and adapts aspect ratio', () {
      const validSaved = Rect.fromLTWH(500, 300, 400.0, 225.0);
      final bounds = calcPipBounds(
        targetSize: targetSize,
        minSize: minSize,
        aspectRatio: aspectRatio,
        workArea: workArea,
        savedPipBounds: validSaved,
      );
      expect(bounds.width, closeTo(400.0, 0.1));
      expect(bounds.height, closeTo(400.0 / aspectRatio, 0.1));
      expect(bounds.left, 500.0);
      expect(bounds.top, 300.0);
    });

    test('clamps position inside work area when saved position is out of bounds', () {
      const outOfBoundsSaved = Rect.fromLTWH(1800, 1000, 400.0, 225.0);
      final bounds = calcPipBounds(
        targetSize: targetSize,
        minSize: minSize,
        aspectRatio: aspectRatio,
        workArea: workArea,
        savedPipBounds: outOfBoundsSaved,
      );
      expect(bounds.right, lessThanOrEqualTo(1920.0));
      expect(bounds.bottom, lessThanOrEqualTo(1080.0));
      expect(bounds.left, greaterThanOrEqualTo(0.0));
      expect(bounds.top, greaterThanOrEqualTo(0.0));
    });
  });
}
