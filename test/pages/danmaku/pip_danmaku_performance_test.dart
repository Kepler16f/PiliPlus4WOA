import 'package:PiliPlus/plugin/pl_player/utils/danmaku_pip_policy.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('DanmakuPipPolicy', () {
    test('scales desktop PiP font size down proportionally and clamps >= 12', () {
      expect(
        DanmakuPipPolicy.effectiveFontSize(
          notFullscreen: true,
          isPipMode: false,
          fontScale: 1.4,
          fontScaleFS: 1.7,
          isDesktop: true,
        ),
        closeTo(21.0, 1e-6),
      );

      expect(
        DanmakuPipPolicy.effectiveFontSize(
          notFullscreen: true,
          isPipMode: true,
          fontScale: 1.4,
          fontScaleFS: 1.7,
          isDesktop: true,
        ),
        closeTo(15.75, 1e-6),
      );

      expect(
        DanmakuPipPolicy.effectiveFontSize(
          notFullscreen: true,
          isPipMode: true,
          fontScale: 0.6,
          fontScaleFS: 1.0,
          isDesktop: true,
        ),
        12.0,
      );

      expect(
        DanmakuPipPolicy.effectiveStrokeWidth(
          strokeWidth: 2.5,
          isPipMode: true,
        ),
        2.0,
      );
      expect(
        DanmakuPipPolicy.effectiveMassiveMode(
          massiveMode: true,
          isPipMode: true,
        ),
        isFalse,
      );
      expect(DanmakuPipPolicy.maxAddPerTick(isPipMode: true), 4);
      expect(DanmakuPipPolicy.maxAddPerTick(isPipMode: false), 10);
    });
  });

  group('DanmakuScreen PiP density and lifecycle', () {
    testWidgets(
      'caps same-frame track additions in PiP and reuses cached images safely',
      (tester) async {
        late DanmakuController<Object> controller;
        Size screenSize = const Size(498, 280);
        double opacity = 0.7;

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                return Center(
                  child: DanmakuScreen<Object>(
                    createdController: (c) => controller = c,
                    option: const DanmakuOption(
                      fontSize: 16,
                      area: 0.5,
                      strokeWidth: 2.0,
                      massiveMode: true,
                      static2Scroll: true,
                    ),
                    size: screenSize,
                    opacity: opacity,
                  ),
                );
              },
            ),
          ),
        );

        final trackCount = controller.trackCount;
        expect(trackCount, greaterThan(0));

        // Burst 60 danmaku in the exact same frame (simulating a whole-second
        // bucket in a dense video while in PiP). Even with massiveMode=true,
        // no two danmaku should stack at x=viewWidth on the same track on the
        // same frame.
        int added = 0;
        for (int i = 0; i < 60; i++) {
          final text = i % 3 == 0 ? '哈哈哈' : '测试弹幕_$i';
          if (controller.addDanmaku(DanmakuContentItem<Object>(text))) {
            added++;
          }
        }
        expect(added, equals(trackCount));
        for (final track in controller.scrollDanmaku) {
          expect(track.length, lessThanOrEqualTo(1));
        }

        // Pump a few frames so danmaku move and paint cleanly with opacity < 1.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 100));

        // Add static danmaku wider than PiP viewWidth to verify static2Scroll
        // fallback path does not leak or throw.
        controller.addDanmaku(
          DanmakuContentItem<Object>(
            '这是一条非常非常非常非常非常非常非常非常长的顶部静态弹幕用于测试画中画窗口宽度超出时转滚动',
            type: DanmakuItemType.top,
          ),
        );

        // Shrink window size (entering smaller PiP / zero tracks edge case)
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: DanmakuScreen<Object>(
                createdController: (c) => controller = c,
                option: const DanmakuOption(
                  fontSize: 16,
                  area: 0.5,
                  strokeWidth: 2.0,
                  massiveMode: false,
                  static2Scroll: true,
                ),
                size: const Size(200, 20),
                opacity: 0.5,
              ),
            ),
          ),
        );
        expect(controller.trackCount, equals(0));
        expect(
          controller.addDanmaku(DanmakuContentItem<Object>('零轨道不崩溃')),
          isFalse,
        );

        // Dispose widget cleanly (verifies cloned cached ui.Image disposal)
        await tester.pumpWidget(const SizedBox.shrink());
        DmUtils.clearImageCache();
      },
    );
  });
}
