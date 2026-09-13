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
  DateTime? _aiCapturedAt;

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
    final hasData = modules.any((m) => m.isAvailable(ble.latestData));

    if (!hasData) {
      setState(() {
        _aiLoading = false;
        _aiError = 'No biomedical data available to analyze yet.';
      });
      return;
    }

    final data = ble.latestData;
    final sessionDuration = ble.sessionStartTime == null
        ? null
        : DateTime.now().difference(ble.sessionStartTime!).inSeconds;

    // Rich structured biotelemetry payload for the AMBER-01 Telemetry
    // Copilot — see AiService for the system prompt that consumes this.
    final payload = <String, dynamic>{
      'current_heart_rate_bpm': (data['fingerOk'] == true && (data['bpm'] as int? ?? 0) > 0)
          ? data['bpm']
          : ((data['leadsOff'] == false) ? data['bpmEcg'] : null),
      'spo2_percentage': (data['fingerOk'] == true) ? data['spo2'] : null,
      'ecg_signal_quality_sqi': data['sqi'],
      'ecg_leads_connected': data['leadsOff'] == false,
      'finger_on_sensor': data['fingerOk'] == true,
      'calculated_rr_intervals_ms': ble.recentRrIntervalsMs,
      'estimated_hrv_rmssd_ms': ble.estimatedHrvRmssdMs,
      'pulse_rhythm_regularity': ble.pulseRhythmRegularity,
      'session_duration_seconds': sessionDuration,
      'data_source': ble.status == ConnectionStatus.demo ? 'simulated_demo_mode' : 'live_sensor',
    };

    try {
      final result = await AiService.interpret(payload);
      setState(() {
        _aiInsight = result;
        _aiCapturedAt = DateTime.now();
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
    // Deliberately NOT context.watch<BleManager>() here: the AppBar/Scaffold
    // chrome must not rebuild on every telemetry tick. Reactive sections
    // (metrics, oscilloscopes) subscribe themselves further down via
    // ListenableBuilder / ValueListenableBuilder, scoped to just those
    // widgets.
    final ble = context.read<BleManager>();

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
        // Scoped listener: only this subtree rebuilds when BleManager
        // notifies (now throttled to ~1.3Hz for metrics). Oscilloscope
        // canvases inside re-subscribe independently at full sample rate
        // via ValueListenableBuilder(ble.waveformTick).
        child: ListenableBuilder(
          listenable: ble,
          builder: (context, _) => _crtViewMode ? _buildCrtView(ble) : _buildModularView(ble),
        ),
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
    final sqi = data['sqi'] as String? ?? 'LEAD_ARTIFACT';

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
          // Subscribes directly to the 50Hz waveformTick so the wave stays
          // silky-smooth without rebuilding the metrics/text above it.
          SizedBox(
            height: 180,
            child: ValueListenableBuilder<int>(
              valueListenable: ble.waveformTick,
              builder: (context, _, _) => CrtOscilloscope(
                title: 'CHANNEL 1 · PPG WAVE',
                statusText: 'SWEEP 25mm/s',
                samples: ble.ppgWaveHistory,
                alertActive: !fingerOk,
                alertMessage: 'PLACE FINGER ON SENSOR',
                isDemo: ble.status == ConnectionStatus.demo,
                waveColor: AmberPalette.amber,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Channel 2 Oscilloscope: ECG Waveform
          SizedBox(
            height: 190,
            child: ValueListenableBuilder<int>(
              valueListenable: ble.waveformTick,
              builder: (context, _, _) => CrtOscilloscope(
                title: 'CHANNEL 2 · ECG',
                statusText: leadsOff ? 'STANDBY' : (bpmEcgValid ? '$bpmEcg BPM' : 'SIGNAL OK'),
                samples: ble.ecgWaveHistory,
                alertActive: leadsOff,
                alertMessage: 'LEADS OFF',
                isDemo: ble.status == ConnectionStatus.demo,
                waveColor: const Color(0xFFFFBE26),
              ),
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
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 8,
                  spacing: 12,
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
                      label: 'SQI',
                      value: sqi.replaceAll('_', ' '),
                      color: switch (sqi) {
                        'CLEAN' => AmberPalette.green,
                        'MODERATE_NOISE' => AmberPalette.cream,
                        _ => AmberPalette.red,
                      },
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
                  'AMBER-01 · CLINICAL-STYLE BIOTELEMETRY UNIT · SN 30102-BE1',
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
          capturedAt: _aiCapturedAt,
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

/// AMBER-01 Telemetry Copilot report card. Renders the Gemini Markdown
/// report with amber-phosphor section badges instead of a raw text blob,
/// and stamps the capture time so the reading doesn't look stale.
class _AiInsightCard extends StatelessWidget {
  final bool loading;
  final String? insight;
  final String? error;
  final DateTime? capturedAt;
  final VoidCallback? onAsk;

  const _AiInsightCard({
    required this.loading,
    required this.insight,
    required this.error,
    required this.capturedAt,
    required this.onAsk,
  });

  String _fmtTime(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

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
                Text('AMBER-01 Telemetry Copilot', style: Theme.of(context).textTheme.titleMedium),
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
              if (capturedAt != null) ...[
                const SizedBox(height: 6),
                Text(
                  'CAPTURED ${_fmtTime(capturedAt!)}',
                  style: const TextStyle(color: AmberPalette.textDim, fontSize: 10, letterSpacing: 1.2),
                ),
              ],
              const SizedBox(height: 12),
              _CopilotReport(markdown: insight!),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: AmberPalette.red, fontSize: 13)),
            ],
            if (insight == null && error == null) ...[
              const SizedBox(height: 8),
              const Text(
                'Request a structured, educational cardiology-style telemetry report from the current ECG and SpO₂ readings.',
                style: TextStyle(color: AmberPalette.textDim, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lightweight Markdown renderer for the Copilot's report — just enough to
/// turn its numbered "N. 🫀 SECTION TITLE" headers into amber phosphor
/// badges, "**bold**" spans into bold text, and "- " lines into bullets,
/// without pulling in a full Markdown package for four heading styles.
class _CopilotReport extends StatelessWidget {
  final String markdown;
  const _CopilotReport({required this.markdown});

  static final _sectionHeader = RegExp(r'^\s*\d+\.\s*(.+)$');

  @override
  Widget build(BuildContext context) {
    final lines = markdown.split('\n');
    final widgets = <Widget>[];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final headerMatch = _sectionHeader.firstMatch(line);
      if (headerMatch != null) {
        widgets.add(Padding(
          padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 14, bottom: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AmberPalette.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AmberPalette.amber.withValues(alpha: 0.4)),
            ),
            child: Text(
              _stripBold(headerMatch.group(1)!).toUpperCase(),
              style: const TextStyle(
                color: AmberPalette.amberBright,
                fontWeight: FontWeight.w800,
                fontSize: 12,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ));
        continue;
      }

      final isBullet = line.startsWith('- ') || line.startsWith('* ');
      final content = isBullet ? line.substring(2) : line;

      widgets.add(Padding(
        padding: EdgeInsets.only(bottom: 6, left: isBullet ? 8 : 0),
        child: RichText(text: _parseBold(isBullet ? '•  $content' : content)),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
  }

  String _stripBold(String text) => text.replaceAll('**', '');

  /// Splits on `**bold**` markers and returns a TextSpan tree, so a single
  /// RichText can mix regular and bold runs without a Markdown package.
  TextSpan _parseBold(String text) {
    const baseStyle = TextStyle(color: AmberPalette.text, height: 1.45, fontSize: 13.5);
    final boldStyle = baseStyle.copyWith(fontWeight: FontWeight.w700, color: AmberPalette.cream);
    final parts = text.split('**');
    final spans = <TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(TextSpan(text: parts[i], style: i.isOdd ? boldStyle : baseStyle));
    }
    return TextSpan(children: spans.isEmpty ? [const TextSpan(text: '')] : spans);
  }
}
