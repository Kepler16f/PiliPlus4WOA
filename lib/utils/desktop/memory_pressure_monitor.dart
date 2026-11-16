import 'dart:async' show Timer;
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math' show min;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart'
    show
        ValueListenable,
        ValueNotifier,
        debugPrint,
        kDebugMode,
        visibleForTesting;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/services.dart' show rootBundle;
import 'package:win32/win32.dart'
    show
        EmptyWorkingSet,
        GetCurrentProcess,
        GlobalMemoryStatusEx,
        MEMORYSTATUSEX;

/// 系统内存压力等级，用于驱动桌面端缓存自适应收缩。
enum MemoryPressureLevel {
  normal,
  elevated,
  critical,
}

/// Windows 系统内存状态快照。
class MemoryStatusSnapshot {
  const MemoryStatusSnapshot({
    required this.memoryLoadPercent,
    required this.totalPhysBytes,
    required this.availPhysBytes,
    required this.totalPageFileBytes,
    required this.availPageFileBytes,
  });

  final int memoryLoadPercent;
  final int totalPhysBytes;
  final int availPhysBytes;
  final int totalPageFileBytes;
  final int availPageFileBytes;
}

/// 监听 Windows 整机物理/提交内存压力并自适应收缩本地缓存。
///
/// 原因（Windows ARM64 / UMA）：
/// 1) Flutter Windows 引擎默认不会自动向 Dart 派发低内存告警，
///    [PaintingBinding.instance.imageCache] 会长期按默认 100 MiB / 1000 张占用；
/// 2) 骁龙 WOA 平台 CPU 与 Adreno GPU 共享物理 LPDDR5x，当整机内存吃紧时，
///    Windows 会修剪进程工作集并将冷页换出到磁盘，前台 UI / 渲染线程一旦触发
///    硬缺页中断或遭遇内存压缩带宽争用，就会产生明显卡顿与掉帧。
///
/// 注意：前台活跃期间仅缩减无用缓存与限制缓冲上限（直接归还已提交内存），
/// **绝不**在前台播放时调用 `EmptyWorkingSet`，避免人为制造热页缺页中断。
class MemoryPressureMonitor {
  MemoryPressureMonitor._();
  static MemoryPressureMonitor get instance => _instance;
  static final MemoryPressureMonitor _instance = MemoryPressureMonitor._();

  static const int _kMiB = 1024 * 1024;
  static const int _kGiB = 1024 * _kMiB;
  static const Duration _kPollInterval = Duration(seconds: 5);

  final ValueNotifier<MemoryPressureLevel> _levelNotifier =
      ValueNotifier<MemoryPressureLevel>(MemoryPressureLevel.normal);

  MemoryPressureLevel get level => _levelNotifier.value;
  ValueListenable<MemoryPressureLevel> get listenable => _levelNotifier;

  Timer? _pollTimer;
  Pointer<MEMORYSTATUSEX>? _memStatusPtr;
  bool _initialized = false;
  int _totalPhysBytes = 0;

  /// 根据系统内存快照与当前状态计算压力等级（带迟滞区间防止临界点抖动）。
  @visibleForTesting
  static MemoryPressureLevel evaluatePressure(
    MemoryStatusSnapshot status, {
    MemoryPressureLevel current = MemoryPressureLevel.normal,
  }) {
    final hasPhys = status.totalPhysBytes > 0;
    final hasPageFile = status.totalPageFileBytes > 0;

    final criticalAvailFloor = hasPhys
        ? min(_kGiB, status.totalPhysBytes ~/ 8)
        : _kGiB;
    final elevatedAvailFloor = hasPhys
        ? min(2 * _kGiB, status.totalPhysBytes ~/ 4)
        : 2 * _kGiB;
    final criticalPageFileFloor = hasPageFile
        ? min(_kGiB, status.totalPageFileBytes ~/ 10)
        : 0;

    final isCritical =
        status.memoryLoadPercent >= 90 ||
        (hasPhys && status.availPhysBytes < criticalAvailFloor) ||
        (criticalPageFileFloor > 0 &&
            status.availPageFileBytes < criticalPageFileFloor);
    if (isCritical) {
      return MemoryPressureLevel.critical;
    }

    if (current == MemoryPressureLevel.critical) {
      const recoverySlack = 384 * _kMiB;
      final physRecovered =
          !hasPhys ||
          status.availPhysBytes >= criticalAvailFloor + recoverySlack;
      final pageRecovered =
          criticalPageFileFloor == 0 ||
          status.availPageFileBytes >= criticalPageFileFloor + recoverySlack;
      if (status.memoryLoadPercent > 85 || !physRecovered || !pageRecovered) {
        return MemoryPressureLevel.critical;
      }
    }

    final isElevated =
        status.memoryLoadPercent >= 80 ||
        (hasPhys && status.availPhysBytes < elevatedAvailFloor);
    if (isElevated) {
      return MemoryPressureLevel.elevated;
    }

    if (current == MemoryPressureLevel.elevated) {
      const recoverySlack = 384 * _kMiB;
      final physRecovered =
          !hasPhys ||
          status.availPhysBytes >= elevatedAvailFloor + recoverySlack;
      if (status.memoryLoadPercent > 74 || !physRecovered) {
        return MemoryPressureLevel.elevated;
      }
    }

    return MemoryPressureLevel.normal;
  }

