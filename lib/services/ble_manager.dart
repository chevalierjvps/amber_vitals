import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../modules/ecg_module.dart';
import '../modules/pulse_ox_module.dart';
import '../modules/sensor_module.dart';

enum ConnectionStatus { disconnected, scanning, connecting, connected, demo }

/// Human-readable Signal Quality Index bucket streamed by the firmware
/// (0=CLEAN, 1=MODERATE_NOISE, 2=LEAD_ARTIFACT). See esp32_amber_monitor.ino.
enum SignalQuality { clean, moderateNoise, leadArtifact }

/// BleManager - Bluetooth Low Energy communication and telemetry processing engine.
/// Engineered by João V.P.
/// Features:
///   - Standard Nordic UART Service (NUS) (6e400001...)
///   - Legacy BioMonitor Service (4fafc201...)
///   - 8-field biomedical telemetry: IR, BPM, SPO2, FINGER_OK, ECG, LEADS_OFF, BPM_ECG, SQI
///   - Real-time rolling oscilloscope buffers (PPG and ECG) with baseline tracking,
///     pushed to their own 50Hz notifier so waveform repaints never trigger a
///     full widget-tree rebuild
///   - Numeric UI metrics (BPM, SpO2, IR) throttled + smoothed to ~1.3Hz to
///     eliminate on-screen text vibration
///   - Genuine cardiac-cycle (R-peak) event detection driving the heartbeat
///     pulse animation, with a 450ms refractory lock
///   - High-fidelity synthetic multi-Gaussian ECG demo mode (P-QRS-T)
///   - Amber CRT terminal event logging
class BleManager extends ChangeNotifier {
  // Nordic UART Service (NUS) UUIDs
  static final _nusServiceUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final _nusCharTxUuid  = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'); // Notify
  static final _nusCharRxUuid  = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'); // Write

  // Legacy BioMonitor Service UUIDs
  static final _legacyServiceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final _legacyCharUuid    = Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

  static const _deviceName = 'ESP32-BioMonitor';
  static const int maxPoints = 300;

  // UI metrics are recomputed/notified at this cadence, independent of the
  // 50Hz sample ingestion rate, so BPM/SpO2/IR readouts stop vibrating.
  static const _metricsInterval = Duration(milliseconds: 750);

  ConnectionStatus status = ConnectionStatus.disconnected;
  String? errorMessage;

  /// Throttled (~1.3Hz), lightly-smoothed snapshot for text/status widgets.
  /// Do NOT read this from a 50Hz painter — use [ppgWaveHistory] /
  /// [ecgWaveHistory] + [waveformTick] instead.
  SensorData latestData = {};

  DateTime? sessionStartTime;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _demoTimer;
  Timer? _metricsTimer;
  final Random _rng = Random();

  // Sensor modules
  final PulseOxModule pulseOx = PulseOxModule();
  final EcgModule ecgModule = EcgModule();

  // Oscilloscope buffers (PPG & ECG) - mutated in place at 50Hz.
  final List<double> ppgWaveHistory = [];
  final List<double> ecgWaveHistory = [];
  double _dcBaseline = 0;
  double _ecgBaseline = 0;

  /// Bumped on every incoming sample (~50Hz). Oscilloscope widgets should
  /// listen to this directly (ValueListenableBuilder) instead of the whole
  /// [BleManager], so a repaint never dirties the rest of the UI tree.
  final ValueNotifier<int> waveformTick = ValueNotifier<int>(0);

  // Raw (unsmoothed, 50Hz-fresh) telemetry, folded into `latestData` only
  // by the throttled metrics timer below.
  int _rawIr = 0;
  int _rawBpm = 0;
  int _rawSpo2 = 0;
  bool _rawFingerOk = false;
  int _rawEcg = 0;
  bool _rawLeadsOff = true;
  int _rawBpmEcg = 0;
  SignalQuality _rawSqi = SignalQuality.leadArtifact;

  // Exponential-moving-average smoothing state for the throttled readouts.
  double? _smoothBpm;
  double? _smoothSpo2;
  double? _smoothIr;

  // CRT Terminal event log
  final List<String> terminalLogs = ['>>> SYSTEM INITIALIZED.'];

