import 'package:flutter/material.dart';
import 'ui/theme/app_theme.dart';
import 'ui/app_shell.dart';

/// The root MaterialApp widget for Autonion Agent.
class AutonionApp extends StatelessWidget {
  const AutonionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Autonion Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const AppShell(),
    );
  }
}