  /// 按压力等级和物理内存总量返回 Flutter ImageCache 上限。
  @visibleForTesting
  static ({int maximumSize, int maximumSizeBytes}) imageCacheBudgetFor(
    MemoryPressureLevel level, {
    required int totalPhysBytes,
  }) {
    switch (level) {
      case MemoryPressureLevel.normal:
        if (totalPhysBytes > 0 && totalPhysBytes <= 8 * _kGiB) {
          return (maximumSize: 250, maximumSizeBytes: 40 * _kMiB);
        }
        if (totalPhysBytes > 0 && totalPhysBytes <= 16 * _kGiB) {
          return (maximumSize: 350, maximumSizeBytes: 56 * _kMiB);
        }
        return (maximumSize: 450, maximumSizeBytes: 72 * _kMiB);
      case MemoryPressureLevel.elevated:
        return (maximumSize: 120, maximumSizeBytes: 20 * _kMiB);
      case MemoryPressureLevel.critical:
        return (maximumSize: 48, maximumSizeBytes: 8 * _kMiB);
    }
  }

  /// 按当前内存压力封顶 mpv demuxer 前/后向缓冲区大小。
  static ({int maxBytes, int maxBackBytes}) capDemuxerBuffer({
    required int configuredMaxBytes,
    required int configuredMaxBackBytes,
    required MemoryPressureLevel pressure,
  }) {
    switch (pressure) {
      case MemoryPressureLevel.normal:
        return (
          maxBytes: configuredMaxBytes,
          maxBackBytes: configuredMaxBackBytes,
        );
      case MemoryPressureLevel.elevated:
        return (
          maxBytes: min(configuredMaxBytes, 4 * _kMiB),
          maxBackBytes: min(configuredMaxBackBytes, 2 * _kMiB),
        );
      case MemoryPressureLevel.critical:
        return (
          maxBytes: min(configuredMaxBytes, 2 * _kMiB),
          maxBackBytes: 0,
        );
    }
  }

  void init() {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;

    final ptr = calloc<MEMORYSTATUSEX>();
    ptr.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
    _memStatusPtr = ptr;

    final initial = _readWindowsMemoryStatus();
    if (initial != null) {
      _totalPhysBytes = initial.totalPhysBytes;
      final initialLevel = evaluatePressure(initial);
      _levelNotifier.value = initialLevel;
      _applyImageCachePolicy(initialLevel, purgeOffscreen: false);
    } else {
      _applyImageCachePolicy(MemoryPressureLevel.normal, purgeOffscreen: false);
    }

    _pollTimer = Timer.periodic(_kPollInterval, (_) => checkNow());
  }

  MemoryStatusSnapshot? _readWindowsMemoryStatus() {
    final ptr = _memStatusPtr;
    if (ptr == null) return null;
    try {
      final result = GlobalMemoryStatusEx(ptr);
      if (!result.value) return null;
      final status = ptr.ref;
      return MemoryStatusSnapshot(
        memoryLoadPercent: status.dwMemoryLoad,
        totalPhysBytes: status.ullTotalPhys,
        availPhysBytes: status.ullAvailPhys,
        totalPageFileBytes: status.ullTotalPageFile,
        availPageFileBytes: status.ullAvailPageFile,
      );
    } catch (_) {
      return null;
    }
  }

  /// 主动采样一次系统内存并按需触发缓存调整。
  void checkNow() {
    if (!Platform.isWindows || !_initialized) return;
    final snapshot = _readWindowsMemoryStatus();
    if (snapshot == null) return;
    _totalPhysBytes = snapshot.totalPhysBytes;

    final nextLevel = evaluatePressure(snapshot, current: _levelNotifier.value);
    if (nextLevel != _levelNotifier.value) {
      final escalating = nextLevel.index > _levelNotifier.value.index;
      if (kDebugMode) {
        debugPrint(
          'MemoryPressure: ${_levelNotifier.value.name} -> ${nextLevel.name} '
          '(load=${snapshot.memoryLoadPercent}%, '
          'availPhys=${snapshot.availPhysBytes ~/ _kMiB}MiB)',
        );
      }
      _applyImageCachePolicy(
        nextLevel,
        purgeOffscreen: escalating && nextLevel == MemoryPressureLevel.critical,
      );
      _levelNotifier.value = nextLevel;
    }
  }

  void _applyImageCachePolicy(
    MemoryPressureLevel level, {
    required bool purgeOffscreen,
  }) {
    final budget = imageCacheBudgetFor(level, totalPhysBytes: _totalPhysBytes);
    // 先缩容再 clear，避免瞬间重新解码膨胀。
    PaintingBinding.instance.imageCache
      ..maximumSize = budget.maximumSize
      ..maximumSizeBytes = budget.maximumSizeBytes;
    if (purgeOffscreen) {
      PaintingBinding.instance.imageCache.clear();
      rootBundle.clear();
    }
  }

  /// 仅在窗口最小化/隐藏到托盘且未播放视频时调用：
  /// 清理离屏图像缓存并将休眠页交还系统备用列表，降低整机内存占压。
  void trimBackgroundMemory() {
    if (!Platform.isWindows) return;
    PaintingBinding.instance.imageCache.clear();
    rootBundle.clear();
    try {
      EmptyWorkingSet(GetCurrentProcess());
    } catch (_) {}
  }

  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final ptr = _memStatusPtr;
    if (ptr != null) {
      calloc.free(ptr);
      _memStatusPtr = null;
    }
    _initialized = false;
  }
}
