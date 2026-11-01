import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/connect/connect_screen.dart';
import '../features/live/live_screen.dart';

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const ConnectScreen()),
    GoRoute(path: '/live', builder: (context, state) => const LiveScreen()),
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
