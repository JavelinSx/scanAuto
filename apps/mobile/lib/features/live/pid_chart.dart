import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:scan_core/scan_core.dart';

/// График одного PID за последние [window].
class PidChart extends StatelessWidget {
  const PidChart({
    super.key,
    required this.pid,
    required this.series,
    this.window = const Duration(minutes: 2),
  });

  final Pid pid;
  final Series? series;
  final Duration window;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = series;
    if (s == null || s.length < 2) {
      return const SizedBox(
        height: 200,
        child: Center(child: Text('Копим данные…')),
      );
    }

    // Перерисовка 4 раза в секунду: окно ищем двоичным поиском, а не проходом
    // по всей записи, которая за час вырастает до десятков тысяч точек.
    final fromMs = s.tMs.last - window.inMilliseconds;
    final spots = [
      for (var i = s.lowerBound(fromMs); i < s.length; i++)
        FlSpot(s.tMs[i] / 1000, s.values[i]),
    ];
    // Ось по данным с запасом, но не шире типичного диапазона параметра.
    var lo = spots.map((p) => p.y).reduce(min);
    var hi = spots.map((p) => p.y).reduce(max);
    final pad = max((hi - lo) * 0.15, (pid.max - pid.min) * 0.02);
    lo = max(lo - pad, pid.min);
    hi = min(hi + pad, pid.max);
    if (hi <= lo) hi = lo + 1;

    final axisStyle = Theme.of(context).textTheme.labelSmall;
    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minX: max(fromMs / 1000, 0),
          maxX: s.tMs.last / 1000,
          minY: lo,
          maxY: hi,
          lineTouchData: const LineTouchData(enabled: false),
          gridData: const FlGridData(drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 30,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text('${value.toInt()} с', style: axisStyle),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    value.toStringAsFixed(pid.decimals),
                    style: axisStyle,
                  ),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              barWidth: 2,
              color: scheme.primary,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: scheme.primary.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
        duration: Duration.zero,
      ),
    );
  }
}
