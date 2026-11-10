import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/background_session.dart';
import '../features/ai/ai_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/live/live_screen.dart';
import '../features/live/scan_controller.dart';
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

class ScanAutoApp extends ConsumerStatefulWidget {
  const ScanAutoApp({super.key});

  @override
  ConsumerState<ScanAutoApp> createState() => _ScanAutoAppState();
}

class _ScanAutoAppState extends ConsumerState<ScanAutoApp> {
  static const _seed = Color(0xFF1565C0);

  // Сворачивание и выключение экрана — в журнал сеанса: так видно,
  // откуда пауза в записи.
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (s) {
      ref.read(scanControllerProvider.notifier).logLifecycle(s.name);
      // Вернулись из настроек — проверить, сняли ли ограничение батареи.
      if (s == AppLifecycleState.resumed) {
        ref.invalidate(backgroundStatusProvider);
      }
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

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
