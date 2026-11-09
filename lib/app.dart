import 'package:flutter/material.dart';

import 'data/settings.dart';
import 'features/cashier/cashier_screen.dart';
import 'features/role/role_picker_screen.dart';
import 'features/terminal/terminal_screen.dart';
import 'services/app_services.dart';

class PosLinkApp extends StatelessWidget {
  const PosLinkApp({super.key, required this.services});

  final AppServices services;

  static ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E), brightness: brightness),
        useMaterial3: true,
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POS Link',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: services,
        builder: (context, _) {
          final role = services.settings.role;
          if (role == null) return RolePickerScreen(services: services);
          if (!services.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          return role == AppRole.cashier ? CashierScreen(services: services) : TerminalScreen(services: services);
        },
      ),
    );
  }
}
