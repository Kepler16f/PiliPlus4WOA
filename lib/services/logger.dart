import 'dart:io';

import 'package:PiliPlus/utils/json_file_handler.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:catcher_2/utils/log_printer.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final logger = Logger(
  filter: ProductionFilter(),
  printer: PrettyLogPrinter(
    dateTimeFormat: PrettyLogPrinter.toEncodableFallback,
  ),
  level: kDebugMode ? .trace : .warning,
);

abstract final class LoggerUtils {
  static File? _logFile;

  static Future<File> getLogsPath() async {
    if (_logFile != null) return _logFile!;

    // ARM64 修改版：崩溃日志同时写入系统临时目录（Windows），
    // 因为 Documents/PiliPlus 目录在某些环境下不可见/不存在，
    // 写入 Temp 便于用户快速取回日志定位崩溃。
    if (Platform.isWindows) {
      String dir = Directory.systemTemp.path;
      final String filename = p.join(dir, 'piliplus_crash_log.json');
      final File file = File(filename);
      if (!file.existsSync()) {
        await file.create(recursive: true);
      }
      return _logFile = file;
    }

    String dir = (await getApplicationDocumentsDirectory()).path;
    final String filename = p.join(dir, '.pili_logs.json');
    final File file = File(filename);
    if (!file.existsSync()) {
      await file.create(recursive: true);
    }
    return _logFile = file;
  }

  static Future<bool> clearLogs() async {
    try {
      if (Pref.enableLog) {
        await JsonFileHandler.add(
          (raf) => raf.setPosition(0).then((raf) => raf.truncate(0)),
        );
      } else {
        final file = await getLogsPath();
        await file.writeAsBytes(const [], flush: true);
      }
    } catch (e) {
      // if (kDebugMode) debugPrint('Error clearing file: $e');
      return false;
    }
    return true;
  }
}
