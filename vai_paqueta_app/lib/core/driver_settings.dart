class DriverSettings {
  const DriverSettings._();

  /// Intervalo de envio de ping (WS) quando o WebSocket está conectado.
  static const Duration pingIntervalWs = Duration(seconds: 3);
  /// Intervalo de envio de ping (HTTP) quando não há WS.
  static const Duration pingIntervalHttp = Duration(seconds: 3);
  /// Intervalo de ping (HTTP) no serviço de segundo plano.
  static const Duration backgroundPingInterval = Duration(seconds: 3);
  /// Intervalo de polling de corrida (HTTP) no modo ecotaxista.
  static const Duration corridaPollingInterval = Duration(seconds: 3);

  /// Limite de velocidade (km/h) para disparar aviso.
  static const double speedWarningThresholdKmh = 25.0;
  /// Cooldown mínimo entre avisos de velocidade.
  static const Duration speedWarningCooldown = Duration(seconds: 30);
  /// Tempo para auto-fechar o aviso de velocidade.
  static const Duration speedWarningAutoClose = Duration(seconds: 10);
}

class PassengerSettings {
  const PassengerSettings._();

  /// Intervalo base do polling de corrida (HTTP) no modo passageiro.
  static const Duration corridaPollIntervalBase = Duration(seconds: 3);
  /// Intervalo mínimo do polling (HTTP) quando há backoff.
  static const Duration corridaPollIntervalMin = Duration(seconds: 3);
  /// Intervalo máximo do polling (HTTP) quando há backoff.
  static const Duration corridaPollIntervalMax = Duration(seconds: 10);
  /// Intervalo do polling de motoristas online no mapa.
  static const Duration motoristasOnlinePollingInterval = Duration(seconds: 3);
  /// Tempo mínimo para liberar cancelamento após corrida aceita.
  static const Duration tempoMinimoCancelamentoAposAceite = Duration(minutes: 2);
  /// Tempo mínimo para liberar finalização após corrida iniciada.
  static const Duration tempoMinimoFinalizarAposInicio = Duration(minutes: 3);
  /// Tick dos contadores regressivos (cancelar/finalizar).
  static const Duration countdownTick = Duration(seconds: 1);
  /// Debounce das sugestões de endereço.
  static const Duration suggestionDebounce = Duration(milliseconds: 300);
}

class NetworkSettings {
  const NetworkSettings._();

  /// Timeout de conexão (HTTP).
  static const Duration connectTimeout = Duration(seconds: 10);
  /// Timeout de leitura (HTTP).
  static const Duration receiveTimeout = Duration(seconds: 15);
}

class RealtimeSettings {
  const RealtimeSettings._();

  /// Tempo máximo para receber handshake (WS).
  static const Duration handshakeTimeout = Duration(seconds: 6);
  /// Base do backoff de reconexão (WS) em segundos.
  static const int reconnectBaseSeconds = 2;
  /// Incremento do backoff por tentativa (WS) em segundos.
  static const int reconnectStepSeconds = 2;
  /// Limite máximo do backoff de reconexão (WS) em segundos.
  static const int reconnectMaxSeconds = 30;
}

class UiTimings {
  const UiTimings._();

  /// Duração padrão de transição dos modais.
  static const Duration modalTransition = Duration(milliseconds: 200);
  /// Pausa curta entre passos do coach mark.
  static const Duration coachMarkStepDelay = Duration(milliseconds: 50);
  /// Duração da animação de scroll no coach mark.
  static const Duration coachMarkScrollDuration = Duration(milliseconds: 250);
}
