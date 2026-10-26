import 'package:flutter/widgets.dart';

/// Prevents repeated pointer events from dismissing more than the image route.
class ImageViewerDismissController {
  bool _closing = false;

  void close(BuildContext context) {
    if (_closing || !context.mounted) return;
    final route = ModalRoute.of(context);
    // A delayed gesture must not pop a menu/dialog above the image and leave
    // this controller permanently latched while the image route stays open.
    if (route == null || !route.isCurrent) return;

    _closing = true;
    try {
      Navigator.of(context).pop();
    } finally {
      // A route may consume pop through local history or reject it in didPop.
      // Keep the repeat-pop guard only when the image route actually left.
      if (route.isCurrent) _closing = false;
    }
  }
}
