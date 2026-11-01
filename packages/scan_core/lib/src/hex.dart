final _hexOnly = RegExp(r'^[0-9A-Fa-f]+$');

/// Байты из hex-строки ответа ELM327: «41 0C 1A F8» или «410C1AF8».
/// null, если строка — не данные (текст, нечётная длина).
List<int>? parseHexBytes(String s) {
  final clean = s.replaceAll(' ', '');
  if (clean.isEmpty || clean.length.isOdd || !_hexOnly.hasMatch(clean)) {
    return null;
  }
  return [
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}

String hexByte(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

String formatHex(List<int> bytes, {bool spaces = true}) =>
    bytes.map(hexByte).join(spaces ? ' ' : '');
