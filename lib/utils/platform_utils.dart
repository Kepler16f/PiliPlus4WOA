import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

abstract final class PlatformUtils {
  @pragma("vm:platform-const")
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  @pragma("vm:platform-const")
  static final bool isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @pragma("vm:platform-const")
  static final bool isDarwin = Platform.isIOS || Platform.isMacOS;

  /// 是否为 Windows ARM64（WoA）环境。
  static final bool isWindowsArm64 =
      Platform.isWindows && Abi.current() == Abi.windowsArm64;
}
