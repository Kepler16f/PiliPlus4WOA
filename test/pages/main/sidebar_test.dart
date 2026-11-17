import 'dart:io';

import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory storage;

  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('piliplus-sidebar-test-');
    Hive.init(storage.path);
    GStorage.regAdapter();
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  setUp(() async {
    await GStorage.setting.clear();
    Get
      ..reset()
      ..put(AccountService());
  });

  tearDown(Get.reset);

  group('MainController.useBottomNav', () {
    test('initializes to false when Pref.useSideBar is enabled', () async {
      await GStorage.setting.put(SettingBoxKey.useSideBar, true);
      final controller = MainController();

      expect(controller.useSideBar, isTrue);
      expect(controller.useBottomNav, isFalse);
    });

    test('defaults to true when Pref.useSideBar is disabled', () {
      final controller = MainController();

      expect(controller.useSideBar, isFalse);
      expect(controller.useBottomNav, isTrue);
    });
  });

  group('MainLayout', () {
    Future<void> pumpLayout(
      WidgetTester tester, {
      required Size viewport,
      required Widget? sideBar,
      required Widget? bottomNav,
      Widget? body,
    }) async {
      tester.view
        ..physicalSize = viewport
        ..devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: MainLayout(
            sideBar: sideBar,
            bottomNav: bottomNav,
            body: body ?? const ColoredBox(color: Colors.white),
          ),
        ),
      );
    }

    for (final viewport in const [Size(400, 800), Size(1180, 720)]) {
      testWidgets(
        'places sideBar on the left and sizes body to remaining width (${viewport.width.toInt()}x${viewport.height.toInt()})',
        (tester) async {
          const sideBarKey = Key('sidebar');
          const bodyKey = Key('body');

          await pumpLayout(
            tester,
            viewport: viewport,
            sideBar: const SizedBox(key: sideBarKey, width: 130),
            bottomNav: null,
            body: const SizedBox.expand(key: bodyKey),
          );

          final sideRect = tester.getRect(find.byKey(sideBarKey));
          final bodyRect = tester.getRect(find.byKey(bodyKey));

          expect(sideRect.topLeft, Offset.zero);
          expect(sideRect.width, 130);
          expect(sideRect.height, viewport.height);

          expect(bodyRect.left, 130);
          expect(bodyRect.top, 0);
          expect(bodyRect.width, viewport.width - 130);
          expect(bodyRect.height, viewport.height);
        },
      );
    }

    testWidgets(
      'centers bottomNav at the bottom while body fills viewport when sideBar is null',
      (tester) async {
        const bottomNavKey = Key('bottomNav');
        const bodyKey = Key('body');

        await pumpLayout(
          tester,
          viewport: const Size(400, 800),
          sideBar: null,
          bottomNav: const SizedBox(key: bottomNavKey, width: 200, height: 64),
          body: const SizedBox.expand(key: bodyKey),
        );

        final navRect = tester.getRect(find.byKey(bottomNavKey));
        final bodyRect = tester.getRect(find.byKey(bodyKey));

        expect(bodyRect, const Rect.fromLTWH(0, 0, 400, 800));
        expect(navRect, const Rect.fromLTWH(100, 736, 200, 64));
      },
    );

    testWidgets(
      'clamps body width to 0 instead of throwing negative BoxConstraints when viewport is narrower than sideBar',
      (tester) async {
        const bodyKey = Key('body');

        await pumpLayout(
          tester,
          viewport: const Size(60, 400),
          sideBar: const SizedBox(width: 130),
          bottomNav: null,
          body: const SizedBox.expand(key: bodyKey),
        );

        expect(tester.takeException(), isNull);
        final bodySize = tester.getSize(find.byKey(bodyKey));
        expect(bodySize, const Size(0, 400));
      },
    );

    testWidgets('renders NavigationRail inside MainLayout without errors', (
      tester,
    ) async {
      await pumpLayout(
        tester,
        viewport: const Size(1180, 720),
        sideBar: NavigationRail(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: const [
            NavigationRailDestination(
              icon: Icon(Icons.home_outlined),
              label: Text('首页'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.motion_photos_on_outlined),
              label: Text('动态'),
            ),
          ],
        ),
        bottomNav: null,
        body: const SizedBox.expand(key: Key('railBody')),
      );

      expect(tester.takeException(), isNull);
      final railRect = tester.getRect(find.byType(NavigationRail));
      final bodyRect = tester.getRect(find.byKey(const Key('railBody')));
      expect(railRect.left, 0);
      expect(bodyRect.left, railRect.width);
      expect(bodyRect.right, 1180);
    });
  });
}
