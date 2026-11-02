import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart' as app;
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('piliplus-refresh-test-');
    Hive.init(storage.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  Future<GlobalKey<app.RefreshIndicatorState>> mount(
    WidgetTester tester,
    Future<void> Function() refresh, {
    bool ticking = true,
  }) async {
    final key = GlobalKey<app.RefreshIndicatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: ticking,
            child: app.RefreshIndicator(
              key: key,
              onRefresh: refresh,
              child: ListView(children: const [SizedBox(height: 1800)]),
            ),
          ),
        ),
      ),
    );
    return key;
  }

  testWidgets('refresh completes with a muted ticker and can run again', (
    tester,
  ) async {
    var calls = 0;
    final key = await mount(tester, () async {
      calls++;
    }, ticking: false);
    var completed = false;
    key.currentState!.show().then((_) => completed = true);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 350));
    expect(completed, isTrue);
    expect(calls, 1);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    key.currentState!.show();
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, 2);
  });

  for (final synchronous in [true, false]) {
    testWidgets(
      'cleans up a ${synchronous ? 'synchronous' : 'future'} callback error',
      (tester) async {
        final key = await mount(tester, () {
          if (synchronous) throw StateError('refresh failed');
          return Future<void>.error(StateError('refresh failed'));
        });
        var completed = false;
        key.currentState!.show().then((_) => completed = true);
        await tester.pump(const Duration(milliseconds: 160));
        expect(tester.takeException(), isA<StateError>());
        await tester.pump(const Duration(milliseconds: 350));
        expect(completed, isTrue);
        expect(find.byType(RefreshProgressIndicator), findsNothing);
      },
    );
  }

  testWidgets(
    'disposing a pending refresh releases show without another callback',
    (tester) async {
      final request = Completer<void>();
      final key = await mount(tester, () => request.future);
      var completed = false;
      key.currentState!.show().then((_) => completed = true);
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(completed, isTrue);
      request.complete();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a previous dismissal cannot erase a new refresh', (
    tester,
  ) async {
    var calls = 0;
    final second = Completer<void>();
    final key = await mount(tester, () {
      calls++;
      return calls == 1 ? Future<void>.value() : second.future;
    }, ticking: false);
    key.currentState!.show();
    await tester.pump(const Duration(milliseconds: 160));
    var completed = false;
    key.currentState!.show().then((_) => completed = true);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, 2);
    expect(completed, isFalse);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    second.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(completed, isTrue);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('a refresh that never completes is released by the watchdog', (
    tester,
  ) async {
    final key = await mount(tester, () => Completer<void>().future);
    var completed = false;
    key.currentState!.show().then((_) => completed = true);
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 350));
    expect(completed, isTrue);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });
}
