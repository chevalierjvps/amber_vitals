import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps the Google Gemini API (generativelanguage.googleapis.com) to turn
/// a plain-text summary of the current sensor readings into a short,
/// plain-language comment. Gemini has a free tier, which is why this is
/// the default instead of a paid API.
///
/// Deliberately takes a pre-built summary string (see
/// [SensorModule.summarize]) rather than raw sensor data, so this class
/// doesn't need to know anything about which sensors exist.
class AiService {
  static const _apiKeyPrefKey = 'gemini_api_key';
  static const _modelPrefKey = 'gemini_model';

  // gemini-2.0-flash is the free-tier-friendly model as of when this was
  // written. Google renames/retires models occasionally — if this one ever
  // 404s, the model name is user-editable in Settings without touching code.
  static const defaultModel = 'gemini-2.0-flash';

  static const _systemInstruction =
      'Você comenta leituras de sensores biométricos de um projeto pessoal/educacional de eletrônica. '
      'Nunca dê diagnóstico médico — apenas descreva a tendência dos números em 2-3 frases curtas, em '
      'português, de forma acessível. Se algo estiver fora de faixas de referência gerais, mencione com '
      'cautela e sugira observar/procurar um profissional se persistir, sem alarmismo.';

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

  /// Sends [summary] (e.g. "Oxímetro: 78 bpm, SpO2 98%.") and returns a
  /// short interpretation. Throws with a user-facing message on failure.
  static Future<String> interpret(String summary) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Configure sua chave de API do Gemini nas Configurações primeiro.');
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
              {'text': summary},
            ],
          },
        ],
        'generationConfig': {'maxOutputTokens': 300},
      }),
    );

    if (response.statusCode != 200) {
      final body = _tryDecodeError(response.body);
      throw Exception('Erro da API (${response.statusCode}): $body');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Resposta da API veio vazia (pode ter sido bloqueada por filtro de segurança).');
    }
    final content = (candidates.first as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw Exception('Resposta da API veio sem texto.');
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
