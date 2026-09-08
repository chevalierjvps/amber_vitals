import 'package:flutter/widgets.dart';

/// A single physical sensor's data slice, as decoded by [BleManager] from
/// whatever BLE characteristic feeds it. Plain string-keyed values keep
/// this generic enough that a new sensor doesn't need any change here.
typedef SensorData = Map<String, dynamic>;

/// Contract every sensor "module" implements. The home screen never knows
/// about specific sensors — it just asks each registered module whether it
/// currently has data, and if so, renders whatever card the module builds.
///
/// To add a new sensor later (e.g. the AD8232 ECG): implement this
/// interface, register it in [SensorModule.all], and it shows up
/// automatically — no other file needs to change.
abstract class SensorModule {
  /// Stable id, also used to namespace this module's keys in [SensorData].
  String get id;

  /// Human-readable name shown in the UI.
  String get displayName;

  IconData get icon;

  /// Whether [data] contains a fresh, meaningful reading for this module.
  /// Modules with no data yet (sensor not wired in, or not sending) return
  /// false and are simply not shown, instead of rendering stale/garbage
  /// values.
  bool isAvailable(SensorData data);

  /// Builds this module's card for the current [data]. Only called when
  /// [isAvailable] is true.
  Widget buildCard(BuildContext context, SensorData data);

  /// One-line plain-text summary of the current reading, used to feed the
  /// AI insights request — keeps that prompt sensor-agnostic too.
  String summarize(SensorData data);
}
