import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/amber_theme.dart';

/// Oscilloscope CRT Widget - Reproduz fielmente a estética do monitor CRT Amber do PC
class CrtOscilloscope extends StatelessWidget {
  final String title;
  final String statusText;
  final List<double> samples;
  final bool alertActive;
  final String alertMessage;
  final bool isDemo;
  final Color waveColor;

  const CrtOscilloscope({
    super.key,
    required this.title,
    required this.statusText,
    required this.samples,
    this.alertActive = false,
    this.alertMessage = '',
    this.isDemo = false,
    this.waveColor = const Color(0xFFFFB000),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0C0701),
        border: Border.all(color: const Color(0xFF2E1C00), width: 1.5),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabeçalho do Canal
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: const TextStyle(
                  color: Color(0xFF7A4A00),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              Text(
                statusText.toUpperCase(),
                style: TextStyle(
                  color: alertActive ? AmberPalette.red : const Color(0xFF7A4A00),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Tela do Osciloscópio
          Expanded(
            child: Stack(
              children: [
                // Fundo com Grid e Traçado da Onda
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF060300),
                      ),
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _CrtWavePainter(
                            samples: samples,
                            waveColor: waveColor,
                            gridColor: const Color(0x287A4A00),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Badge de Modo Demo
                if (isDemo)
                  Positioned(
                    top: 6,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: AmberPalette.green, width: 1),
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.black.withValues(alpha: 0.7),
                      ),
                      child: const Text(
                        'SIMULATED',
                        style: TextStyle(
                          color: AmberPalette.green,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),

                // Banner de Alerta Centralizado (ex: "COLOQUE O DEDO NO SENSOR" ou "ELETRODO SOLTO")
                if (alertActive)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xF00A0601),
                        border: Border.all(
                          color: const Color(0xFF7A4A00),
                          style: BorderStyle.solid,
                          width: 1.2,
                        ),
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.8),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: Text(
                        alertMessage.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFD8C48A),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CrtWavePainter extends CustomPainter {
  final List<double> samples;
  final Color waveColor;
  final Color gridColor;
  static const int maxPoints = 300;

  _CrtWavePainter({
    required this.samples,
    required this.waveColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Linhas da Grade do Osciloscópio
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final stepX = size.width / 10.0;
    final stepY = size.height / 6.0;

    for (double x = stepX; x < size.width; x += stepX) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = stepY; y < size.height; y += stepY) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (samples.length < 2) return;

    // 2. Escalonamento adaptativo da amplitude
    double minVal = -100;
    double maxVal = 100;
    for (final v in samples) {
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final range = max(maxVal - minVal, 180.0);
    final midY = size.height / 2.0;

    final path = Path();
    for (int i = 0; i < samples.length; i++) {
      final x = (i / maxPoints) * size.width;
      final y = midY - (samples[i] / (range / 2.0)) * (size.height * 0.42);
      final clampedY = y.clamp(1.5, size.height - 1.5);
      if (i == 0) {
        path.moveTo(x, clampedY);
      } else {
        path.lineTo(x, clampedY);
      }
    }

    // 3. Brilho Fósforo Âmbar (Glow exterior)
    final glowPaint = Paint()
      ..color = waveColor.withValues(alpha: 0.4)
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    canvas.drawPath(path, glowPaint);

    // 4. Núcleo Nítido da Onda (Core brilhante)
    final corePaint = Paint()
      ..color = waveColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, corePaint);
  }

  @override
  bool shouldRepaint(covariant _CrtWavePainter oldDelegate) => true;
}
