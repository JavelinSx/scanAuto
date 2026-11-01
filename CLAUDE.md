# scanAuto

OBD-II сканер для Android (Flutter) с разбором записанных графиков языковой моделью по ключу
пользователя. Документы — `docs/`, начинать с `docs/architecture.md` и `docs/mvp-plan.md`.

## Структура

- `packages/scan_core` — чистый Dart, без Flutter: ELM327, PID и коды, симулятор, запись,
  пакет и клиенты ИИ. Вся логика, которую можно проверить без телефона, живёт здесь.
- `apps/mobile` — Flutter, только интерфейс и платформа (транспорты Bluetooth, хранение, разрешения).
- Корневой `pubspec.yaml` — pub workspace: один `pubspec.lock`, зависимости ставятся из корня.

## Команды

- Зависимости: `flutter pub get` в корне.
- Тесты ядра: `dart test` в `packages/scan_core`; приложения: `flutter test` в `apps/mobile`.
- Анализ: `dart analyze` в `packages/scan_core`, `flutter analyze` в `apps/mobile`.
- Разбор симулятора моделью на ПК: `dart run scan_core:demo --scenario vacuumLeak [--ask]`.
- Симулятор Wi-Fi адаптера на ПК: `dart run scan_core:sim_server --scenario vacuumLeak`.
- Формат проверяет CI: `dart format packages/scan_core apps/mobile/lib apps/mobile/test`.

## Правила

- Документы, комментарии и тексты интерфейса — по-русски. Комментарий объясняет «почему», а не «что».
- Версии пакетов перед добавлением сверять с pub.dev и записывать в таблицу стека в `docs/architecture.md`.
- `test` в `scan_core` не поднимать выше того, что разрешает `flutter_test` (он закрепляет `test_api`).
- Новая логика протокола — сначала поддержка в `SimulatedElm327`, потом тест в `scan_core`.
- В ЭБУ ничего не пишем, кроме сброса ошибок (режим 04) по подтверждению пользователя.
- В пакет для ИИ не попадают VIN, время и место записи. Ключи ИИ — только в secure storage,
  не в логах и не в репозитории.
- Anthropic: `anthropic-version: 2026-10-21`, без `temperature`/`top_p`/`top_k` (на этой версии — 400).
