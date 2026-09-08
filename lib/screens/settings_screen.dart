import 'package:flutter/material.dart';

import '../services/ai_service.dart';
import '../theme/amber_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _saved = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    AiService.getApiKey().then((key) {
      if (key != null && mounted) setState(() => _controller.text = key);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Chave de API da Anthropic', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Usada para os insights de IA sobre suas leituras. Fica salva só neste dispositivo.',
            style: const TextStyle(color: AmberPalette.textDim, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            decoration: InputDecoration(
              hintText: 'sk-ant-...',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await AiService.setApiKey(_controller.text.trim());
              setState(() => _saved = true);
              await Future.delayed(const Duration(seconds: 2));
              if (mounted) setState(() => _saved = false);
            },
            child: Text(_saved ? 'Salvo!' : 'Salvar'),
          ),
        ],
      ),
    );
  }
}