  // Heartbeat / genuine R-peak detection for the systolic pulse animation.
  bool heartPulseActive = false;
  Timer? _pulseResetTimer;
  DateTime? _lastPeakTime;
  double _peakEnvelope = 60.0; // adaptive amplitude envelope for threshold scaling
  bool _peakArmed = true;
  double _demoPhasePrev = 0.0;

  // Rolling R-peak timestamps for RR-interval / HRV (RMSSD) estimation, fed
  // to the AI Cardiology Copilot.
  final List<DateTime> _rPeakTimestamps = [];
  static const _maxRPeaks = 24;

  // Audio tone control
  bool audioToneEnabled = false;

  void toggleAudioTone() {
    audioToneEnabled = !audioToneEnabled;
    notifyListeners();
  }

  void logTerm(String msg) {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    terminalLogs.add('[$h:$m:$s] $msg');
    if (terminalLogs.length > 5) {
      terminalLogs.removeAt(0);
    }
    notifyListeners();
  }

  Future<void> connect() async {
    stopDemo();
    errorMessage = null;
    status = ConnectionStatus.scanning;
    logTerm('SCANNING FOR ESP32 DEVICE...');
    notifyListeners();

    try {
      if (await FlutterBluePlus.isSupported == false) {
        throw Exception('Bluetooth is not supported on this device.');
      }

      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
        final requiredDenied = [Permission.bluetoothScan, Permission.bluetoothConnect]
            .map((p) => statuses[p])
            .where((s) => s != null && (s.isDenied || s.isPermanentlyDenied));
        if (requiredDenied.isNotEmpty) {
          throw Exception('Bluetooth permission denied. Enable "Nearby devices" in app settings.');
        }
      }

      final completer = Completer<BluetoothDevice?>();
      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          final addr = r.device.remoteId.str.toUpperCase();
          if (name == _deviceName || addr == '8C:94:DF:97:BC:FA' || name.contains('BioMonitor')) {
            if (!completer.isCompleted) {
              completer.complete(r.device);
            }
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

      final device = await completer.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () => null,
      );
      await FlutterBluePlus.stopScan();
      await sub.cancel();

      if (device == null) {
        throw Exception('Device "$_deviceName" not found. Ensure ESP32 is powered on.');
      }

      status = ConnectionStatus.connecting;
      logTerm('CONNECTING TO ${device.platformName}...');
      notifyListeners();

      _device = device;
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && status == ConnectionStatus.connected) {
          status = ConnectionStatus.disconnected;
          logTerm('ESP32 DISCONNECTED.');
          latestData = {};
          _stopMetricsTimer();
          notifyListeners();
        }
      });

      await device.connect(timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();

      // Look for Nordic UART Service (NUS) first
      BluetoothCharacteristic? notifyChar;
      for (final service in services) {
        if (service.uuid == _nusServiceUuid) {
          for (final c in service.characteristics) {
            if (c.uuid == _nusCharTxUuid) {
              notifyChar = c;
            } else if (c.uuid == _nusCharRxUuid) {
              _rxCharacteristic = c;
            }
          }
        }
      }

      // Fallback to legacy service if NUS is absent
      if (notifyChar == null) {
        for (final service in services) {
          if (service.uuid == _legacyServiceUuid) {
            for (final c in service.characteristics) {
              if (c.uuid == _legacyCharUuid) {
                notifyChar = c;
              }
            }
          }
        }
      }

      if (notifyChar == null) {
        throw Exception('No compatible telemetry characteristic found on ESP32.');
      }

      await notifyChar.setNotifyValue(true);
      _valueSub = notifyChar.lastValueStream.listen(_onData);

      status = ConnectionStatus.connected;
      sessionStartTime = DateTime.now();
      _startMetricsTimer();
      logTerm('ESP32 CONNECTED (TELEMETRY ACTIVE).');
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString().replaceFirst('Exception: ', '');
      status = ConnectionStatus.disconnected;
      logTerm('ERROR: $errorMessage');
      notifyListeners();
    }
  }

  /// Sends text commands to ESP32 over NUS RX
  Future<void> sendCommand(String command) async {
    if (_rxCharacteristic != null && status == ConnectionStatus.connected) {
      try {
        final payload = utf8.encode('$command\n');
        await _rxCharacteristic!.write(payload, withoutResponse: true);
        logTerm('CMD SENT: $command');
      } catch (e) {
        debugPrint('Error sending BLE command: $e');
      }
    }
  }

  void _onData(List<int> bytes) {
    if (bytes.isEmpty) return;
    final line = utf8.decode(bytes, allowMalformed: true).trim();
    final parts = line.split(',');
    if (parts.length < 4) return;

    final ir = int.tryParse(parts[0]) ?? 0;
    final bpm = int.tryParse(parts[1]) ?? 0;
    final spo2 = int.tryParse(parts[2]) ?? 0;
    final fingerOk = parts[3] == '1';

    int? ecg;
    bool? leadsOff;
    int bpmEcg = 0;
    SignalQuality sqi = SignalQuality.leadArtifact;

    if (parts.length >= 6) {
      ecg = int.tryParse(parts[4]);
      leadsOff = parts[5] == '1';
    }
    if (parts.length >= 7) {
      bpmEcg = int.tryParse(parts[6]) ?? 0;
    }
    if (parts.length >= 8) {
      sqi = _decodeSqi(int.tryParse(parts[7]));
    }

    _processTelemetry(
      ir: ir,
      bpm: bpm,
      spo2: spo2,
      fingerOk: fingerOk,
      ecg: ecg ?? 0,
      leadsOff: leadsOff ?? true,
      bpmEcg: bpmEcg,
      sqi: sqi,
    );
  }

  SignalQuality _decodeSqi(int? code) {
    switch (code) {
      case 0:
        return SignalQuality.clean;
      case 1:
        return SignalQuality.moderateNoise;
      default:
        return SignalQuality.leadArtifact;
    }
  }

  /// Called at full sample rate (~50Hz). Only touches raw fields, mutable
  /// waveform buffers, and the [waveformTick] notifier — never calls
  /// [notifyListeners] directly, so it can never cause a full-tree rebuild
  /// or text/metric flicker. UI-facing metrics are folded in by the
  /// throttled timer started in [_startMetricsTimer].
  void _processTelemetry({
    required int ir,
    required int bpm,
    required int spo2,
    required bool fingerOk,
    required int ecg,
    required bool leadsOff,
    required int bpmEcg,
    required SignalQuality sqi,
  }) {
    // 1. Process PPG Waveform
    double ppgCentered;
    if (!fingerOk || ir < 50000) {
      ppgCentered = (_rng.nextDouble() - 0.5) * 4;
    } else {
      if (_dcBaseline == 0) _dcBaseline = ir.toDouble();
      _dcBaseline += 0.04 * (ir - _dcBaseline);
      ppgCentered = -(ir - _dcBaseline);
    }
    ppgWaveHistory.add(ppgCentered);
    if (ppgWaveHistory.length > maxPoints) ppgWaveHistory.removeAt(0);

    // 2. Process ECG Waveform
    double ecgCentered;
    if (leadsOff) {
      ecgCentered = (_rng.nextDouble() - 0.5) * 3;
    } else {
      if (_ecgBaseline == 0) _ecgBaseline = ecg.toDouble();
      _ecgBaseline += 0.003 * (ecg - _ecgBaseline);
      ecgCentered = ecg - _ecgBaseline;
    }
    ecgWaveHistory.add(ecgCentered);
    if (ecgWaveHistory.length > maxPoints) ecgWaveHistory.removeAt(0);

    // 3. Update sensor modules (used by modular cards + AI summaries)
    pulseOx.pushSample(ir.toDouble());
    ecgModule.pushSample(ecg.toDouble());

    // 4. Genuine cardiac-cycle detection for the heartbeat pulse animation
    // (demo mode uses an exact synthetic-phase crossing instead — see
    // startDemoMode). Real telemetry uses an adaptive-envelope threshold
    // crossing on whichever channel currently has a valid lead.
    if (status != ConnectionStatus.demo) {
      final activeSignal = !leadsOff ? ecgCentered : (fingerOk ? ppgCentered : null);
      if (activeSignal != null) {
        _detectHeartbeatEvent(activeSignal);
      }
    }

    // 5. Stash raw values; folded into `latestData` by the throttled timer.
    _rawIr = ir;
    _rawBpm = bpm;
    _rawSpo2 = spo2;
    _rawFingerOk = fingerOk;
    _rawEcg = ecg;
    _rawLeadsOff = leadsOff;
    _rawBpmEcg = bpmEcg;
    _rawSqi = sqi;

    waveformTick.value++;
  }

  /// Adaptive-envelope amplitude threshold crossing with a mandatory 450ms
  /// refractory lock, so a single cardiac cycle can only ever fire one
  /// pulse — this replaces the old buggy "BPM text changed" trigger, which
  /// could strobe multiple times per beat or miss beats entirely.
  void _detectHeartbeatEvent(double signal) {
    if (signal > _peakEnvelope) {
      _peakEnvelope = signal;
    } else {
      _peakEnvelope *= 0.995; // slow decay lets the threshold track amplitude drift
    }
    final threshold = max(_peakEnvelope * 0.55, 15.0);
    final now = DateTime.now();
    final refractoryOk =
        _lastPeakTime == null || now.difference(_lastPeakTime!) > const Duration(milliseconds: 450);

    if (_peakArmed && signal > threshold && refractoryOk) {
      _peakArmed = false;
      _lastPeakTime = now;
      _recordRPeak(now);
      _triggerHeartPulse();
    } else if (signal < threshold * 0.4) {
      _peakArmed = true;
    }
  }

  void _recordRPeak(DateTime at) {
    _rPeakTimestamps.add(at);
    if (_rPeakTimestamps.length > _maxRPeaks) {
      _rPeakTimestamps.removeAt(0);
    }
  }

  /// Recent beat-to-beat (RR) intervals in milliseconds, most recent last.
  List<int> get recentRrIntervalsMs {
    final out = <int>[];
    for (var i = 1; i < _rPeakTimestamps.length; i++) {
      out.add(_rPeakTimestamps[i].difference(_rPeakTimestamps[i - 1]).inMilliseconds);
    }
    return out;
  }

  /// RMSSD (root mean square of successive RR-interval differences), a
  /// standard time-domain HRV metric, in milliseconds. Null until enough
  /// beats have been observed.
  double? get estimatedHrvRmssdMs {
    final rr = recentRrIntervalsMs;
    if (rr.length < 3) return null;
    var sumSq = 0.0;
    for (var i = 1; i < rr.length; i++) {
      final diff = (rr[i] - rr[i - 1]).toDouble();
      sumSq += diff * diff;
    }
    return sqrt(sumSq / (rr.length - 1));
  }

  /// Coefficient-of-variation based rhythm regularity label for RR
  /// intervals, e.g. "Regular" vs "Irregular" — feeds the AI copilot.
  String get pulseRhythmRegularity {
    final rr = recentRrIntervalsMs;
    if (rr.length < 3) return 'Insufficient data';
    final mean = rr.reduce((a, b) => a + b) / rr.length;
    if (mean <= 0) return 'Insufficient data';
    final variance = rr.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) / rr.length;
    final cv = sqrt(variance) / mean;
    if (cv < 0.08) return 'Regular';
    if (cv < 0.18) return 'Mild variability (physiological)';
    return 'Irregular';
  }

  String get signalQualityLabel {
    switch (_rawSqi) {
      case SignalQuality.clean:
        return 'CLEAN';
      case SignalQuality.moderateNoise:
        return 'MODERATE_NOISE';
      case SignalQuality.leadArtifact:
        return 'LEAD_ARTIFACT';
    }
  }

  void _startMetricsTimer() {
    _metricsTimer?.cancel();
    _smoothBpm = null;
    _smoothSpo2 = null;
    _smoothIr = null;
    _metricsTimer = Timer.periodic(_metricsInterval, (_) => _flushMetrics());
  }

  void _stopMetricsTimer() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
  }

  /// Folds the latest raw telemetry into a smoothed, throttled snapshot and
  /// notifies listeners. Runs at ~1.3Hz — the only rate at which text
  /// widgets are asked to rebuild.
  void _flushMetrics() {
    const alpha = 0.45; // EMA weight; higher = snappier, lower = smoother

    if (_rawFingerOk && _rawBpm > 0) {
      _smoothBpm = _smoothBpm == null ? _rawBpm.toDouble() : _smoothBpm! + alpha * (_rawBpm - _smoothBpm!);
    }
    if (_rawFingerOk && _rawSpo2 > 0) {
      _smoothSpo2 = _smoothSpo2 == null ? _rawSpo2.toDouble() : _smoothSpo2! + alpha * (_rawSpo2 - _smoothSpo2!);
    }
    _smoothIr = _smoothIr == null ? _rawIr.toDouble() : _smoothIr! + alpha * (_rawIr - _smoothIr!);

    latestData = {
      'ir': _smoothIr?.round() ?? _rawIr,
      'bpm': _smoothBpm?.round() ?? 0,
      'spo2': _smoothSpo2?.round() ?? 0,
      'fingerOk': _rawFingerOk,
      'ecg': _rawEcg,
      'leadsOff': _rawLeadsOff,
      'bpmEcg': _rawBpmEcg,
      'sqi': signalQualityLabel,
    };

    notifyListeners();
  }

  void _triggerHeartPulse() {
    heartPulseActive = true;
    notifyListeners();
    _pulseResetTimer?.cancel();
    _pulseResetTimer = Timer(const Duration(milliseconds: 150), () {
      heartPulseActive = false;
      notifyListeners();
    });
  }

  // -------------------------------------------------------------------------
  // DEMO SIMULATION MODE (MATHEMATICAL MULTI-GAUSSIAN P-QRS-T)
  // -------------------------------------------------------------------------
  double _gauss(double x, double mu, double sigma, double amp) {
    final diff = x - mu;
    return amp * exp(-(diff * diff) / (2.0 * sigma * sigma));
  }

  double synthEcg(double t) {
    const period = 3.0; // ~1 beat per second (50 ticks at 50Hz)
    final phase = (t % period) / period;
    return _gauss(phase, 0.18, 0.035, 45.0)   // P Wave
         - _gauss(phase, 0.30, 0.018, 65.0)   // Q Wave
         + _gauss(phase, 0.33, 0.022, 480.0)  // R Peak
         - _gauss(phase, 0.36, 0.018, 130.0)  // S Wave
         + _gauss(phase, 0.55, 0.070, 95.0);  // T Wave
  }

  void startDemoMode() {
    stopDemo();
    status = ConnectionStatus.demo;
    errorMessage = null;
    sessionStartTime = DateTime.now();
    logTerm('DEMO MODE ACTIVATED (SYNTHETIC SIGNALS).');
    _startMetricsTimer();
    _demoPhasePrev = 0.0;

    var t = 0.0;
    const period = 3.0;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      t += 0.06;
      final bpm = 74 + (4 * sin(t / 3)).round();
      // Deterministic waveform only — no per-tick randomness, so nothing
      // vibrates that shouldn't.
      final ir = 90000 + 20000 * sin(t);
      // Stable physiological SpO2 baseline (98%) with a slow 0.2Hz
      // respiratory sinus arrhythmia ripple instead of raw RNG jitter.
      final spo2 = (98 + 0.6 * sin(t * 2 * pi * 0.2)).round();
      final ecgVal = 2048.0 + synthEcg(t);

      // Genuine R-peak event: fires exactly when the synthetic cardiac
      // phase crosses the R wave (~0.33), with the same 450ms refractory
      // lock used for real telemetry, instead of reacting to BPM text
      // changes (which caused the old strobe/double-pulse bug).
      final phase = (t % period) / period;
      if (_demoPhasePrev < 0.33 && phase >= 0.33) {
        final now = DateTime.now();
        final refractoryOk =
            _lastPeakTime == null || now.difference(_lastPeakTime!) > const Duration(milliseconds: 450);
        if (refractoryOk) {
          _lastPeakTime = now;
          _recordRPeak(now);
          _triggerHeartPulse();
        }
      }
      _demoPhasePrev = phase;

      _processTelemetry(
        ir: ir.round(),
        bpm: bpm,
        spo2: spo2,
        fingerOk: true,
        ecg: ecgVal.round(),
        leadsOff: false,
        bpmEcg: bpm,
        sqi: SignalQuality.clean,
      );
    });

    notifyListeners();
  }

  void stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
    _stopMetricsTimer();
    if (status == ConnectionStatus.demo) {
      status = ConnectionStatus.disconnected;
      sessionStartTime = null;
      logTerm('DEMO MODE DEACTIVATED.');
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    stopDemo();
    _stopMetricsTimer();
    await _valueSub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _rxCharacteristic = null;
    status = ConnectionStatus.disconnected;
    sessionStartTime = null;
    latestData = {};
    logTerm('DISCONNECTED.');
    notifyListeners();
  }

  @override
  void dispose() {
    stopDemo();
    _stopMetricsTimer();
    _pulseResetTimer?.cancel();
    _valueSub?.cancel();
    _connSub?.cancel();
    waveformTick.dispose();
    super.dispose();
  }
}
