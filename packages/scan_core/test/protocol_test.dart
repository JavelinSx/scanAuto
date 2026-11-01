import 'package:scan_core/scan_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseObdResponse', () {
    test('одна строка с пробелами и без', () {
      expect(parseObdResponse('41 0C 1A F8\r\r'), [
        [0x41, 0x0C, 0x1A, 0xF8],
      ]);
      expect(parseObdResponse('410C1AF8'), [
        [0x41, 0x0C, 0x1A, 0xF8],
      ]);
    });

    test('эхо и SEARCHING... отбрасываются', () {
      expect(
        parseObdResponse(
          '010C\rSEARCHING...\r41 0C 0B B8\r\r',
          command: '010C',
        ),
        [
          [0x41, 0x0C, 0x0B, 0xB8],
        ],
      );
    });

    test('ответ двух блоков — два сообщения', () {
      expect(parseObdResponse('4100BE3FA813\r4100 98180001'), hasLength(2));
    });

    test('многокадровый ответ CAN склеивается и обрезается по длине', () {
      const raw =
          '014\r'
          '0: 49 02 01 58 54 41\r'
          '1: 32 31 39 30 30 30 30\r'
          '2: 30 30 30 30 30 30 31\r';
      final messages = parseObdResponse(raw);
      expect(messages, hasLength(1));
      expect(messages.single, hasLength(0x14));
      expect(
        String.fromCharCodes(messages.single.sublist(3)),
        'XTA21900000000001',
      );
    });

    test('ошибки адаптера', () {
      expect(
        () => parseObdResponse('NO DATA'),
        throwsA(
          isA<ElmException>().having((e) => e.error, 'error', ElmError.noData),
        ),
      );
      expect(
        () => parseObdResponse('SEARCHING...\rUNABLE TO CONNECT'),
        throwsA(
          isA<ElmException>().having(
            (e) => e.error,
            'error',
            ElmError.unableToConnect,
          ),
        ),
      );
      expect(
        () => parseObdResponse('?'),
        throwsA(
          isA<ElmException>().having(
            (e) => e.error,
            'error',
            ElmError.unknownCommand,
          ),
        ),
      );
    });

    test('mode01Data берёт данные нужного PID', () {
      final messages = parseObdResponse('41 05 7B');
      expect(mode01Data(messages, 0x05), [0x7B]);
      expect(mode01Data(messages, 0x0C), isNull);
    });
  });

  group('PID', () {
    test('формулы J1979', () {
      expect(pidsByKey['rpm']!.decode([0x1A, 0xF8]), 1726);
      expect(pidsByKey['coolant']!.decode([0x7B]), 83);
      expect(pidsByKey['ltft1']!.decode([0x80]), 0);
      expect(pidsByKey['ltft1']!.decode([0x91]), closeTo(13.28, 0.01));
      expect(pidsByKey['maf']!.decode([0x01, 0x2C]), 3);
      expect(pidsByKey['o2_b1s1']!.decode([0x5A, 0x80]), 0.45);
      expect(pidsByKey['voltage']!.decode([0x37, 0x6E]), closeTo(14.19, 0.001));
    });

    test('мало байт — null, а не мусор', () {
      expect(pidsByKey['rpm']!.decode([0x1A]), isNull);
    });

    test('маска поддерживаемых PID туда и обратно', () {
      const supported = {0x01, 0x05, 0x0C, 0x0D, 0x20};
      final encoded = encodeSupportedPids(0x00, supported);
      expect(decodeSupportedPids(0x00, encoded), supported);
      expect(
        decodeSupportedPids(0x00, [0xBE, 0x1F, 0xA8, 0x13]),
        containsAll([0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x20]),
      );
    });
  });

  group('коды неисправностей', () {
    test('расшифровка двух байт', () {
      expect(decodeDtc(0x01, 0x71), 'P0171');
      expect(decodeDtc(0x04, 0x20), 'P0420');
      expect(decodeDtc(0xC1, 0x23), 'U0123');
      expect(decodeDtc(0x41, 0x00), 'C0100');
      expect(decodeDtc(0x93, 0x45), 'B1345');
    });

    test('encodeDtc обратна decodeDtc', () {
      for (final code in ['P0171', 'P0300', 'P2BAE', 'U0100', 'B1345']) {
        final [a, b] = encodeDtc(code);
        expect(decodeDtc(a, b), code);
      }
    });

    test('CAN: число кодов, затем пары', () {
      expect(
        parseDtcResponse(
          [
            [0x43, 0x02, 0x01, 0x71, 0x03, 0x01],
          ],
          mode: 3,
          isCan: true,
        ),
        ['P0171', 'P0301'],
      );
    });

    test('старые протоколы: пары, добитые нулями; повторы убираются', () {
      expect(
        parseDtcResponse(
          [
            [0x43, 0x01, 0x71, 0x00, 0x00, 0x00, 0x00],
            [0x43, 0x01, 0x71, 0x04, 0x20, 0x00, 0x00],
          ],
          mode: 3,
          isCan: false,
        ),
        ['P0171', 'P0420'],
      );
    });

    test('описание: известный код и устройство неизвестного', () {
      expect(describeDtc('P0171'), contains('бедная'));
      expect(describeDtc('P1234'), contains('код производителя'));
      expect(describeDtc('P2BAE'), contains('общий код SAE'));
      expect(describeDtc('U0100'), contains('сеть блоков'));
    });
  });
}
