import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/utils/storage_pref.dart';

/// ARM64 修改版特有的触摸调试日志。
///
/// 由「设置 → 其它设置 → *触摸调试日志」开关控制（[Pref.touchDebugLog]）。
/// 日志写入系统临时目录，复现触摸问题后可将该文件发送给开发者定位问题。
abstract final class TouchDebugLog {
  static final _buffer = StringBuffer();
  static bool _scheduled = false;

  static String get logFilePath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}piliplus_touch_debug.log';

  static void log(String message) {
    if (!Pref.touchDebugLog) return;
    // Scroll notifications run on the UI isolate. Never force a disk flush for
    // every pointer move; a slow disk must not stall the gesture being logged.
    if (_buffer.length < 64 * 1024) {
      _buffer.writeln('[${DateTime.now().toIso8601String()}] $message');
    }
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    if (_scheduled || _buffer.isEmpty) return;
    _scheduled = true;
    Timer(const Duration(milliseconds: 250), _flush);
  }

  static Future<void> _flush() async {
    final text = _buffer.toString();
    _buffer.clear();
    try {
      await File(logFilePath).writeAsString(
        text,
        mode: FileMode.append,
      );
    } catch (_) {
      // 日志失败不应影响应用运行。
    } finally {
      _scheduled = false;
      _scheduleFlush();
    }
  }
}
