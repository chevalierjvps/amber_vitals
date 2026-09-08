import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/ble_manager.dart';
import 'theme/amber_theme.dart';

void main() {
  runApp(const AmberVitalsApp());
}

class AmberVitalsApp extends StatelessWidget {
  const AmberVitalsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => BleManager(),
      child: MaterialApp(
        title: 'Amber Vitals',
        debugShowCheckedModeBanner: false,
        theme: AmberTheme.build(),
        home: const HomeScreen(),
      ),
    );
  }
}
