# scanAuto

Сканер OBD-II для Android: подключается к адаптеру ELM327, показывает живые данные двигателя
и коды неисправностей, записывает поездку и отдаёт графики на разбор языковой модели —
любой, по API пользователя (Claude, YandexGPT, OpenAI, DeepSeek, OpenRouter, локальная Ollama).

Статус: этап 0, программа диагностики, Bluetooth. Работают Bluetooth Classic, Wi-Fi и симулятор, живые данные,
график, чтение и сброс ошибок, программа «прогрев → город → трасса» с профилем машины и
разбор записи моделью по ключу пользователя.

## Структура

```
apps/mobile/          Flutter-приложение (Android)
packages/scan_core/   чистый Dart: ELM327, PID и коды, симулятор, запись, пакет и клиент ИИ
docs/                 архитектура, протокол, ИИ и MCP, план этапов
```

## Запуск

```bash
flutter pub get
```

```bash
cd apps/mobile && flutter run
```

На стартовом экране — «Симулятор»: машина не нужна, сценарий «Подсос воздуха» даёт ошибку P0171
и характерные топливные коррекции.

Wi-Fi путь без машины — симулятор адаптера на ПК; в приложении «Wi-Fi адаптер», адрес
10.0.2.2 в эмуляторе или IP компьютера для телефона в той же сети:

```bash
cd packages/scan_core && dart run scan_core:sim_server --scenario vacuumLeak
```

Тесты ядра и приложения:

```bash
cd packages/scan_core && dart test
```

```bash
cd apps/mobile && flutter test
```

Разбор записи симулятора моделью прямо на ПК — для подбора промпта и модели
(подробности в [docs/ai.md](docs/ai.md#5-проверка-на-пк)):

```bash
cd packages/scan_core && dart run scan_core:demo --scenario vacuumLeak
```

## Документы

- [Архитектура и решения](docs/architecture.md)
- [ELM327 и OBD-II: что важно знать](docs/obd.md)
- [ИИ: провайдеры, что уходит в модель, MCP](docs/ai.md)
- [Программа диагностики: прогрев → город → трасса](docs/program.md)
- [Релизы, подпись, журналы сеансов](docs/release.md)
- [План этапов](docs/mvp-plan.md)
