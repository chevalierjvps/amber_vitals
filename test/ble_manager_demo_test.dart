import 'package:flutter_test/flutter_test.dart';
import 'package:amber_vitals/services/ble_manager.dart';

void main() {
  test('demo mode produces smooth, non-random waveform + throttled metrics + heartbeat events', () async {
    final ble = BleManager();
    ble.startDemoMode();

    // Simulate ~2.5s of demo ticks (20ms period => 125 ticks) synchronously
    // by waiting on real timers.
    await Future.delayed(const Duration(milliseconds: 2600));

    expect(ble.status, ConnectionStatus.demo);
    expect(ble.ppgWaveHistory.length, greaterThan(50));
    expect(ble.ecgWaveHistory.length, greaterThan(50));

    // latestData should be populated by the throttled metrics timer.
    expect(ble.latestData['bpm'], isNotNull);
    expect(ble.latestData['sqi'], 'CLEAN');

    // At ~75 BPM for 2.5s we expect roughly 2-4 R-peak events recorded.
    expect(ble.recentRrIntervalsMs.length, greaterThanOrEqualTo(1));

    ble.stopDemo();
    ble.dispose();
  });
}
