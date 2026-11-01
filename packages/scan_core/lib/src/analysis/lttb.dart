/// Прореживание Largest-Triangle-Three-Buckets: из каждого интервала берётся точка,
/// дающая наибольший треугольник с соседями. В отличие от усреднения сохраняет
/// пики и переключения лямбды — форма кривой остаётся читаемой.
List<(int, double)> lttb(List<int> t, List<double> v, int threshold) {
  final n = t.length;
  if (threshold >= n || threshold < 3) {
    return [for (var i = 0; i < n; i++) (t[i], v[i])];
  }

  final sampled = <(int, double)>[(t[0], v[0])];
  final every = (n - 2) / (threshold - 2);
  var a = 0;
  for (var i = 0; i < threshold - 2; i++) {
    // Среднее следующего интервала — третья вершина треугольника.
    final avgStart = ((i + 1) * every).floor() + 1;
    var avgEnd = ((i + 2) * every).floor() + 1;
    if (avgEnd > n) avgEnd = n;
    var avgT = 0.0;
    var avgV = 0.0;
    for (var j = avgStart; j < avgEnd; j++) {
      avgT += t[j];
      avgV += v[j];
    }
    final len = avgEnd - avgStart;
    avgT /= len;
    avgV /= len;

    final rangeStart = (i * every).floor() + 1;
    final rangeEnd = ((i + 1) * every).floor() + 1;
    var maxArea = -1.0;
    var next = rangeStart;
    for (var j = rangeStart; j < rangeEnd; j++) {
      final area =
          ((t[a] - avgT) * (v[j] - v[a]) - (t[a] - t[j]) * (avgV - v[a])).abs();
      if (area > maxArea) {
        maxArea = area;
        next = j;
      }
    }
    sampled.add((t[next], v[next]));
    a = next;
  }
  sampled.add((t[n - 1], v[n - 1]));
  return sampled;
}
