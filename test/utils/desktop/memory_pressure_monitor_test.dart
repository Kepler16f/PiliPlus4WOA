import 'package:PiliPlus/utils/desktop/memory_pressure_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mib = 1024 * 1024;
  const gib = 1024 * mib;

  group('MemoryPressureMonitor.evaluatePressure', () {
    test('returns normal when load and available physical memory are healthy', () {
      const status = MemoryStatusSnapshot(
        memoryLoadPercent: 60,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 6400 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 12 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(status),
        MemoryPressureLevel.normal,
      );
    });

    test('escalates to elevated at 80% load or low physical memory', () {
      const highLoad = MemoryStatusSnapshot(
        memoryLoadPercent: 80,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 3200 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 8 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(highLoad),
        MemoryPressureLevel.elevated,
      );

      const lowAvail = MemoryStatusSnapshot(
        memoryLoadPercent: 72,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 1900 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 6 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(lowAvail),
        MemoryPressureLevel.elevated,
      );
    });

    test('uses hysteresis before stepping down from elevated to normal', () {
      const borderline = MemoryStatusSnapshot(
        memoryLoadPercent: 76,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 3800 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 10 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(
          borderline,
          current: MemoryPressureLevel.elevated,
        ),
        MemoryPressureLevel.elevated,
      );

      const recovered = MemoryStatusSnapshot(
        memoryLoadPercent: 74,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 4200 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 10 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(
          recovered,
          current: MemoryPressureLevel.elevated,
        ),
        MemoryPressureLevel.normal,
      );
    });

    test('escalates to critical on high load, low phys, or low commit', () {
      const highLoad = MemoryStatusSnapshot(
        memoryLoadPercent: 90,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 1600 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 6 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(highLoad),
        MemoryPressureLevel.critical,
      );

      const lowCommit = MemoryStatusSnapshot(
        memoryLoadPercent: 75,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 4 * gib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 512 * mib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(lowCommit),
        MemoryPressureLevel.critical,
      );
    });

    test('steps down from critical smoothly with hysteresis', () {
      const stillTight = MemoryStatusSnapshot(
        memoryLoadPercent: 87,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 2 * gib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 4 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(
          stillTight,
          current: MemoryPressureLevel.critical,
        ),
        MemoryPressureLevel.critical,
      );

      const moderatelyFreed = MemoryStatusSnapshot(
        memoryLoadPercent: 82,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 2800 * mib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 4 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(
          moderatelyFreed,
          current: MemoryPressureLevel.critical,
        ),
        MemoryPressureLevel.elevated,
      );

      const fullyFreed = MemoryStatusSnapshot(
        memoryLoadPercent: 65,
        totalPhysBytes: 16 * gib,
        availPhysBytes: 5 * gib,
        totalPageFileBytes: 24 * gib,
        availPageFileBytes: 10 * gib,
      );
      expect(
        MemoryPressureMonitor.evaluatePressure(
          fullyFreed,
          current: MemoryPressureLevel.critical,
        ),
        MemoryPressureLevel.normal,
      );
    });
  });

  group('MemoryPressureMonitor.imageCacheBudgetFor', () {
    test('scales normal budget with physical RAM and shrinks on pressure', () {
      expect(
        MemoryPressureMonitor.imageCacheBudgetFor(
          MemoryPressureLevel.normal,
          totalPhysBytes: 8 * gib,
        ),
        (maximumSize: 250, maximumSizeBytes: 40 * mib),
      );
      expect(
        MemoryPressureMonitor.imageCacheBudgetFor(
          MemoryPressureLevel.normal,
          totalPhysBytes: 16 * gib,
        ),
        (maximumSize: 350, maximumSizeBytes: 56 * mib),
      );
      expect(
        MemoryPressureMonitor.imageCacheBudgetFor(
          MemoryPressureLevel.normal,
          totalPhysBytes: 32 * gib,
        ),
        (maximumSize: 450, maximumSizeBytes: 72 * mib),
      );
      expect(
        MemoryPressureMonitor.imageCacheBudgetFor(
          MemoryPressureLevel.elevated,
          totalPhysBytes: 32 * gib,
        ),
        (maximumSize: 120, maximumSizeBytes: 20 * mib),
      );
      expect(
        MemoryPressureMonitor.imageCacheBudgetFor(
          MemoryPressureLevel.critical,
          totalPhysBytes: 32 * gib,
        ),
        (maximumSize: 48, maximumSizeBytes: 8 * mib),
      );
    });
  });

  group('MemoryPressureMonitor.capDemuxerBuffer', () {
    test('preserves configured buffer on normal pressure', () {
      expect(
        MemoryPressureMonitor.capDemuxerBuffer(
          configuredMaxBytes: 32 * mib,
          configuredMaxBackBytes: 32 * mib,
          pressure: MemoryPressureLevel.normal,
        ),
        (maxBytes: 32 * mib, maxBackBytes: 32 * mib),
      );
    });

    test('caps large buffer and preserves smaller/live zero back-buffer', () {
      expect(
        MemoryPressureMonitor.capDemuxerBuffer(
          configuredMaxBytes: 32 * mib,
          configuredMaxBackBytes: 32 * mib,
          pressure: MemoryPressureLevel.elevated,
        ),
        (maxBytes: 4 * mib, maxBackBytes: 2 * mib),
      );
      expect(
        MemoryPressureMonitor.capDemuxerBuffer(
          configuredMaxBytes: 2 * mib,
          configuredMaxBackBytes: 0,
          pressure: MemoryPressureLevel.elevated,
        ),
        (maxBytes: 2 * mib, maxBackBytes: 0),
      );
      expect(
        MemoryPressureMonitor.capDemuxerBuffer(
          configuredMaxBytes: 32 * mib,
          configuredMaxBackBytes: 32 * mib,
          pressure: MemoryPressureLevel.critical,
        ),
        (maxBytes: 2 * mib, maxBackBytes: 0),
      );
    });
  });
}
