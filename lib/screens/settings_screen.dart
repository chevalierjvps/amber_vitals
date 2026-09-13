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
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Gemini API Key', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Used for AI biometric health insights. Stored locally on this device. '
            'Get your free key at aistudio.google.com/apikey.',
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
          Text('AI Model', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Default: ${AiService.defaultModel}. If Google updates or renames the model, update it here without code changes.',
            style: const TextStyle(color: AmberPalette.textDim, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(hintText: 'gemini-2.0-flash'),
          ),
          const SizedBox(height: 20),
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
            child: Text(_saved ? 'Saved!' : 'Save Settings'),
          ),

          const SizedBox(height: 36),
          const Divider(color: AmberPalette.border),
          const SizedBox(height: 20),

          // About & Credits Section (João V.P.)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: AmberPalette.amber, size: 20),
                      const SizedBox(width: 8),
                      Text('About Amber Vitals', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'AMBER-01 · Clinical-Style Biotelemetry Unit',
                    style: TextStyle(color: AmberPalette.text, fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Engineered & Developed by João V.P. (@chevalierjvps)',
                    style: TextStyle(color: AmberPalette.amber, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Real-time biomedical telemetry monitor pairing an ESP32 microcontroller with an AD8232 ECG sensor and a MAX30102 pulse oximeter over Nordic UART Service (NUS) Bluetooth Low Energy, with on-device DSP filtering and a Gemini-powered telemetry copilot.',
                    style: TextStyle(color: AmberPalette.textDim, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Hardware Serial: SN 30102-BE1 · Version 2.0.0',
                    style: TextStyle(color: AmberPalette.textDim, fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'DIY educational electronics project — not a certified medical device. '
                    'It does not diagnose conditions; consult a healthcare professional for any real health concern.',
                    style: TextStyle(color: AmberPalette.textDim, fontSize: 10.5, height: 1.4, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
