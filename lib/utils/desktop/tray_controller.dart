import 'dart:io' show Platform;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:tray_manager/tray_manager.dart';

/// 桌面端托盘图标。
///
/// ARM64 修改版：原先这段逻辑直接写在 main/view.dart 里，窗口管理迁到
/// nativeapi 后把它拆到这里，与 [WindowController] 配套：托盘的「显示窗口」
/// 「退出」都交给窗口控制器执行，保证「隐藏到托盘 → 从托盘恢复 → 续播」
/// 这条链路的顺序不被拆散。
class TrayController with TrayListener {
  TrayController._();
  static TrayController get instance => _instance;
  static final TrayController _instance = TrayController._();

  final bool showTrayIcon = Pref.showTrayIcon;

  bool _inited = false;

  void init() {
    if (!showTrayIcon || _inited) return;
    _inited = true;

    trayManager.addListener(this);
    _handleTray();
  }

  Future<void> _handleTray() async {
    if (Platform.isWindows) {
      await trayManager.setIcon(Assets.logoIco);
    } else {
      await trayManager.setIcon(Assets.logoLarge);
    }
    if (!Platform.isLinux) {
      await trayManager.setToolTip(Constants.appName);
    }

    Menu trayMenu = Menu(
      items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出 ${Constants.appName}'),
      ],
    );
    await trayManager.setContextMenu(trayMenu);
  }

  @override
  void onTrayIconMouseDown() {
    // 窗口可见则隐藏，不可见则显示。隐藏/显示与「进后台暂停 / 恢复续播」
    // 都由窗口控制器统一处理，避免两边各做一半导致状态不一致。
    WindowController.instance.toggleVisibility();
  }

  @override
  void onTrayIconRightMouseDown() {
    // ignore: deprecated_member_use
    trayManager.popUpContextMenu(bringAppToFront: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        // 托盘菜单「显示窗口」此前只调用 _show()，漏了 _onShowWindow()：从
        // 托盘菜单恢复窗口就再也没人把播放拉起来，表现成「窗口回来了但一直不播」。
        // 顺序上先显示窗口再恢复播放：窗口真正被呈现之后才恢复播放，否则又会
        // 短暂进入「窗口没被呈现、mpv 却在渲染」的状态。
        WindowController.instance.show();
      case 'exit':
        WindowController.instance.onClose();
    }
  }

  void dispose() {
    if (!_inited) return;
    _inited = false;
    trayManager
      ..removeListener(this)
      ..destroy();
  }
}
