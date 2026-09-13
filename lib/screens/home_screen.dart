import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../modules/sensor_module.dart';
import '../services/ai_service.dart';
import '../services/ble_manager.dart';
import '../theme/amber_theme.dart';
import '../widgets/crt_oscilloscope.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _aiInsight;
  bool _aiLoading = false;
  String? _aiError;

  // Toggle between CRT Bioscanner view and Modular Cards view
  bool _crtViewMode = true;

  // Real-time clock and uptime timer
  late Timer _clockTimer;
  late DateTime _bootTime;
  DateTime _currentTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _bootTime = DateTime.now();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _currentTime = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    super.dispose();
  }

  String _fmtClock(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _fmtUptime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _askAi(BleManager ble) async {
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });

    final modules = <SensorModule>[ble.pulseOx, ble.ecgModule];
    final available = modules.where((m) => m.isAvailable(ble.latestData));
    final summary = available.map((m) => m.summarize(ble.latestData)).join(' ');

    if (summary.isEmpty) {
      setState(() {
        _aiLoading = false;
        _aiError = 'No biomedical data available to analyze yet.';
      });
      return;
    }

    try {
      final result = await AiService.interpret(summary);
      setState(() {
        _aiInsight = result;
        _aiLoading = false;
      });
    } catch (e) {
      setState(() {
        _aiError = e.toString().replaceFirst('Exception: ', '');
        _aiLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();

    return Scaffold(
      backgroundColor: const Color(0xFF040200),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080501),
        title: Row(
          children: [
            Text(
              'AMBER-01',
              style: GoogleFonts.jetBrainsMono(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: AmberPalette.amber,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'BIOSCANNER',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 13,
                letterSpacing: 1.2,
                color: AmberPalette.textDim,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _crtViewMode ? Icons.view_agenda_outlined : Icons.monitor_heart_outlined,
              color: AmberPalette.amber,
            ),
            tooltip: _crtViewMode ? 'Modular Cards View' : 'CRT Bioscanner View',
            onPressed: () => setState(() => _crtViewMode = !_crtViewMode),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AmberPalette.textDim),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _crtViewMode ? _buildCrtView(ble) : _buildModularView(ble),
      ),
    );
  }

  // =========================================================================
  // 1. CRT BIOSCANNER VIEW (Faithfully ported from the retro PC monitor)
  // =========================================================================
  Widget _buildCrtView(BleManager ble) {
    final data = ble.latestData;
    final fingerOk = data['fingerOk'] == true;
    final bpmPpg = data['bpm'] as int? ?? 0;
    final spo2 = data['spo2'] as int? ?? 0;
    final leadsOff = data['leadsOff'] as bool? ?? true;
    final bpmEcg = data['bpmEcg'] as int? ?? 0;
    final ir = data['ir'] as int? ?? 0;

    // Main card fallback logic: PPG takes priority; falls back to ECG if finger is off
    final bpmPpgValid = fingerOk && bpmPpg > 0;
    final bpmEcgValid = !leadsOff && bpmEcg > 0;

    String displayBpm = '--';
    String bpmLabel = 'BPM';
    if (bpmPpgValid) {
      displayBpm = bpmPpg.toString();
      bpmLabel = 'BPM';
    } else if (bpmEcgValid) {
      displayBpm = bpmEcg.toString();
      bpmLabel = 'BPM (ECG)';
    } else if (fingerOk) {
      displayBpm = 'CAL';
    }

    final uptime = _currentTime.difference(_bootTime);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top bar: Live Clock + Uptime + Action Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_fmtClock(_currentTime)} · UP ${_fmtUptime(uptime)}',
                style: GoogleFonts.jetBrainsMono(
                  color: AmberPalette.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              Row(
                children: [
                  // Audio Tone Button
                  InkWell(
                    onTap: () => ble.toggleAudioTone(),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: ble.audioToneEnabled ? AmberPalette.amber : const Color(0xFF4A3000),
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        ble.audioToneEnabled ? 'TONE: ON' : 'TONE: OFF',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: ble.audioToneEnabled ? AmberPalette.amber : AmberPalette.textDim,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Simulation / Demo Mode Button
                  InkWell(
                    onTap: () {
                      if (ble.status == ConnectionStatus.demo) {
                        ble.stopDemo();
                      } else {
                        ble.startDemoMode();
                      }
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: ble.status == ConnectionStatus.demo ? AmberPalette.green : const Color(0xFF4A3000),
                        ),
                        borderRadius: BorderRadius.circular(4),
                        color: ble.status == ConnectionStatus.demo ? AmberPalette.green.withValues(alpha: 0.15) : Colors.transparent,
                      ),
                      child: Text(
                        'DEMO',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: ble.status == ConnectionStatus.demo ? AmberPalette.green : AmberPalette.textDim,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Primary Metrics Panel (Hero Heart Rate + SpO2)
          Row(
            children: [
              // Hero Heart Rate Card
              Expanded(
                flex: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E0802),
                    border: Border.all(color: const Color(0xFF2E1C00), width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'HEART RATE',
                            style: TextStyle(
                              color: Color(0xFF7A4A00),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          AnimatedScale(
                            scale: ble.heartPulseActive ? 1.4 : 1.0,
                            duration: const Duration(milliseconds: 120),
                            child: Icon(
                              Icons.favorite,
                              size: 16,
                              color: ble.heartPulseActive ? AmberPalette.red : const Color(0xFF7A4A00),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          displayBpm,
                          style: GoogleFonts.vt323(
                            fontSize: 64,
                            height: 0.95,
                            color: AmberPalette.amber,
                            shadows: [
                              Shadow(color: AmberPalette.amber.withValues(alpha: 0.6), blurRadius: 18),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          bpmLabel,
                          style: const TextStyle(color: Color(0xFF7A4A00), fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // SpO2 Card
              Expanded(
                flex: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0E0802),
                    border: Border.all(color: const Color(0xFF2E1C00), width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'OXYGEN SAT.',
                            style: TextStyle(
                              color: Color(0xFF7A4A00),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          Text(
                            'SpO₂',
                            style: TextStyle(color: Color(0xFF7A4A00), fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          (fingerOk && spo2 > 0) ? spo2.toString() : (fingerOk ? 'CAL' : '--'),
                          style: GoogleFonts.vt323(
                            fontSize: 48,
                            height: 0.95,
                            color: AmberPalette.amber,
                            shadows: [
                              Shadow(color: AmberPalette.amber.withValues(alpha: 0.5), blurRadius: 14),
                            ],
                          ),
                        ),
                      ),
                      const Align(
                        alignment: Alignment.centerRight,
                        child: Text('%', style: TextStyle(color: Color(0xFF7A4A00), fontSize: 11)),
                      ),
                      const SizedBox(height: 6),
                      // Phosphor green progress fill bar
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: const Color(0xFF060400),
                          border: Border.all(color: const Color(0xFF2E1C00)),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (fingerOk && spo2 > 0) ? (spo2 / 100.0).clamp(0.0, 1.0) : 0.0,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AmberPalette.green,
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(color: AmberPalette.green.withValues(alpha: 0.7), blurRadius: 6),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Channel 1 Oscilloscope: PPG Waveform
          SizedBox(
            height: 180,
            child: CrtOscilloscope(
              title: 'CHANNEL 1 · PPG WAVE',
              statusText: 'SWEEP 25mm/s',
              samples: ble.ppgWaveHistory,
              alertActive: !fingerOk,
              alertMessage: 'PLACE FINGER ON SENSOR',
              isDemo: ble.status == ConnectionStatus.demo,
              waveColor: AmberPalette.amber,
            ),
          ),
          const SizedBox(height: 12),

          // Channel 2 Oscilloscope: ECG Waveform
          SizedBox(
            height: 190,
            child: CrtOscilloscope(
              title: 'CHANNEL 2 · ECG',
              statusText: leadsOff ? 'STANDBY' : (bpmEcgValid ? '$bpmEcg BPM' : 'SIGNAL OK'),
              samples: ble.ecgWaveHistory,
              alertActive: leadsOff,
              alertMessage: 'LEADS OFF',
              isDemo: ble.status == ConnectionStatus.demo,
              waveColor: const Color(0xFFFFBE26),
            ),
          ),
          const SizedBox(height: 12),

          // Telemetry & CRT Terminal Panel
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0601),
              border: Border.all(color: const Color(0xFF2E1C00), width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                // Status Indicators
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _StatusIndicator(
                      label: 'LINK',
                      value: ble.status == ConnectionStatus.connected
                          ? 'ESP32'
                          : (ble.status == ConnectionStatus.demo ? 'SIMULATED' : 'SEARCHING'),
                      color: ble.status == ConnectionStatus.connected
                          ? AmberPalette.green
                          : (ble.status == ConnectionStatus.demo ? AmberPalette.cream : AmberPalette.textDim),
                    ),
                    _StatusIndicator(
                      label: 'SENSOR',
                      value: fingerOk ? 'FINGER OK' : 'IDLE',
                      color: fingerOk ? AmberPalette.green : AmberPalette.textDim,
                    ),
                    _StatusIndicator(
                      label: 'ECG',
                      value: leadsOff ? 'LOOSE' : 'OK',
                      color: leadsOff ? AmberPalette.red : AmberPalette.green,
                    ),
                    _StatusIndicator(
                      label: 'IR',
                      value: ir.toString(),
                      color: AmberPalette.amber,
                    ),
                  ],
                ),
                const Divider(color: Color(0xFF2E1C00), height: 18),

                // Terminal Log Feed
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF040200),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x337A4A00)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final log in ble.terminalLogs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            log,
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10.5,
                              color: log.contains('ERROR')
                                  ? AmberPalette.red
                                  : (log.contains('CONNECTED') ? AmberPalette.green : AmberPalette.amber),
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Quick Action Connect / Disconnect Buttons
          if (ble.status != ConnectionStatus.connected && ble.status != ConnectionStatus.demo)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => ble.startDemoMode(),
                    child: const Text('Simulation Mode'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => ble.connect(),
                    child: const Text('Connect ESP32'),
                  ),
                ),
              ],
            )
          else
            OutlinedButton(
              onPressed: () => ble.disconnect(),
              child: const Text('Disconnect'),
            ),

          const SizedBox(height: 16),

          // Prominent Nameplate Footer with Author Attribution to João V.P.
          Center(
            child: Column(
              children: [
                Text(
                  'AMBER-01 · BIOTELEMETRY UNIT · SN 30102-BE1',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10.0,
                    color: const Color(0xFF5E3C00),
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'ENGINEERED & DEVELOPED BY JOÃO V.P.',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: AmberPalette.amber.withValues(alpha: 0.75),
                    letterSpacing: 1.6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  // =========================================================================
  // 2. MODULAR CARDS VIEW (Individual Sensor Cards + Gemini AI Insights)
  // =========================================================================
  Widget _buildModularView(BleManager ble) {
    final modules = <SensorModule>[ble.pulseOx, ble.ecgModule];
    final availableModules = modules.where((m) => m.isAvailable(ble.latestData)).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ConnectionBar(ble: ble),
        const SizedBox(height: 16),

        for (final module in availableModules) ...[
          module.buildCard(context, ble.latestData),
          const SizedBox(height: 14),
        ],

        if (availableModules.isEmpty &&
            ble.status != ConnectionStatus.connected &&
            ble.status != ConnectionStatus.demo)
          _EmptyState(ble: ble),

        const SizedBox(height: 8),
        _AiInsightCard(
          loading: _aiLoading,
          insight: _aiInsight,
          error: _aiError,
          onAsk: availableModules.isEmpty ? null : () => _askAi(ble),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helper Widgets
// ---------------------------------------------------------------------------
class _StatusIndicator extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatusIndicator({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
            ],
          ),
        ),
        const SizedBox(width: 5),
        Text(
          '$label: ',
          style: const TextStyle(color: Color(0xFF7A4A00), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  final BleManager ble;
  const _ConnectionBar({required this.ble});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (ble.status) {
      ConnectionStatus.connected => ('Connected', AmberPalette.green),
      ConnectionStatus.demo => ('Demo Mode (Simulated)', AmberPalette.cream),
      ConnectionStatus.connecting => ('Connecting...', AmberPalette.amber),
      ConnectionStatus.scanning => ('Scanning for device...', AmberPalette.amber),
      ConnectionStatus.disconnected => ('Disconnected', AmberPalette.textDim),
    };

    final busy = ble.status == ConnectionStatus.connecting || ble.status == ConnectionStatus.scanning;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (!busy) ...[
              const SizedBox(height: 12),
              if (ble.status == ConnectionStatus.connected || ble.status == ConnectionStatus.demo)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(onPressed: () => ble.disconnect(), child: const Text('Disconnect')),
                )
              else
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(onPressed: () => ble.startDemoMode(), child: const Text('Demo Mode')),
                    FilledButton(onPressed: () => ble.connect(), child: const Text('Connect ESP32')),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final BleManager ble;
  const _EmptyState({required this.ble});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          const Icon(Icons.sensors_off_rounded, size: 40, color: AmberPalette.textDim),
          const SizedBox(height: 12),
          Text(
            ble.errorMessage ?? 'Connect ESP32-BioMonitor via Bluetooth or activate Demo Mode to explore the live vitals monitor.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AmberPalette.textDim),
          ),
        ],
      ),
    );
  }
}

class _AiInsightCard extends StatelessWidget {
  final bool loading;
  final String? insight;
  final String? error;
  final VoidCallback? onAsk;

  const _AiInsightCard({required this.loading, required this.insight, required this.error, required this.onAsk});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, color: AmberPalette.amber, size: 20),
                const SizedBox(width: 8),
                Text('AI Health Insight', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (!loading)
                  TextButton(
                    onPressed: onAsk,
                    child: const Text('Analyze'),
                  )
                else
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (insight != null) ...[
              const SizedBox(height: 12),
              Text(insight!, style: const TextStyle(color: AmberPalette.text, height: 1.4)),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: AmberPalette.red, fontSize: 13)),
            ],
            if (insight == null && error == null) ...[
              const SizedBox(height: 8),
              const Text(
                'Request a plain-language educational summary about the current ECG and SpO₂ telemetry readings.',
                style: TextStyle(color: AmberPalette.textDim, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
