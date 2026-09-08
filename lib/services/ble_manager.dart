import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../modules/pulse_ox_module.dart';
import '../modules/sensor_module.dart';

enum ConnectionStatus { disconnected, scanning, connecting, connected, demo }

/// Matches the ESP32 firmware's GATT server (esp32_amber_monitor.ino):
/// device name "ESP32-BioMonitor", one service/characteristic sending
/// "IR,BPM,SPO2,FINGER_OK\n" as a NOTIFY string at ~25Hz.
///
/// Owns the single source of truth for live [SensorData], and hands it to
/// whichever [SensorModule]s say they can use it — this class knows about
/// the wire format, nothing above it does.
class BleManager extends ChangeNotifier {
  static final _serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final _charUuid = Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');
  static const _deviceName = 'ESP32-BioMonitor';

  ConnectionStatus status = ConnectionStatus.disconnected;
  String? errorMessage;
  SensorData latestData = {};

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _demoTimer;

  final PulseOxModule pulseOx = PulseOxModule();

  Future<void> connect() async {
    errorMessage = null;
    status = ConnectionStatus.scanning;
    notifyListeners();

    try {
      if (await FlutterBluePlus.isSupported == false) {
        throw Exception('Bluetooth não suportado neste dispositivo.');
      }

      final completer = Completer<BluetoothDevice?>();
      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (r.device.platformName == _deviceName) {
            if (!completer.isCompleted) completer.complete(r.device);
          }
        }
      });

      await FlutterBluePlus.startScan(
        withNames: [_deviceName],
        timeout: const Duration(seconds: 8),
      );

      final device = await completer.future.timeout(
        const Duration(seconds: 9),
        onTimeout: () => null,
      );
      await FlutterBluePlus.stopScan();
      await sub.cancel();

      if (device == null) {
        throw Exception('Dispositivo "$_deviceName" não encontrado. Verifique se o ESP32 está ligado e por perto.');
      }

      status = ConnectionStatus.connecting;
      notifyListeners();

      _device = device;
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && status == ConnectionStatus.connected) {
          status = ConnectionStatus.disconnected;
          latestData = {};
          notifyListeners();
        }
      });

      await device.connect(timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();

      final service = services.firstWhere(
        (s) => s.uuid == _serviceUuid,
        orElse: () => throw Exception('Serviço BLE esperado não encontrado no dispositivo.'),
      );
      final characteristic = service.characteristics.firstWhere(
        (c) => c.uuid == _charUuid,
        orElse: () => throw Exception('Característica BLE esperada não encontrada.'),
      );

      await characteristic.setNotifyValue(true);
      _valueSub = characteristic.lastValueStream.listen(_onData);

      status = ConnectionStatus.connected;
      notifyListeners();
    } catch (e) {
      errorMessage = e.toString().replaceFirst('Exception: ', '');
      status = ConnectionStatus.disconnected;
      notifyListeners();
    }
  }

  void _onData(List<int> bytes) {
    if (bytes.isEmpty) return;
    final line = utf8.decode(bytes, allowMalformed: true).trim();
    // Formato do firmware: "IR,BPM,SPO2,FINGER_OK"
    final parts = line.split(',');
    if (parts.length != 4) return;

    final ir = int.tryParse(parts[0]);
    final bpm = int.tryParse(parts[1]);
    final spo2 = int.tryParse(parts[2]);
    final fingerOk = parts[3] == '1';
    if (ir == null || bpm == null || spo2 == null) return;

    pulseOx.pushSample(ir.toDouble());
    latestData = {
      'ir': ir,
      'bpm': bpm,
      'spo2': spo2,
      'fingerOk': fingerOk,
    };
    notifyListeners();
  }

  /// Simulated data stream so the UI (and the module system) can be
  /// exercised without the physical sensor attached.
  void startDemoMode() {
    stopDemo();
    status = ConnectionStatus.demo;
    errorMessage = null;
    final rng = Random();
    var t = 0.0;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      t += 0.12;
      final ir = 90000 + 20000 * sin(t) + rng.nextDouble() * 800;
      pulseOx.pushSample(ir);
      latestData = {
        'ir': ir.round(),
        'bpm': 72 + rng.nextInt(6),
        'spo2': 97 + rng.nextInt(3),
        'fingerOk': true,
      };
      notifyListeners();
    });
    notifyListeners();
  }

  void stopDemo() {
    _demoTimer?.cancel();
    _demoTimer = null;
  }

  Future<void> disconnect() async {
    stopDemo();
    await _valueSub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _device = null;
    status = ConnectionStatus.disconnected;
    latestData = {};
    notifyListeners();
  }

  @override
  void dispose() {
    stopDemo();
    _valueSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}
