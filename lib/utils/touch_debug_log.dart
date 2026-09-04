import 'dart:io';

import 'package:PiliPlus/utils/storage_pref.dart';

/// ARM64 修改版特有的触摸调试日志。
///
/// 由「设置 → 其它设置 → *触摸调试日志」开关控制（[Pref.touchDebugLog]）。
/// 日志写入系统临时目录，复现触摸问题后可将该文件发送给开发者定位问题。
abstract final class TouchDebugLog {
  static String get logFilePath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}piliplus_touch_debug.log';

  static void log(String message) {
    if (!Pref.touchDebugLog) return;
    try {
      final file = File(logFilePath);
      file.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志失败不应影响应用运行。
    }
  }
}
