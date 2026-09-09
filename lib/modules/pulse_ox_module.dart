import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme/amber_theme.dart';
import 'sensor_module.dart';

/// MAX30102 pulse-oximeter module: heart rate (BPM) + blood-oxygen (SpO2),
/// fed by the ESP32 firmware's "IR,BPM,SPO2,FINGER_OK" BLE notification.
class PulseOxModule implements SensorModule {
  /// Rolling window of recent IR samples, kept here so the card can draw a
  /// live waveform. Fed externally by [pushSample] as new BLE data arrives.
  final List<double> _irHistory = [];
  static const _historyLength = 100;

  void pushSample(double ir) {
    _irHistory.add(ir);
    if (_irHistory.length > _historyLength) {
      _irHistory.removeAt(0);
    }
  }

  @override
  String get id => 'pulse_ox';

  @override
  String get displayName => 'Oxímetro de Pulso';

  @override
  IconData get icon => Icons.favorite_rounded;

  @override
  bool isAvailable(SensorData data) => data.containsKey('bpm');

  @override
  String summarize(SensorData data) {
    final fingerOk = data['fingerOk'] == true;
    if (!fingerOk) return 'Oxímetro: sem dedo no sensor.';
    return 'Oxímetro: ${data['bpm']} bpm, SpO2 ${data['spo2']}%.';
  }

  @override
  Widget buildCard(BuildContext context, SensorData data) {
    final fingerOk = data['fingerOk'] == true;
    final bpm = data['bpm'] as int?;
    final spo2 = data['spo2'] as int?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.favorite_rounded, color: AmberPalette.amber),
                const SizedBox(width: 10),
                Text(displayName, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                _StatusPill(fingerOk: fingerOk),
              ],
            ),
            const SizedBox(height: 20),
            if (!fingerOk)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Coloque o dedo no sensor',
                    style: TextStyle(color: AmberPalette.textDim, fontSize: 16),
                  ),
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Readout(label: 'BPM', value: bpm?.toString() ?? '--', color: AmberPalette.amber),
                  _Readout(label: 'SpO2 %', value: spo2?.toString() ?? '--', color: AmberPalette.green),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(height: 60, child: _Waveform(samples: _irHistory)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _Readout({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AmberTheme.readoutStyle(color: color)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: AmberPalette.textDim, fontSize: 12, letterSpacing: 1)),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool fingerOk;
  const _StatusPill({required this.fingerOk});

  @override
  Widget build(BuildContext context) {
    final color = fingerOk ? AmberPalette.green : AmberPalette.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        fingerOk ? 'lendo' : 'aguardando',
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  final List<double> samples;
  const _Waveform({required this.samples});

  @override
  Widget build(BuildContext context) {
    if (samples.length < 2) {
      return const SizedBox.shrink();
    }
    final minV = samples.reduce((a, b) => a < b ? a : b);
    final maxV = samples.reduce((a, b) => a > b ? a : b);
    final spread = (maxV - minV).abs() < 1 ? 1.0 : (maxV - minV);

    return LineChart(
      LineChartData(
        minY: minV - spread * 0.1,
        maxY: maxV + spread * 0.1,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        // Without this, the curve's cubic smoothing overshoots past the
        // first/last points and bleeds outside the chart's own box (visible
        // as the amber fill spilling past the card's rounded edge).
        clipData: const FlClipData.all(),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < samples.length; i++) FlSpot(i.toDouble(), samples[i]),
            ],
            isCurved: true,
            color: AmberPalette.amber,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: AmberPalette.amber.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}
