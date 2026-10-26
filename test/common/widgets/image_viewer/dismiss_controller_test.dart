import 'package:PiliPlus/common/widgets/image_viewer/dismiss_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late GlobalKey<NavigatorState> navigatorKey;
  late BuildContext viewerContext;
  late VoidCallback close;

  Future<void> openViewer(WidgetTester tester) async {
    navigatorKey = GlobalKey<NavigatorState>();
    final controller = ImageViewerDismissController();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('comments')),
      ),
    );
    navigatorKey.currentState!.push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) {
          viewerContext = context;
          close = () => controller.close(context);
          // Match the image viewer's gesture-independent pointer callback.
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerUp: (_) => close(),
            child: const ColoredBox(color: Colors.black),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a blank tap returns to the comments', (tester) async {
    await openViewer(tester);
    await tester.tapAt(const Offset(30, 30));
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(find.text('comments'), findsOneWidget);
  });

  testWidgets('a pending close does not pop a popup or lock dismissal', (
    tester,
  ) async {
    await openViewer(tester);
    final pendingClose = close;
    showDialog<void>(
      context: viewerContext,
      builder: (context) => const AlertDialog(content: Text('image menu')),
    );
    await tester.pumpAndSettle();

    pendingClose();
    await tester.pumpAndSettle();
    expect(find.text('image menu'), findsOneWidget);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 30));
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(find.text('comments'), findsOneWidget);
  });

  testWidgets('a local history pop does not lock subsequent dismissal', (
    tester,
  ) async {
    await openViewer(tester);
    ModalRoute.of(viewerContext)!.addLocalHistoryEntry(LocalHistoryEntry());
    close();
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState!.canPop(), isTrue);

    close();
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('repeated close callbacks only pop the image route', (tester) async {
    await openViewer(tester);
    close();
    close();
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(find.text('comments'), findsOneWidget);
  });
}
