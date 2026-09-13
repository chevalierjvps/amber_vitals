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

/// BleManager - Bluetooth Low Energy communication and telemetry processing engine.
/// Engineered by João V.P.
/// Features:
///   - Standard Nordic UART Service (NUS) (6e400001...)
///   - Legacy BioMonitor Service (4fafc201...)
///   - 7-field biomedical telemetry: IR, BPM, SPO2, FINGER_OK, ECG, LEADS_OFF, BPM_ECG
///   - Real-time rolling oscilloscope buffers (PPG and ECG) with baseline tracking
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

  ConnectionStatus status = ConnectionStatus.disconnected;
  String? errorMessage;
  SensorData latestData = {};

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _demoTimer;
  final Random _rng = Random();

  // Sensor modules
  final PulseOxModule pulseOx = PulseOxModule();
  final EcgModule ecgModule = EcgModule();

  // Oscilloscope buffers (PPG & ECG)
  final List<double> ppgWaveHistory = [];
  final List<double> ecgWaveHistory = [];
  double _dcBaseline = 0;
  double _ecgBaseline = 0;

  // CRT Terminal event log
  final List<String> terminalLogs = ['>>> SYSTEM INITIALIZED.'];

  // Heartbeat notification for audio tone & visual systolic pulse
  int _lastBpm = 0;
  bool heartPulseActive = false;
  Timer? _pulseResetTimer;

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

    if (parts.length >= 6) {
      ecg = int.tryParse(parts[4]);
      leadsOff = parts[5] == '1';
    }
    if (parts.length >= 7) {
      bpmEcg = int.tryParse(parts[6]) ?? 0;
    }

    _processTelemetry(
      ir: ir,
      bpm: bpm,
      spo2: spo2,
      fingerOk: fingerOk,
      ecg: ecg ?? 0,
      leadsOff: leadsOff ?? true,
      bpmEcg: bpmEcg,
    );
  }

  void _processTelemetry({
    required int ir,
    required int bpm,
    required int spo2,
    required bool fingerOk,
    required int ecg,
    required bool leadsOff,
    required int bpmEcg,
  }) {
    // 1. Process PPG Waveform
    if (!fingerOk || ir < 50000) {
      ppgWaveHistory.add((_rng.nextDouble() - 0.5) * 4);
    } else {
      if (_dcBaseline == 0) _dcBaseline = ir.toDouble();
      _dcBaseline += 0.04 * (ir - _dcBaseline);
      ppgWaveHistory.add(-(ir - _dcBaseline));
    }
    if (ppgWaveHistory.length > maxPoints) ppgWaveHistory.removeAt(0);

    // 2. Process ECG Waveform
    if (leadsOff) {
      ecgWaveHistory.add((_rng.nextDouble() - 0.5) * 3);
    } else {
      if (_ecgBaseline == 0) _ecgBaseline = ecg.toDouble();
      _ecgBaseline += 0.003 * (ecg - _ecgBaseline);
      ecgWaveHistory.add(ecg - _ecgBaseline);
    }
    if (ecgWaveHistory.length > maxPoints) ecgWaveHistory.removeAt(0);

    // 3. Update sensor modules
    pulseOx.pushSample(ir.toDouble());
    ecgModule.pushSample(ecg.toDouble());

    // 4. Heartbeat detection for pulse animation
    final activeBpm = (fingerOk && bpm > 0) ? bpm : (bpmEcg > 0 ? bpmEcg : 0);
    if (activeBpm > 0 && activeBpm != _lastBpm) {
      _triggerHeartPulse();
      _lastBpm = activeBpm;
    }

    latestData = {
      'ir': ir,
      'bpm': bpm,
      'spo2': spo2,
      'fingerOk': fingerOk,
      'ecg': ecg,
      'leadsOff': leadsOff,
      'bpmEcg': bpmEcg,
    };

    notifyListeners();
  }

  void _triggerHeartPulse() {
    heartPulseActive = true;
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
    logTerm('DEMO MODE ACTIVATED (SYNTHETIC SIGNALS).');

    var t = 0.0;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      t += 0.06;
      final ir = 90000 + 20000 * sin(t) + _rng.nextDouble() * 800;
      final bpm = 74 + (4 * sin(t / 3)).round();
      final spo2 = 97 + _rng.nextInt(2);
      final ecgVal = 2048.0 + synthEcg(t) + (_rng.nextDouble() - 0.5) * 6;

      _processTelemetry(
        ir: ir.round(),
        bpm: bpm,
        spo2: spo2,
        fingerOk: true,
        ecg: ecgVal.round(),
        leadsOff: false,
        bpmEcg: bpm,
      );
    });

    notifyListeners();
  }

  void stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
    if (status == ConnectionStatus.demo) {
      status = ConnectionStatus.disconnected;
      logTerm('DEMO MODE DEACTIVATED.');
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    stopDemo();
    await _valueSub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    _rxCharacteristic = null;
    status = ConnectionStatus.disconnected;
    latestData = {};
    logTerm('DISCONNECTED.');
    notifyListeners();
  }

  @override
  void dispose() {
    stopDemo();
    _pulseResetTimer?.cancel();
    _valueSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}
