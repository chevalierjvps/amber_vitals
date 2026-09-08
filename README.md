# Amber Vitals

A modular Flutter app for the biosensor project — connects to the
ESP32-based BLE monitor and shows live vitals, replacing the earlier
browser + Python-bridge setup. Modern Material 3 layout, amber palette
carried over from the desktop rice, monospace glowing numerals on live
readouts as the one deliberate retro touch.

## Modular by design

The app never hardcodes "MAX30102 + AD8232" — it just asks a list of
[`SensorModule`](lib/modules/sensor_module.dart) implementations whether
they currently have data, and renders a card for each one that does.
Today that's one working module ([pulse oximeter](lib/modules/pulse_ox_module.dart),
BPM + SpO2 + live PPG waveform) and one placeholder
([ECG](lib/modules/ecg_module.dart)) that's wired up but stays dormant
until the AD8232 actually starts sending an `ecgMv` field over BLE — no
other file needs to change when that happens.

To add a new sensor later: implement `SensorModule`, add one line to the
`modules` list in [`home_screen.dart`](lib/screens/home_screen.dart), done.

## BLE contract

Matches `esp32_amber_monitor.ino`: device name `ESP32-BioMonitor`, service
`4fafc201-1fb5-459e-8fcc-c5c9c331914b`, characteristic
`beb5483e-36e1-4688-b7f5-ea07361b26a8` (NOTIFY), payload `IR,BPM,SPO2,FINGER_OK\n`.

No hardware handy? Hit **Demonstração** on the home screen for a simulated
data stream that exercises the whole UI.

## AI insights

Settings → paste an Anthropic API key (stored locally via
`shared_preferences`, never leaves the device except in the API call
itself). The "Analisar" button sends a one-line plain-text summary of
whatever modules are currently available (not raw sensor data) and shows
back a short, non-diagnostic comment. See
[`ai_service.dart`](lib/services/ai_service.dart).

## Running it

Built and verified so far on **Linux desktop**:

```sh
flutter pub get
flutter run -d linux
```

Android is untested — the code is cross-platform (`flutter_blue_plus`
supports it), but this dev machine doesn't have the Android SDK
command-line tools installed, so `flutter run -d android` hasn't actually
been exercised yet.

## Status

- [x] Modular sensor-card architecture
- [x] BLE connect + live pulse-ox readings + waveform
- [x] Demo mode (no hardware required)
- [x] AI insight panel (bring your own Anthropic key)
- [ ] AD8232 ECG module (activates automatically once the firmware sends it)
- [ ] Android build verified on a device/emulator
