import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../modules/ecg_module.dart';
import '../modules/sensor_module.dart';
import '../services/ai_service.dart';
import '../services/ble_manager.dart';
import '../theme/amber_theme.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _aiInsight;
  bool _aiLoading = false;
  String? _aiError;

  Future<void> _askAi(BleManager ble) async {
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });

    // Módulos disponíveis atualmente. Adicionar um módulo novo à lista abaixo
    // é o único lugar que precisa saber que ele existe — o resumo pra IA é
    // montado automaticamente a partir de summarize() de cada um.
    final modules = <SensorModule>[ble.pulseOx];
    final available = modules.where((m) => m.isAvailable(ble.latestData));
    final summary = available.map((m) => m.summarize(ble.latestData)).join(' ');

    if (summary.isEmpty) {
      setState(() {
        _aiLoading = false;
        _aiError = 'Nenhum dado disponível ainda para analisar.';
      });
      return;
    }

    try {
      final result = await AiService.interpret(summary);
      setState(() {
        _aiInsight = result;
        _aiLoading = false;
      });
    } catch (e) {
      setState(() {
        _aiError = e.toString().replaceFirst('Exception: ', '');
        _aiLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();
    final modules = <SensorModule>[ble.pulseOx];
    final availableModules = modules.where((m) => m.isAvailable(ble.latestData)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Amber Vitals'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _ConnectionBar(ble: ble),
          const SizedBox(height: 20),

          // Cada módulo disponível renderiza seu próprio card. Nenhum
          // sensor específico é mencionado aqui — é só uma lista.
          for (final module in availableModules) ...[
            module.buildCard(context, ble.latestData),
            const SizedBox(height: 16),
          ],

          // ECG ainda não foi integrado ao firmware: mostra o placeholder
          // que explica que ele vai aparecer sozinho quando estiver pronto.
          if (!EcgModule().isAvailable(ble.latestData)) ...[
            const EcgComingSoonCard(),
            const SizedBox(height: 16),
          ],

          if (availableModules.isEmpty && ble.status != ConnectionStatus.connected && ble.status != ConnectionStatus.demo)
            _EmptyState(ble: ble),

          const SizedBox(height: 8),
          _AiInsightCard(
            loading: _aiLoading,
            insight: _aiInsight,
            error: _aiError,
            onAsk: availableModules.isEmpty ? null : () => _askAi(ble),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBar extends StatelessWidget {
  final BleManager ble;
  const _ConnectionBar({required this.ble});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (ble.status) {
      ConnectionStatus.connected => ('Conectado', AmberPalette.green),
      ConnectionStatus.demo => ('Modo demonstração', AmberPalette.cream),
      ConnectionStatus.connecting => ('Conectando...', AmberPalette.amber),
      ConnectionStatus.scanning => ('Procurando dispositivo...', AmberPalette.amber),
      ConnectionStatus.disconnected => ('Desconectado', AmberPalette.textDim),
    };

    final busy = ble.status == ConnectionStatus.connecting || ble.status == ConnectionStatus.scanning;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
            if (busy)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else if (ble.status == ConnectionStatus.connected || ble.status == ConnectionStatus.demo)
              OutlinedButton(onPressed: () => ble.disconnect(), child: const Text('Desconectar'))
            else
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(onPressed: () => ble.startDemoMode(), child: const Text('Demonstração')),
                  FilledButton(onPressed: () => ble.connect(), child: const Text('Conectar')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final BleManager ble;
  const _EmptyState({required this.ble});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          const Icon(Icons.sensors_off_rounded, size: 40, color: AmberPalette.textDim),
          const SizedBox(height: 12),
          Text(
            ble.errorMessage ?? 'Conecte o ESP32-BioMonitor por Bluetooth ou use o modo demonstração para ver o app funcionando.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AmberPalette.textDim),
          ),
        ],
      ),
    );
  }
}

class _AiInsightCard extends StatelessWidget {
  final bool loading;
  final String? insight;
  final String? error;
  final VoidCallback? onAsk;

  const _AiInsightCard({required this.loading, required this.insight, required this.error, required this.onAsk});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome_rounded, color: AmberPalette.amber, size: 20),
                const SizedBox(width: 8),
                Text('Insight de IA', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (!loading)
                  TextButton(
                    onPressed: onAsk,
                    child: const Text('Analisar'),
                  )
                else
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (insight != null) ...[
              const SizedBox(height: 12),
              Text(insight!, style: const TextStyle(color: AmberPalette.text, height: 1.4)),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: const TextStyle(color: AmberPalette.red, fontSize: 13)),
            ],
            if (insight == null && error == null) ...[
              const SizedBox(height: 8),
              const Text(
                'Peça um comentário em linguagem simples sobre a leitura atual.',
                style: TextStyle(color: AmberPalette.textDim, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
