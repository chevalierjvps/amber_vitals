import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps the Anthropic Messages API to turn a plain-text summary of the
/// current sensor readings into a short, plain-language comment.
///
/// Deliberately takes a pre-built summary string (see
/// [SensorModule.summarize]) rather than raw sensor data, so this class
/// doesn't need to know anything about which sensors exist.
class AiService {
  static const _apiKeyPrefKey = 'anthropic_api_key';

  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyPrefKey);
  }

  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyPrefKey, key);
  }

  /// Sends [summary] (e.g. "Oxímetro: 78 bpm, SpO2 98%.") and returns a
  /// short interpretation. Throws with a user-facing message on failure.
  static Future<String> interpret(String summary) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Configure sua chave de API da Anthropic nas Configurações primeiro.');
    }

    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-haiku-4-5-20251001',
        'max_tokens': 300,
        'system':
            'Você comenta leituras de sensores biométricos de um projeto pessoal/educacional de eletrônica. '
            'Nunca dê diagnóstico médico — apenas descreva a tendência dos números em 2-3 frases curtas, em '
            'português, de forma acessível. Se algo estiver fora de faixas de referência gerais, mencione com '
            'cautela e sugira observar/procurar um profissional se persistir, sem alarmismo.',
        'messages': [
          {'role': 'user', 'content': summary},
        ],
      }),
    );

    if (response.statusCode != 200) {
      final body = _tryDecodeError(response.body);
      throw Exception('Erro da API (${response.statusCode}): $body');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final content = decoded['content'] as List<dynamic>?;
    if (content == null || content.isEmpty) {
      throw Exception('Resposta da API veio vazia.');
    }
    return (content.first as Map<String, dynamic>)['text'] as String? ?? '';
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
