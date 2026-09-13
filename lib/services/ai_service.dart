import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps the Google Gemini API (generativelanguage.googleapis.com) to turn
/// a structured biotelemetry snapshot into the AMBER-01 Telemetry Copilot's
/// report. Gemini has a free tier, which is why this is the default instead
/// of a paid API.
///
/// Deliberately takes a pre-built JSON-able [Map] (see
/// [BleManager.buildTelemetryPayload] in home_screen) rather than raw BLE
/// state, so this class doesn't need to know anything about which sensors
/// exist.
class AiService {
  static const _apiKeyPrefKey = 'gemini_api_key';
  static const _modelPrefKey = 'gemini_model';

  // gemini-2.0-flash is the free-tier-friendly model as of when this was
  // written. Google renames/retires models occasionally — if this one ever
  // 404s, the model name is user-editable in Settings without touching code.
  static const defaultModel = 'gemini-2.0-flash';

  // AMBER-01 Telemetry Copilot: turns a structured biotelemetry JSON stream
  // into a clinically-styled but explicitly educational report. This is a
  // hobby ESP32 + AD8232/MAX30102 project, not a certified medical device —
  // the model is required to say so and to never present its output as an
  // actual diagnosis.
  static const _systemInstruction =
      'You are the AMBER-01 Telemetry Copilot, a biotelemetry interpretation assistant for a '
      'DIY/educational ESP32 electronics project (AD8232 ECG + MAX30102 pulse oximeter), '
      'developed by João V.P. Analyze the provided biotelemetric JSON snapshot and output a '
      'concise, beautifully formatted report using standard Markdown, structured into exactly '
      'these four sections:\n'
      '1. 🫀 RHYTHM & CONDUCTION — sinus rhythm impression, rate classification, and stability, '
      'based only on the given numbers.\n'
      '2. 🫁 HEMODYNAMICS & OXYGENATION — SpO2 / plethysmographic correlation.\n'
      '3. ⚡ SIGNAL INTEGRITY & HRV — signal quality (SQI) assessment and a plain description of '
      'the RR-interval / HRV numbers provided.\n'
      '4. 📋 SUMMARY & GUIDANCE — a clear, reassuring, non-alarmist summary in plain language, '
      'ending with this exact disclaimer verbatim on its own line: "Educational estimate only — '
      'AMBER-01 is a hobby project, not a certified medical device. It does not diagnose any '
      'condition; consult a healthcare professional for any real health concern."\n'
      'You may use accessible clinical terminology (e.g. normocardia, sinus arrhythmia, '
      'hemoglobin saturation) but never state or imply an actual medical diagnosis, and never '
      'omit the disclaimer. If signal quality is poor (SQI = LEAD_ARTIFACT or missing data), say '
      'so plainly instead of speculating about the reading.';

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyPrefKey);
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyPrefKey, key);
  }

  static Future<String> getModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modelPrefKey) ?? defaultModel;
  }

  static Future<void> setModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelPrefKey, model);
  }

  /// Sends a structured [telemetry] snapshot (current_heart_rate,
  /// spo2_percentage, ecg_signal_quality_sqi, calculated_rr_intervals,
  /// estimated_hrv_rmssd_ms, pulse_rhythm_regularity, session_duration, ...)
  /// and returns the formatted Markdown report. Throws with a user-facing
  /// message on failure.
  static Future<String> interpret(Map<String, dynamic> telemetry) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Configure your Gemini API key in Settings first.');
    }
    final model = await getModel();

    final response = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _systemInstruction},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': jsonEncode(telemetry)},
            ],
          },
        ],
        'generationConfig': {'maxOutputTokens': 900},
      }),
    );

    if (response.statusCode != 200) {
      final body = _tryDecodeError(response.body);
      throw Exception('API error (${response.statusCode}): $body');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('API response came back empty (may have been blocked by a safety filter).');
    }
    final content = (candidates.first as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw Exception('API response came back without any text.');
    }
    return (parts.first as Map<String, dynamic>)['text'] as String? ?? '';
  }

  static String _tryDecodeError(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return (decoded['error'] as Map<String, dynamic>?)?['message'] as String? ?? body;
    } catch (_) {
      return body;
    }
  }
}
