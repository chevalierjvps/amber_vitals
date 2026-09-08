import 'package:flutter/material.dart';

import '../services/ai_service.dart';
import '../theme/amber_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _keyController = TextEditingController();
  final _modelController = TextEditingController();
  bool _saved = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    AiService.getApiKey().then((key) {
      if (key != null && mounted) setState(() => _keyController.text = key);
    });
    AiService.getModel().then((model) {
      if (mounted) setState(() => _modelController.text = model);
    });
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Chave de API do Gemini', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Usada para os insights de IA sobre suas leituras. Fica salva só neste dispositivo. '
            'Pegue a sua de graça em aistudio.google.com/apikey.',
            style: TextStyle(color: AmberPalette.textDim, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyController,
            obscureText: _obscure,
            decoration: InputDecoration(
              hintText: 'AIzaSy...',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Modelo', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Padrão: ${AiService.defaultModel}. Se o Google renomear/aposentar esse modelo, troque aqui sem precisar mexer no código.',
            style: const TextStyle(color: AmberPalette.textDim, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(hintText: 'gemini-2.0-flash'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await AiService.setApiKey(_keyController.text.trim());
              await AiService.setModel(
                _modelController.text.trim().isEmpty ? AiService.defaultModel : _modelController.text.trim(),
              );
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
