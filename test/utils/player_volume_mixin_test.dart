import 'package:PiliPlus/utils/player_volume_gain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('playerVolumeBoostAf', () {
    test('returns null at or below 100%', () {
      expect(playerVolumeBoostAf(1.0), isNull);
      expect(playerVolumeBoostAf(0.5), isNull);
    });

    test('matches mpv cubic volume gain at 150%', () {
      // mpv: gain = (150/100)^3 = 3.375 -> 10.57dB -> 取整到 10.5dB -> 3.350
      expect(
        playerVolumeBoostAf(1.5),
        'alimiter=level_in=3.350:limit=1:level=0',
      );
    });

    test('matches mpv cubic volume gain at 200%', () {
      // mpv: gain = 2^3 = 8 -> 18.06dB -> 取整到 18dB -> 7.943
      expect(
        playerVolumeBoostAf(2.0),
        'alimiter=level_in=7.943:limit=1:level=0',
      );
    });

    test('matches mpv cubic volume gain at 300%', () {
      // mpv: gain = 3^3 = 27 -> 28.63dB -> 取整到 28.5dB -> 26.303
      expect(
        playerVolumeBoostAf(3.0),
        'alimiter=level_in=26.607:limit=1:level=0',
      );
    });
  });
}
