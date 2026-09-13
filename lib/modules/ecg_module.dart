import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme/amber_theme.dart';
import 'sensor_module.dart';

/// ECG (AD8232) module integrated with real-time DSP filtering and Pan-Tompkins R-peak detector.
/// Engineered by João V.P.
class EcgModule implements SensorModule {
  final List<double> _ecgHistory = [];
  static const _historyLength = 120;

  void pushSample(double ecg) {
    _ecgHistory.add(ecg);
    if (_ecgHistory.length > _historyLength) {
      _ecgHistory.removeAt(0);
    }
  }

  @override
  String get id => 'ecg';

  @override
  String get displayName => 'Electrocardiogram (ECG)';

  @override
  IconData get icon => Icons.monitor_heart_rounded;

  @override
  bool isAvailable(SensorData data) => data.containsKey('ecg') && data['ecg'] != null;

  @override
  String summarize(SensorData data) {
    final leadsOff = data['leadsOff'] == true;
    if (leadsOff) {
      return 'ECG: leads loose or disconnected from patient.';
    }
    final bpmEcg = data['bpmEcg'] as int? ?? 0;
    return 'ECG: heart rate of $bpmEcg BPM via R-peak (QRS) detection, skin electrodes secure and signal filtered.';
  }

  @override
  Widget buildCard(BuildContext context, SensorData data) {
    final leadsOff = data['leadsOff'] == true;
    final bpmEcg = data['bpmEcg'] as int? ?? 0;
    final ecgRaw = data['ecg'] as int? ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart_rounded, color: AmberPalette.amber),
                const SizedBox(width: 10),
                Text(displayName, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                _EcgStatusPill(leadsOff: leadsOff, bpmEcg: bpmEcg),
              ],
            ),
            const SizedBox(height: 20),
            if (leadsOff)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: AmberPalette.red, size: 28),
                      const SizedBox(height: 8),
                      Text(
                        'Leads loose or disconnected',
                        style: TextStyle(color: AmberPalette.red.withValues(alpha: 0.9), fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Check LO+ and LO- leads and skin electrodes.',
                        style: TextStyle(color: AmberPalette.textDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _EcgReadout(
                    label: 'BPM (ECG)',
                    value: bpmEcg > 0 ? bpmEcg.toString() : '--',
                    color: AmberPalette.amber,
                  ),
                  _EcgReadout(
                    label: 'ADC SIGNAL',
                    value: ecgRaw.toString(),
                    color: AmberPalette.cream,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 70,
                child: _EcgWaveform(samples: _ecgHistory),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EcgReadout extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _EcgReadout({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AmberTheme.readoutStyle(color: color, size: 36)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: AmberPalette.textDim, fontSize: 11, letterSpacing: 1)),
      ],
    );
  }
}

class _EcgStatusPill extends StatelessWidget {
  final bool leadsOff;
  final int bpmEcg;

  const _EcgStatusPill({required this.leadsOff, required this.bpmEcg});

  @override
  Widget build(BuildContext context) {
    final color = leadsOff ? AmberPalette.red : AmberPalette.green;
    final text = leadsOff ? 'leads off' : (bpmEcg > 0 ? '$bpmEcg BPM' : 'signal ok');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EcgWaveform extends StatelessWidget {
  final List<double> samples;
  const _EcgWaveform({required this.samples});

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
        clipData: const FlClipData.all(),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < samples.length; i++) FlSpot(i.toDouble(), samples[i]),
            ],
            isCurved: false,
            color: AmberPalette.amberBright,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: AmberPalette.amber.withValues(alpha: 0.10),
            ),
          ),
        ],
      ),
    );
  }
}
