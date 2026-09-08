import 'package:flutter/material.dart';

import '../theme/amber_theme.dart';
import 'sensor_module.dart';

/// AD8232 ECG module. Not wired into the firmware yet — this exists to
/// prove out the modular pattern: the moment the firmware starts sending
/// an "ecgMv"/"heartRateEcg" field, [isAvailable] flips to true and this
/// card starts rendering automatically, with zero changes anywhere else
/// in the app.
class EcgModule implements SensorModule {
  @override
  String get id => 'ecg';

  @override
  String get displayName => 'ECG (AD8232)';

  @override
  IconData get icon => Icons.monitor_heart_rounded;

  @override
  bool isAvailable(SensorData data) => data.containsKey('ecgMv');

  @override
  String summarize(SensorData data) => 'ECG: ${data['ecgMv']} mV.';

  @override
  Widget buildCard(BuildContext context, SensorData data) {
    // Currently unreachable (isAvailable always false until the sensor is
    // wired in), kept simple on purpose.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text('ECG: ${data['ecgMv']} mV'),
      ),
    );
  }
}

/// Placeholder card shown instead of a real ECG card while the sensor isn't
/// connected yet — makes the "this app is modular" story visible in the UI
/// rather than just silently omitting the module.
class EcgComingSoonCard extends StatelessWidget {
  const EcgComingSoonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.monitor_heart_rounded, color: AmberPalette.textDim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ECG (AD8232)', style: TextStyle(color: AmberPalette.textDim, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    'Sensor ainda não conectado — este card aparece sozinho assim que o AD8232 estiver no firmware.',
                    style: TextStyle(color: AmberPalette.textDim.withValues(alpha: 0.8), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
