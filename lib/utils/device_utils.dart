import 'dart:io' show Platform, exit;

import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, Size;
import 'package:win32/win32.dart' as kernel32;

abstract final class DeviceUtils {
  static final int sdkInt = AndroidHelper.sdkInt();

  static bool get isTablet {
    return size.shortestSide >= 600;
  }

  static Size get size {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize / view.devicePixelRatio;
  }

  static String get platformName => PlatformUtils.isDesktop
      ? 'desktop'
      : isTablet
      ? 'pad'
      : 'phone';

  // 上游 2.1.6（align app exit）：把「真退出」收敛到一个入口。
  // Windows 上 exit(0) 会被 flutter_inappwebview 的残留句柄拖住（进程不退、
  // 托盘图标还在），要显式 TerminateProcess；其余平台走 exit(0)。
  // 见 https://github.com/pichillilorenzo/flutter_inappwebview/issues/2482
  // 与 https://github.com/pichillilorenzo/flutter_inappwebview/issues/2512
  static void exitApp() {
    if (Platform.isWindows) {
      final hProcess = kernel32.GetCurrentProcess();
      kernel32.TerminateProcess(hProcess, 0);
    } else {
      exit(0);
    }
  }
}
