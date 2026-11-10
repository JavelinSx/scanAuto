/// Ядро scanAuto: ELM327 / OBD-II, симулятор, запись, подготовка данных для ИИ.
library;

export 'src/ai/ai_client.dart';
export 'src/ai/prompts.dart';
export 'src/analysis/analysis_packet.dart';
export 'src/analysis/lttb.dart';
export 'src/elm327/ecu_probe.dart';
export 'src/elm327/elm327.dart';
export 'src/elm327/elm_response.dart';
export 'src/hex.dart';
export 'src/obd/dtc.dart';
export 'src/obd/mode06.dart';
export 'src/obd/pids.dart';
export 'src/program/diagnostic_program.dart';
export 'src/program/program_runner.dart';
export 'src/program/simulate_program.dart';
export 'src/program/vehicle_presets.dart';
export 'src/session/live_sampler.dart';
export 'src/session/recording.dart';
export 'src/simulator/sim_engine.dart';
export 'src/simulator/sim_server.dart';
export 'src/simulator/simulated_elm327.dart';
export 'src/transport/obd_transport.dart';
