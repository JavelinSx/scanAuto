import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/ai/ai_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/live/live_screen.dart';
import '../features/logs/logs_screen.dart';
import '../features/program/program_run_screen.dart';
import '../features/program/program_setup_screen.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const ConnectScreen()),
    GoRoute(path: '/live', builder: (context, state) => const LiveScreen()),
    GoRoute(
      path: '/program',
      builder: (context, state) => const ProgramSetupScreen(),
    ),
    GoRoute(
      path: '/program/run',
      builder: (context, state) => const ProgramRunScreen(),
    ),
    GoRoute(path: '/ai', builder: (context, state) => const AiScreen()),
    GoRoute(path: '/logs', builder: (context, state) => const LogsScreen()),
  ],
);

class ScanAutoApp extends StatelessWidget {
  const ScanAutoApp({super.key});

  static const _seed = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'scanAuto',
      routerConfig: _router,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
    );
  }
}
