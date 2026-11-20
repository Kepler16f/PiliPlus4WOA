import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canvas_danmaku upstream pipeline & microsecond repaint', () {
    testWidgets(
      'addDanmaku defers rasterization to per-frame budget queue (2/frame)',
      (tester) async {
        late DanmakuController<void> controller;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmakuScreen<void>(
                createdController: (c) => controller = c,
                option: const DanmakuOption(
                  fontSize: 16,
                  duration: 6,
                  area: 1.0,
                ),
                size: const Size(500, 280),
              ),
            ),
          ),
        );

        // Add 6 scroll danmaku in a single burst (simulating whole-second spike).
        int added = 0;
        for (int i = 0; i < 6; i++) {
          if (controller.addDanmaku(DanmakuContentItem('弹幕测试 $i'))) {
            added++;
          }
        }
        expect(added, greaterThanOrEqualTo(4));

        // Immediately after addDanmaku, images must NOT be synchronously rasterized.
        final allItems = controller.scrollDanmaku
            .expand((track) => track)
            .toList();
        expect(allItems.length, equals(added));
        expect(
          allItems.where((item) => item.image != null).length,
          equals(0),
          reason: 'addDanmaku must enqueue rasterization instead of blocking',
        );

        // First frame tick drains at most 2 items.
        await tester.pump(const Duration(milliseconds: 16));
        final after1Frame = allItems.where((item) => item.image != null).length;
        expect(after1Frame, lessThanOrEqualTo(2));
        expect(after1Frame, greaterThan(0));

        // After enough frames, all queued items are rasterized.
        for (int f = 0; f < 6; f++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          allItems.where((item) => item.image != null).length,
          equals(added),
        );

        controller.clear();
        await tester.pump(const Duration(milliseconds: 16));
      },
    );

    testWidgets(
      'scrolling frames do not rebuild ScrollDanmakuPainter via ValueListenableBuilder',
      (tester) async {
        late DanmakuController<void> controller;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DanmakuScreen<void>(
                createdController: (c) => controller = c,
                option: const DanmakuOption(
                  fontSize: 16,
                  duration: 4,
                  area: 1.0,
                ),
                size: const Size(500, 280),
              ),
            ),
          ),
        );

        controller.addDanmaku(DanmakuContentItem('微秒时钟无重建测试'));
        await tester.pump(const Duration(milliseconds: 16));

        final customPaintsBefore = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .toList();
        final item = controller.scrollDanmaku.expand((t) => t).first;
        final xBefore = item.xPosition;

        // Advance multiple VSync frames; xPosition must move while CustomPaint painter instances stay identical.
        for (int f = 0; f < 10; f++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final customPaintsAfter = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .toList();

        expect(item.xPosition, lessThan(xBefore));
        expect(
          identical(customPaintsBefore[0], customPaintsAfter[0]),
          isTrue,
          reason:
              'ScrollDanmakuPainter should repaint via super(repaint: frameTime) without rebuilding',
        );
        expect(
          identical(customPaintsBefore[2], customPaintsAfter[2]),
          isTrue,
          reason:
              'SpecialDanmakuPainter should repaint via super(repaint: frameTime) without rebuilding',
        );

        controller.clear();
        await tester.pump(const Duration(milliseconds: 16));
      },
    );

    testWidgets(
      'handles PiP shrink (including 0x0), static danmaku, fixed velocity, pause/resume, and option update safely',
      (tester) async {
        late DanmakuController<void> controller;
        final sizeNotifier = ValueNotifier<Size>(const Size(1092, 614));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<Size>(
                valueListenable: sizeNotifier,
                builder: (context, size, _) => DanmakuScreen<void>(
                  createdController: (c) => controller = c,
                  option: const DanmakuOption(
                    fontSize: 18,
                    duration: 5,
                    staticDuration: 2,
                    scrollFixedVelocity: true,
                    massiveMode: true,
                    area: 1.0,
                  ),
                  size: size,
                ),
              ),
            ),
          ),
        );

        for (int i = 0; i < 8; i++) {
          controller.addDanmaku(DanmakuContentItem('滚动弹幕 $i'));
        }
        controller.addDanmaku(
          DanmakuContentItem('顶部弹幕', type: DanmakuItemType.top),
        );
        controller.addDanmaku(
          DanmakuContentItem('底部弹幕', type: DanmakuItemType.bottom),
        );

        for (int f = 0; f < 6; f++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        // Shrink to PiP size without throwing.
        sizeNotifier.value = const Size(498, 280);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        expect(controller.getTrackCount(), greaterThan(0));

        // Update option while running (triggers clearRasterCache & re-queue).
        controller.updateOption(
          controller.option.copyWith(fontSize: 20, strokeWidth: 2.0),
        );
        await tester.pump(const Duration(milliseconds: 16));

        // Pause, update option while paused, resume.
        controller.pause();
        controller.updateOption(controller.option.copyWith(fontSize: 16));
        await tester.pump(const Duration(milliseconds: 16));
        controller.resume();
        await tester.pump(const Duration(milliseconds: 16));

        // Edge case: shrink to 0x0 and add danmaku safely.
        sizeNotifier.value = Size.zero;
        await tester.pump();
        expect(controller.getTrackCount(), equals(0));
        expect(
          controller.addDanmaku(DanmakuContentItem('零尺寸保护', selfSend: true)),
          isFalse,
        );

        // Restore and clean up.
        sizeNotifier.value = const Size(498, 280);
        await tester.pump();
        controller.clear();
        await tester.pump(const Duration(milliseconds: 16));
        sizeNotifier.dispose();
      },
    );
  });
}
