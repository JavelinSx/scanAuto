import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanauto/app/app.dart';

void main() {
  testWidgets('стартовый экран предлагает симулятор и Wi-Fi', (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: ScanAutoApp()));
    expect(find.text('Симулятор'), findsOneWidget);
    expect(find.text('Wi-Fi адаптер'), findsOneWidget);
  });

  testWidgets('симулятор: подключение, ошибка P0171, данные, отключение', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ProviderScope(child: ScanAutoApp()));
    await tester.tap(find.text('Запустить'));
    // Ответы симулятора и опрос идут на таймерах — прокручиваем фейковое время.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('P0171'), findsOneWidget);
    expect(find.textContaining('об/мин'), findsWidgets);

    await tester.tap(find.byTooltip('Отключиться'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Симулятор'), findsOneWidget);
  });
}
