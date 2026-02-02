import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/driver_settings.dart';
import '../../core/error_messages.dart';
import '../../core/map_config.dart';
import '../../core/map_viewport.dart';
import '../../widgets/coach_mark.dart';
import '../../services/map_tile_cache_service.dart';
import '../../services/geo_service.dart';
import '../../services/notification_permission_prompt_service.dart';
import '../../services/route_service.dart';
import '../../services/realtime_service.dart';
import '../rides/rides_service.dart';
import '../auth/auth_provider.dart';

class PassengerPage extends ConsumerStatefulWidget {
  const PassengerPage({super.key});

  @override
  ConsumerState<PassengerPage> createState() => _PassengerPageState();
}

class _PassengerPageState extends ConsumerState<PassengerPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _prefsCorridaKey = 'corrida_ativa_id';
  static const _prefsGuiaPassageiroKey = 'passageiro_guia_visto';
  static const _prefsGuiaPassageiroPromptKey = 'passageiro_guia_prompt_visto';
  static const _prefsGuiaModalPassageiroKey = 'passageiro_guia_modal_visto';
  final GlobalKey _guiaMapaKey = GlobalKey();
  final GlobalKey _guiaOrigemKey = GlobalKey();
  final GlobalKey _guiaGpsKey = GlobalKey();
  final GlobalKey _guiaDestinoKey = GlobalKey();
  final GlobalKey _guiaLugaresKey = GlobalKey();
  final GlobalKey _guiaPedirKey = GlobalKey();
  final GlobalKey _guiaConfigKey = GlobalKey();
  final GlobalKey _guiaTrocarKey = GlobalKey();
  final GlobalKey _guiaModalContainerKey = GlobalKey();
  final GlobalKey _guiaModalStatusKey = GlobalKey();
  final GlobalKey _guiaModalMotoristaKey = GlobalKey();
  final GlobalKey _guiaModalRotaKey = GlobalKey();
  final GlobalKey _guiaModalMapaKey = GlobalKey();
  final GlobalKey _guiaModalAcoesKey = GlobalKey();
  final _origemCtrl = TextEditingController();
  final _destinoCtrl = TextEditingController();
  String _origemTextoConfirmado = '';
  String _destinoTextoConfirmado = '';
  LatLng? _origemLatLng;
  LatLng? _destinoLatLng;
  LatLng? _gpsLatLng;
  LatLng? _motoristaLatLng;
  String? _motoristaNome;
  String? _motoristaTelefone;
  String? _origemEnderecoCorrida;
  String? _destinoEnderecoCorrida;
  List<LatLng> _rota = [];
  List<LatLng> _rotaMotorista = [];
  List<LatLng> _rotaGps = [];
  bool _loading = false;
  bool _corridaAtiva = false;
  int? _corridaIdAtual;
  String? _statusCorrida;
  DateTime? _corridaAceitaEm;
  DateTime? _corridaIniciadaEm;
  int _corridaLugares = 1;
  bool _modalAberto = false;
  StateSetter? _modalSetState;
  bool _guiaPassageiroConcluido = false;
  late final AnimationController _guiaPulseController;
  late final Animation<double> _guiaPulseAnim;
  bool _paymentWarningOpen = false;
  int? _paymentWarningRideId;
  bool _tileUsingAssets = MapTileConfig.useAssets;
  String _tileUrl = MapTileConfig.useAssets ? MapTileConfig.assetsTemplate : MapTileConfig.networkTemplate;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  _TileSource? _assetTileSource;
  _TileSource? _networkTileSource;
  bool _usandoFallbackRede = false;
  bool _posCarregada = false;
  int _lugaresSolicitados = 1;
  List<MotoristaProximo> _motoristasOnline = [];
  Timer? _motoristasOnlineTimer;
  bool _carregandoMotoristasOnline = false;
  final GeoService _geo = GeoService();
  final RouteService _routeService = RouteService();
  String? _rotaKey;
  String? _rotaMotoristaKey;
  String? _rotaGpsKey;
  Timer? _debounceOrigem;
  Timer? _debounceDestino;
  bool _trocandoPerfil = false;
  double _round6(double v) => double.parse(v.toStringAsFixed(6));
  Timer? _corridaTimer;
  Timer? _cancelUnlockTimer;
  Timer? _finalUnlockTimer;
  final MapController _mapController = MapController();
  Timer? _mapResetTimer;
  AnimationController? _mapResetAnimation;
  LatLng? _mapDefaultCenter;
  double? _mapDefaultZoom;
  CameraFit? _mapDefaultFit;
  LatLng? _mapLastCenter;
  double? _mapLastZoom;
  bool _mapUserInteracting = false;
  bool _appPausado = false;
  Duration _corridaPollInterval = PassengerSettings.corridaPollIntervalBase;
  RealtimeService? _realtime;
  bool _wsConnected = false;
  int? _wsPerfilId;
  ProviderSubscription<AsyncValue<dynamic>>? _authSub;
  Duration _serverTimeOffset = Duration.zero;
  double _motoristaBearing = 0.0;

  Future<void> _solicitarPermissaoNotificacaoQuandoPronto() async {
    if (!mounted) return;
    if (_modalAberto || _paymentWarningOpen) return;
    await NotificationPermissionPromptService.maybePrompt(context);
  }
  bool get _podeCancelarCorrida {
    if (!_corridaAtiva || _corridaIdAtual == null) return false;
    final status = _normalizarStatus(_statusCorrida);
    if (status == 'aguardando') return true;
    if (status == 'aceita') return !_cancelamentoBloqueado();
    return false;
  }
  bool get _podeFinalizarCorrida {
    if (!_corridaAtiva || _corridaIdAtual == null) return false;
    final status = _normalizarStatus(_statusCorrida);
    if (status != 'em_andamento') return false;
    return !_finalizacaoBloqueada();
  }

  TileProvider _buildTileProvider() {
    return _tileUsingAssets ? AssetTileProvider() : MapTileCacheService.networkTileProvider();
  }

  Widget _buildGpsMarker() {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blueAccent,
        boxShadow: [
          BoxShadow(
            color: Colors.blueAccent.withValues(alpha: 0.99),
            blurRadius: 3,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.lightBlueAccent.withValues(alpha: 0.50),
            blurRadius: 5,
            spreadRadius: 2,
          ),
        ],
      ),
      child: const Center(
        child: Icon(
          Icons.person,
          size: 22,
          color: Colors.white,
        ),
      ),
    );
  }

  int _effectiveMinNativeZoom() {
    if (_tileMinNativeZoom != null) return _tileMinNativeZoom!;
    return _tileUsingAssets ? MapTileConfig.assetsMinZoom : MapTileConfig.passengerMinZoom;
  }

  int _effectiveMaxNativeZoom() {
    if (_tileMaxNativeZoom != null) return _tileMaxNativeZoom!;
    return _tileUsingAssets ? MapTileConfig.assetsMaxZoom : MapTileConfig.passengerMaxZoom;
  }

  double _effectiveMinZoom() {
    return math.min(
      MapTileConfig.displayMinZoom.toDouble(),
      _effectiveMinNativeZoom().toDouble(),
    );
  }

  double _effectiveMaxZoom() {
    return _effectiveMaxNativeZoom().toDouble();
  }

  String _normalizarStatus(String? status) {
    final raw = (status ?? '').trim().toLowerCase();
    if (raw.isEmpty) return '';
    final normalized = raw.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    if (normalized == 'aguardando_motorista') return 'aguardando';
    return normalized;
  }

  String _statusLabel(String? status) {
    switch (_normalizarStatus(status)) {
      case 'aguardando':
        return 'Aguardando motorista';
      case 'aceita':
        return 'Motorista aceitou';
      case 'em_andamento':
        return 'Em andamento';
      case 'concluida':
        return 'Concluída';
      case 'cancelada':
        return 'Cancelada';
      case 'rejeitada':
        return 'Rejeitada';
      default:
        return status?.trim().isNotEmpty == true ? status!.trim() : 'Aguardando motorista';
    }
  }

  String _statusHint(String? status) {
    switch (_normalizarStatus(status)) {
      case 'aguardando':
        return 'Aguardando confirmação do motorista.';
      case 'aceita':
        return 'Motorista confirmado. A caminho da origem.';
      case 'em_andamento':
        return 'Corrida em andamento.';
      default:
        return 'Status atualizado.';
    }
  }

  String _formatarLugares(int lugares) {
    return lugares == 1 ? '1 assento' : '$lugares assentos';
  }

  bool _mostrarMotoristaNoMapa() {
    final status = _normalizarStatus(_statusCorrida);
    return status == 'aceita' || status == 'em_andamento';
  }

  bool _podeMostrarMotoristasOnline() {
    if (!_corridaAtiva) return true;
    return !_mostrarMotoristaNoMapa();
  }

  void _sincronizarMotoristasOnline() {
    if (_podeMostrarMotoristasOnline()) {
      _iniciarMotoristasOnlinePolling();
    } else {
      _pararMotoristasOnlinePolling(limpar: true);
    }
  }

  DateTime _nowServer() {
    return DateTime.now().add(_serverTimeOffset);
  }

  void _atualizarServerOffset(DateTime? serverTime) {
    if (serverTime == null) return;
    _serverTimeOffset = serverTime.difference(DateTime.now());
  }

  Duration? _tempoRestanteCancelamento() {
    if (_normalizarStatus(_statusCorrida) != 'aceita') return null;
    if (_corridaAceitaEm == null) return PassengerSettings.tempoMinimoCancelamentoAposAceite;
    final elapsed = _nowServer().difference(_corridaAceitaEm!);
    final remaining = PassengerSettings.tempoMinimoCancelamentoAposAceite - elapsed;
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining;
  }

  Duration? _tempoRestanteFinalizacao() {
    if (_normalizarStatus(_statusCorrida) != 'em_andamento') return null;
    if (_corridaIniciadaEm == null) return PassengerSettings.tempoMinimoFinalizarAposInicio;
    final elapsed = _nowServer().difference(_corridaIniciadaEm!);
    final remaining = PassengerSettings.tempoMinimoFinalizarAposInicio - elapsed;
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining;
  }

  bool _cancelamentoBloqueado() {
    final remaining = _tempoRestanteCancelamento();
    return remaining != null && remaining > Duration.zero;
  }

  bool _finalizacaoBloqueada() {
    final remaining = _tempoRestanteFinalizacao();
    return remaining != null && remaining > Duration.zero;
  }

  double _cancelamentoProgresso(Duration remaining) {
    final totalSeconds = PassengerSettings.tempoMinimoCancelamentoAposAceite.inSeconds;
    if (totalSeconds <= 0) return 1;
    final elapsed = (totalSeconds - remaining.inSeconds).clamp(0, totalSeconds);
    return elapsed / totalSeconds;
  }

  double _finalizacaoProgresso(Duration remaining) {
    final totalSeconds = PassengerSettings.tempoMinimoFinalizarAposInicio.inSeconds;
    if (totalSeconds <= 0) return 1;
    final elapsed = (totalSeconds - remaining.inSeconds).clamp(0, totalSeconds);
    return elapsed / totalSeconds;
  }

  String _formatTempoRestante(Duration remaining) {
    final totalSeconds = remaining.inSeconds.clamp(0, 3600);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _gerenciarTimerCancelamento() {
    _cancelUnlockTimer?.cancel();
    final remaining = _tempoRestanteCancelamento();
    if (remaining == null || remaining <= Duration.zero) return;
    _cancelUnlockTimer = Timer.periodic(PassengerSettings.countdownTick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final pending = _tempoRestanteCancelamento();
      if (pending == null || pending <= Duration.zero) {
        timer.cancel();
      }
      setState(() {});
      _modalSetState?.call(() {});
    });
  }

  void _gerenciarTimerFinalizacao() {
    _finalUnlockTimer?.cancel();
    final remaining = _tempoRestanteFinalizacao();
    if (remaining == null || remaining <= Duration.zero) return;
    _finalUnlockTimer = Timer.periodic(PassengerSettings.countdownTick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final pending = _tempoRestanteFinalizacao();
      if (pending == null || pending <= Duration.zero) {
        timer.cancel();
      }
      setState(() {});
      _modalSetState?.call(() {});
    });
  }

  String? _formatLatLng(LatLng? pos) {
    if (pos == null) return null;
    return '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}';
  }

  Future<bool> _mostrarConsentimentoLocalizacao() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Permitir localização'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Para definir sua origem automaticamente e mostrar sua posição no mapa, '
                'o Vai Paquetá precisa acessar sua localização enquanto o app estiver aberto.',
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.gps_fixed, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Preenche o endereço de origem com o GPS.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.edit_location_alt_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Se preferir, você pode digitar o endereço manualmente.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Concordo e continuar'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  void _limparRotaCorrida() {
    if (_rota.isEmpty && _rotaKey == null) return;
    if (!mounted) {
      _rota = [];
      _rotaKey = null;
      return;
    }
    setState(() {
      _rota = [];
      _rotaKey = null;
    });
    _atualizarDefaultMapaPrincipal(forcar: true);
  }

  void _limparRotaGps() {
    if (_rotaGps.isEmpty && _rotaGpsKey == null) return;
    if (!mounted) {
      _rotaGps = [];
      _rotaGpsKey = null;
      return;
    }
    setState(() {
      _rotaGps = [];
      _rotaGpsKey = null;
    });
  }

  Future<void> _carregarRotaGps(LatLng gps, LatLng origem) async {
    final key = 'gps-${_buildRouteKey(gps, origem)}';
    if (_rotaGpsKey == key) return;
    _rotaGpsKey = key;
    final rota = await _fetchRoute(gps, origem);
    if (!mounted) return;
    setState(() => _rotaGps = rota);
    _modalSetState?.call(() {});
  }

  Future<void> _atualizarRotaGpsSePossivel() async {
    if (_corridaAtiva) return;
    final gps = _gpsLatLng;
    final origem = _origemLatLng;
    if (gps == null || origem == null) {
      _limparRotaGps();
      return;
    }
    await _carregarRotaGps(gps, origem);
  }

  Future<void> _atualizarRotaSePossivel() async {
    if (_corridaAtiva) return;
    await _atualizarRotaGpsSePossivel();
    final origem = _origemLatLng;
    final destino = _destinoLatLng;
    if (origem == null || destino == null) {
      _limparRotaCorrida();
      _atualizarDefaultMapaPrincipal(forcar: true);
      return;
    }
    _atualizarDefaultMapaPrincipal(forcar: true);
    await _carregarRotaCorrida(origem, destino);
    _atualizarDefaultMapaPrincipal(forcar: true);
  }

  Future<void> _confirmarOrigemDigitada() async {
    if (_corridaAtiva) return;
    final texto = _origemCtrl.text.trim();
    if (texto.isEmpty) {
      if (!mounted) {
        _origemLatLng = null;
        _origemTextoConfirmado = '';
        _limparRotaCorrida();
        _limparRotaGps();
        return;
      }
      setState(() {
        _origemLatLng = null;
        _origemTextoConfirmado = '';
      });
      _limparRotaCorrida();
      _limparRotaGps();
      return;
    }
    if (_origemLatLng != null && texto == _origemTextoConfirmado) {
      await _atualizarRotaSePossivel();
      return;
    }
    try {
      final res = await _geo.forward(texto);
      if (!mounted) return;

      final isOriginOk = await _geo.isInsideServiceArea(res.lat, res.lng);
      if (!isOriginOk) {
        _showErrorSnackbar('O endereço de origem está fora da área de serviço.');
        setState(() {
          _origemLatLng = null;
        });
        _limparRotaGps();
        return;
      }

      setState(() {
        _origemLatLng = LatLng(res.lat, res.lng);
        _origemCtrl.text = res.endereco;
        _origemCtrl.selection = TextSelection.collapsed(offset: _origemCtrl.text.length); // Add this line
      });
      _origemTextoConfirmado = _origemCtrl.text.trim();
      await _avaliarTilesPara(_origemLatLng);
      await _atualizarRotaSePossivel();
    } catch (e) {
      _showErrorSnackbar('Erro ao localizar origem: ${friendlyError(e)}');
    }
  }

  Future<void> _confirmarDestinoDigitado() async {
    if (_corridaAtiva) return;
    final texto = _destinoCtrl.text.trim();
    if (texto.isEmpty) {
      if (!mounted) {
        _destinoLatLng = null;
        _destinoTextoConfirmado = '';
        _limparRotaCorrida();
        return;
      }
      setState(() {
        _destinoLatLng = null;
        _destinoTextoConfirmado = '';
      });
      _limparRotaCorrida();
      return;
    }
    if (_destinoLatLng != null && texto == _destinoTextoConfirmado) {
      await _atualizarRotaSePossivel();
      return;
    }
    try {
      final res = await _geo.forward(texto);
      if (!mounted) return;

      final isDestOk = await _geo.isInsideServiceArea(res.lat, res.lng);
      if (!isDestOk) {
        _showErrorSnackbar('O endereço de destino está fora da área de serviço.');
        setState(() {
          _destinoLatLng = null;
        });
        return;
      }

      setState(() {
        _destinoLatLng = LatLng(res.lat, res.lng);
        _destinoCtrl.text = res.endereco;
        _destinoCtrl.selection = TextSelection.collapsed(offset: _destinoCtrl.text.length); // Add this line
      });
      _destinoTextoConfirmado = _destinoCtrl.text.trim();
      await _avaliarTilesPara(_destinoLatLng);
      await _atualizarRotaSePossivel();
    } catch (e) {
      _showErrorSnackbar('Erro ao localizar destino: ${friendlyError(e)}');
    }
  }

  String? _buildWhatsAppLink(String? telefone) {
    final raw = (telefone ?? '').trim();
    final digits = raw.replaceAll(RegExp(r'\D+'), '');
    if (digits.isEmpty) return null;
    var normalized = digits;
    if (!raw.startsWith('+') && digits.length <= 11 && !digits.startsWith('55')) {
      normalized = '55$digits';
    }
    if (normalized.length < 8 || normalized.length > 15) return null;
    return 'https://wa.me/$normalized';
  }

  Future<void> _abrirWhatsApp(String? telefone) async {
    final link = _buildWhatsAppLink(telefone);
    if (link == null) return;
    final uri = Uri.parse(link);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      debugPrint('Não foi possível abrir o WhatsApp.');
    }
  }

  void _encerrarCorrida({bool limparEnderecos = false}) {
    _corridaAtiva = false;
    _corridaIdAtual = null;
    _statusCorrida = null;
    _corridaAceitaEm = null;
    _corridaIniciadaEm = null;
    _corridaLugares = 1;
    _motoristaLatLng = null;
    _motoristaNome = null;
    _motoristaTelefone = null;
    _origemEnderecoCorrida = null;
    _destinoEnderecoCorrida = null;
    _rotaMotorista = [];
    _rota = [];
    _rotaKey = null;
    _rotaMotoristaKey = null;
    _rotaGps = [];
    _rotaGpsKey = null;
    _lugaresSolicitados = 1;
    _motoristasOnline = [];
    _motoristasOnlineTimer?.cancel();
    if (limparEnderecos) {
      _origemCtrl.clear();
      _destinoCtrl.clear();
      _origemTextoConfirmado = '';
      _destinoTextoConfirmado = '';
      _origemLatLng = null;
      _destinoLatLng = null;
    }
    _salvarCorridaLocal(null);
    _corridaTimer?.cancel();
    _cancelUnlockTimer?.cancel();
    _finalUnlockTimer?.cancel();
    _fecharModalCorrida();
    _sincronizarMotoristasOnline();
  }

  List<LatLng> _pinsMapaPrincipal() {
    if (_rota.length >= 2) {
      final pins = List<LatLng>.from(_rota);
      if (_motoristaLatLng != null && _mostrarMotoristaNoMapa()) {
        pins.add(_motoristaLatLng!);
      }
      return pins;
    }
    final motorista = _mostrarMotoristaNoMapa() ? _motoristaLatLng : null;
    return MapViewport.collectPins([_origemLatLng, _destinoLatLng, motorista]);
  }

  List<LatLng> _pinsMapaModal() {
    if (_rota.length >= 2) {
      final pins = List<LatLng>.from(_rota);
      final motorista = _mostrarMotoristaNoMapa() ? _motoristaLatLng : null;
      if (motorista != null) {
        pins.add(motorista);
      }
      return pins;
    }
    final motorista = _mostrarMotoristaNoMapa() ? _motoristaLatLng : null;
    return MapViewport.collectPins([_origemLatLng, _destinoLatLng, motorista]);
  }

  void _atualizarDefaultMapaPrincipal({bool forcar = false}) {
    final bounds = MapTileConfig.tilesBounds;
    final rawPins = _pinsMapaPrincipal();
    final pins = rawPins.isEmpty ? rawPins : MapViewport.clampPinsToBounds(rawPins, bounds);
    final center = MapViewport.clampCenter(MapViewport.centerForPins(pins), bounds);
    final minZoom = _effectiveMinZoom();
    final maxZoom = _effectiveMaxZoom();
    final zoom = MapViewport.zoomForPins(
      pins,
      minZoom: minZoom,
      maxZoom: maxZoom,
      fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
    );
    final fitBounds = MapViewport.boundsForPins(pins);
    final fit = fitBounds == null
        ? null
        : CameraFit.bounds(
            bounds: fitBounds,
            padding: const EdgeInsets.all(24),
            minZoom: minZoom,
            maxZoom: maxZoom,
          );

    final prevCenter = _mapDefaultCenter;
    final prevZoom = _mapDefaultZoom;
    _mapDefaultCenter = center;
    _mapDefaultZoom = zoom;
    _mapDefaultFit = fit;

    final mudou = prevCenter == null ||
        prevZoom == null ||
        prevCenter.latitude != center.latitude ||
        prevCenter.longitude != center.longitude ||
        prevZoom != zoom;
    if (forcar) {
      _mapUserInteracting = false;
      _stopMapAnimation();
    }
    if ((mudou || forcar) && !_mapUserInteracting && _mapResetAnimation == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _mapUserInteracting || _mapResetAnimation != null) return;
        if (_mapDefaultFit != null) {
          try {
            final fitted = _mapDefaultFit!.fit(_mapController.camera);
            _animateMapMove(fitted.center, fitted.zoom);
            return;
          } catch (_) {
            // ignora e usa fallback
          }
        }
        _animateMapMove(center, zoom);
      });
    }
  }

  void _scheduleMapReset() {
    _mapUserInteracting = true;
    _mapResetTimer?.cancel();
    _mapResetTimer = Timer(const Duration(seconds: 5), _resetMapToDefault);
  }

  void _resetMapToDefault() {
    if (!mounted) return;
    final center = _mapDefaultCenter;
    final zoom = _mapDefaultZoom;
    if (center == null || zoom == null) return;
    _mapUserInteracting = false;
    if (_mapDefaultFit != null) {
      try {
        final fitted = _mapDefaultFit!.fit(_mapController.camera);
        _animateMapMove(fitted.center, fitted.zoom);
        return;
      } catch (_) {
        // ignora e usa fallback
      }
    }
    _animateMapMove(center, zoom);
  }

  void _stopMapAnimation() {
    final controller = _mapResetAnimation;
    if (controller == null) return;
    controller.stop();
    controller.dispose();
    _mapResetAnimation = null;
  }

  void _animateMapMove(LatLng destCenter, double destZoom) {
    final startCenter = _mapLastCenter ?? destCenter;
    final startZoom = _mapLastZoom ?? destZoom;
    _stopMapAnimation();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _mapResetAnimation = controller;
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
    final latTween = Tween<double>(begin: startCenter.latitude, end: destCenter.latitude);
    final lngTween = Tween<double>(begin: startCenter.longitude, end: destCenter.longitude);
    final zoomTween = Tween<double>(begin: startZoom, end: destZoom);

    controller.addListener(() {
      final lat = latTween.evaluate(curved);
      final lng = lngTween.evaluate(curved);
      final zoom = zoomTween.evaluate(curved);
      _mapController.move(LatLng(lat, lng), zoom);
    });
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        controller.dispose();
        if (_mapResetAnimation == controller) {
          _mapResetAnimation = null;
        }
      }
    });
    controller.forward();
  }

  void _fecharModalCorrida() {
    if (!_modalAberto || !mounted) return;
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    _modalAberto = false;
    _modalSetState = null;
  }

  void _sincronizarModalCorrida() {
    if (!_corridaAtiva || _corridaIdAtual == null) return;
    if (_motoristaLatLng != null) {
      _atualizarRotaMotorista(_statusCorrida);
    }
    if (_modalAberto) {
      _modalSetState?.call(() {});
      return;
    }
    _mostrarModalCorrida();
  }

  Future<void> _mostrarAvisoPagamento({int? rideId}) async {
    if (!mounted) return;
    if (_paymentWarningOpen) return;
    if (rideId != null && _paymentWarningRideId == rideId) return;
    _paymentWarningOpen = true;
    _paymentWarningRideId = rideId;
    FocusScope.of(context).unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) {
      _paymentWarningOpen = false;
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (context) {
          return AlertDialog(
            title: const Text('Aviso sobre pagamento'),
            content: const Text(
              'O pagamento deve ser combinado diretamente entre passageiro e eco-taxista. O app apenas conecta vocês.',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Entendi'),
              ),
            ],
          );
        },
      );
    } finally {
      _paymentWarningOpen = false;
    }
  }

  Future<void> _mostrarGuiaPassageiroSeNecessario() async {
    final prefs = await SharedPreferences.getInstance();
    final promptVisto = prefs.getBool(_prefsGuiaPassageiroPromptKey) ?? false;
    if (promptVisto || !mounted) return;
    if (_modalAberto || _paymentWarningOpen) return;
    final verGuia = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Conheça o app'),
          content: const Text('Quer ver um guia rápido do modo Passageiro?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Conhecer agora'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (verGuia == true) {
      await _mostrarGuiaPassageiro();
    }
    await prefs.setBool(_prefsGuiaPassageiroPromptKey, true);
  }

  Future<void> _mostrarGuiaPassageiroManual() async {
    if (!mounted) return;
    if (_modalAberto || _paymentWarningOpen) return;
    final verGuia = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Guia interativo'),
          content: const Text('Quer iniciar o guia do modo Passageiro?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Iniciar guia'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (verGuia == true) {
      await _mostrarGuiaPassageiro();
    }
  }

  Future<void> _carregarEstadoGuiaPassageiro() async {
    final prefs = await SharedPreferences.getInstance();
    final concluido = prefs.getBool(_prefsGuiaPassageiroKey) ?? false;
    if (!mounted) return;
    setState(() => _guiaPassageiroConcluido = concluido);
    _atualizarGuiaPulse();
  }

  Future<void> _marcarGuiaPassageiroConcluido() async {
    if (!mounted) return;
    setState(() => _guiaPassageiroConcluido = true);
    _atualizarGuiaPulse();
  }

  void _atualizarGuiaPulse() {
    if (_guiaPassageiroConcluido) {
      _guiaPulseController.stop();
      _guiaPulseController.value = 0.0;
    } else if (!_guiaPulseController.isAnimating) {
      _guiaPulseController.repeat(reverse: true);
    }
  }

  Widget _buildGuiaIconButton({required VoidCallback onPressed}) {
    final button = IconButton(
      tooltip: 'Guia interativo',
      icon: const Icon(Icons.help_outline),
      onPressed: onPressed,
    );
    if (_guiaPassageiroConcluido) return button;
    return AnimatedBuilder(
      animation: _guiaPulseAnim,
      child: button,
      builder: (context, child) {
        final t = _guiaPulseAnim.value;
        final glow = 0.15 + 0.25 * t;
        final scale = 1.0 + 0.03 * t;
        return Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.amberAccent.withValues(alpha: 0.7 * glow),
                  blurRadius: 4 + 4 * glow,
                  spreadRadius: 0.2 + 0.6 * glow,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _mostrarGuiaPassageiro() async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    final concluido = await showCoachMarks(context, [
      CoachMarkStep(
        targetKey: _guiaConfigKey,
        title: 'Configurações',
        description: 'Edite seus dados do perfil e encontre o botão Sair.',
      ),
      CoachMarkStep(
        targetKey: _guiaTrocarKey,
        title: 'Trocar perfil',
        description: 'Mude para o modo Ecotaxista.',
      ),
      CoachMarkStep(
        targetKey: _guiaMapaKey,
        title: 'Mapa',
        description: 'Mostra origem, destino e o motorista quando a corrida é aceita.',
      ),
      CoachMarkStep(
        targetKey: _guiaOrigemKey,
        title: 'Origem',
        description: 'Informe de onde você vai sair.',
      ),
      CoachMarkStep(
        targetKey: _guiaGpsKey,
        title: 'GPS',
        description: 'Usa sua localização atual como origem.',
        highlightPadding: const EdgeInsets.all(6),
      ),
      CoachMarkStep(
        targetKey: _guiaDestinoKey,
        title: 'Destino',
        description: 'Informe para onde você vai.',
      ),
      CoachMarkStep(
        targetKey: _guiaLugaresKey,
        title: 'Assentos',
        description: 'Escolha 1 ou 2 assentos para a corrida.',
      ),
      CoachMarkStep(
        targetKey: _guiaPedirKey,
        title: 'Pedir corrida',
        description:
            'Envia sua solicitação. Depois pode virar Cancelar ou Finalizar quando permitido.',
      ),
    ]);
    if (!concluido || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsGuiaPassageiroKey, true);
    await _marcarGuiaPassageiroConcluido();
    await _mostrarGuiaModalPassageiro();
  }

  List<CoachMarkStep> _buildGuiaModalPassageiroSteps() {
    return [
      CoachMarkStep(
        targetKey: _guiaModalContainerKey,
        title: 'Modal da corrida',
        description:
            'Quando você pede uma corrida, este modal aparece para acompanhar o status e a rota.',
        highlightPadding: const EdgeInsets.all(12),
        borderRadius: 16,
        bubblePlacement: CoachMarkBubblePlacement.center,
      ),
      CoachMarkStep(
        targetKey: _guiaModalStatusKey,
        title: 'Status da corrida',
        description: 'Mostra se está aguardando, aceita ou em andamento.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalMotoristaKey,
        title: 'Motorista',
        description: 'Quando a corrida é aceita, aparecem nome, telefone e WhatsApp.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalRotaKey,
        title: 'Rota',
        description: 'Confira origem, destino e quantidade de assentos.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalMapaKey,
        title: 'Mapa da corrida',
        description: 'Mostra sua posição, origem, destino e o motorista quando disponível.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalAcoesKey,
        title: 'Ações',
        description: 'Aqui você pode cancelar ou finalizar quando permitido.',
      ),
    ];
  }

  Future<void> _mostrarGuiaModalPassageiro() async {
    if (!mounted || _modalAberto || _paymentWarningOpen) return;
    final snapshot = _PassengerModalSnapshot.fromState(this);
    final baseLat = _origemLatLng?.latitude ?? MapTileConfig.defaultCenterLat;
    final baseLng = _origemLatLng?.longitude ?? MapTileConfig.defaultCenterLng;
    final origem = LatLng(baseLat + 0.0011, baseLng + 0.0010);
    final destino = LatLng(baseLat - 0.0012, baseLng - 0.0014);
    setState(() {
      _corridaAtiva = true;
      _corridaIdAtual = -1;
      _statusCorrida = 'aguardando';
      _corridaLugares = 1;
      _corridaAceitaEm = null;
      _corridaIniciadaEm = null;
      _motoristaNome = 'Motorista Exemplo';
      _motoristaTelefone = '(21) 99999-0000';
      _origemEnderecoCorrida = 'Praia José Bonifácio, Paquetá';
      _destinoEnderecoCorrida = 'Cais da Barca, Paquetá';
      _origemLatLng = origem;
      _destinoLatLng = destino;
      _motoristaLatLng = null;
      _motoristaBearing = 0.0;
      _rota = [origem, destino];
      _rotaKey = 'guia-modal';
      _rotaMotorista = [];
      _rotaMotoristaKey = null;
      if (_origemCtrl.text.trim().isEmpty) {
        _origemCtrl.text = _origemEnderecoCorrida!;
      }
      if (_destinoCtrl.text.trim().isEmpty) {
        _destinoCtrl.text = _destinoEnderecoCorrida!;
      }
    });
    try {
      await _mostrarModalCorrida(iniciarGuia: true);
    } finally {
      if (mounted) {
        setState(() => snapshot.restore(this));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _guiaPulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _guiaPulseAnim = CurvedAnimation(parent: _guiaPulseController, curve: Curves.easeInOut);
    _carregarEstadoGuiaPassageiro();
    _configurarFonteTiles();
    _carregarCorridaAtiva();
    _carregarPosicao();
    _iniciarMotoristasOnlinePolling();
    _configurarRealtime();
    _authSub = ref.listenManual(authProvider, (_, __) {
      if (!mounted) return;
      _configurarRealtime();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(() async {
        await _mostrarGuiaPassageiroSeNecessario();
        if (!mounted) return;
        await _solicitarPermissaoNotificacaoQuandoPronto();
      }());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _guiaPulseController.dispose();
    _origemCtrl.dispose();
    _destinoCtrl.dispose();
    _debounceOrigem?.cancel();
    _debounceDestino?.cancel();
    _corridaTimer?.cancel();
    _cancelUnlockTimer?.cancel();
    _finalUnlockTimer?.cancel();
    _motoristasOnlineTimer?.cancel();
    _mapResetTimer?.cancel();
    _mapResetAnimation?.dispose();
    _authSub?.close();
    _stopRealtime();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _appPausado = true;
      _corridaTimer?.cancel();
      _cancelUnlockTimer?.cancel();
      _finalUnlockTimer?.cancel();
      _motoristasOnlineTimer?.cancel();
      _mapResetTimer?.cancel();
      _stopMapAnimation();
      _mapUserInteracting = false;
    } else if (state == AppLifecycleState.resumed && _appPausado) {
      _appPausado = false;
      if (_corridaIdAtual != null) {
        if (_wsConnected) {
          _realtime?.sendSync();
        } else {
          _atualizarCorridaAtiva();
          _iniciarPollingCorrida();
        }
      }
      _gerenciarTimerCancelamento();
      _sincronizarMotoristasOnline();
      unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () async {
        await _solicitarPermissaoNotificacaoQuandoPronto();
      }));
    }
  }

  Future<void> _configurarFonteTiles() async {
    final networkSource = _buildNetworkSource();
    final source = await _resolverFonteTiles();
    if (!mounted) return;

    if (MapTileConfig.useAssets) {
      _assetTileSource = source;
      _networkTileSource = networkSource;
      _applyTileSource(source, usandoFallback: false);
    } else {
      _networkTileSource = networkSource;
      _applyTileSource(networkSource, usandoFallback: false);
    }
    final referencia = _origemLatLng ??
        _destinoLatLng ??
        const LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
    await _avaliarTilesPara(referencia);
  }

  String _buildRouteKey(LatLng start, LatLng end) {
    return '${start.latitude.toStringAsFixed(6)},${start.longitude.toStringAsFixed(6)}'
        '|${end.latitude.toStringAsFixed(6)},${end.longitude.toStringAsFixed(6)}';
  }

  Future<List<LatLng>> _fetchRoute(LatLng start, LatLng end) async {
    return _routeService.fetchRoute(start: start, end: end);
  }

  Future<void> _carregarRotaCorrida(LatLng origem, LatLng destino) async {
    final key = _buildRouteKey(origem, destino);
    if (_rotaKey == key) return;
    _rotaKey = key;
    final rota = await _fetchRoute(origem, destino);
    if (!mounted) return;
    setState(() => _rota = rota);
    _modalSetState?.call(() {});
    _atualizarDefaultMapaPrincipal(forcar: true);
  }

  Future<void> _carregarRotaMotorista(LatLng start, LatLng end) async {
    final key = _buildRouteKey(start, end);
    if (_rotaMotoristaKey == key) return;
    _rotaMotoristaKey = key;
    final rota = await _fetchRoute(start, end);
    if (!mounted) return;
    setState(() => _rotaMotorista = rota);
    _modalSetState?.call(() {});
  }

  _TileSource _buildNetworkSource() {
    return _TileSource(
      template: MapTileConfig.networkTemplate,
      usingAssets: false,
      minNativeZoom: MapTileConfig.passengerMinZoom,
      maxNativeZoom: MapTileConfig.passengerMaxZoom,
    );
  }

  void _applyTileSource(_TileSource source, {required bool usandoFallback}) {
    if (!mounted) {
      _tileUsingAssets = source.usingAssets;
      _tileUrl = source.template;
      _tileMinNativeZoom = source.minNativeZoom;
      _tileMaxNativeZoom = source.maxNativeZoom;
      _usandoFallbackRede = usandoFallback;
      return;
    }
    setState(() {
      _tileUsingAssets = source.usingAssets;
      _tileUrl = source.template;
      _tileMinNativeZoom = source.minNativeZoom;
      _tileMaxNativeZoom = source.maxNativeZoom;
      _usandoFallbackRede = usandoFallback;
    });
  }

  Future<_TileSource> _resolverFonteTiles() async {
    if (MapTileConfig.useAssets) {
      final manifest = await _carregarManifesto();
      final assetZooms = _extrairZooms(manifest);
      final minZoom = assetZooms.isNotEmpty ? assetZooms.reduce(math.min) : MapTileConfig.assetsMinZoom;
      final maxZoom = assetZooms.isNotEmpty ? assetZooms.reduce(math.max) : MapTileConfig.assetsMaxZoom;
      return _TileSource(
        template: MapTileConfig.assetsTemplate,
        usingAssets: true,
        minZoom: minZoom.toDouble(),
        maxZoom: maxZoom.toDouble(),
        minNativeZoom: minZoom,
        maxNativeZoom: maxZoom,
      );
    }

    return _TileSource(
      template: MapTileConfig.networkTemplate,
      usingAssets: false,
    );
  }

  Future<bool> _tileLocalDisponivel(LatLng pos) async {
    final path = MapTileConfig.assetPathForLatLng(
      lat: pos.latitude,
      lng: pos.longitude,
      zoom: MapTileConfig.assetsSampleZoom,
    );
    try {
      await rootBundle.load(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _avaliarTilesPara(LatLng? pos) async {
    if (!MapTileConfig.useAssets || pos == null) return;
    final ok = await _tileLocalDisponivel(pos);
    if (!mounted) return;
    if (ok) {
      if (_usandoFallbackRede && _assetTileSource != null) {
        _applyTileSource(_assetTileSource!, usandoFallback: false);
      }
      return;
    }
    if (MapTileConfig.allowNetworkFallback && _networkTileSource != null) {
      _applyTileSource(_networkTileSource!, usandoFallback: true);
      return;
    }
  }

  Future<Map<String, dynamic>?> _carregarManifesto() async {
    try {
      final jsonStr = await rootBundle.loadString('AssetManifest.json');
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      return data;
    } catch (_) {
      return null;
    }
  }

  Set<int> _extrairZooms(Map<String, dynamic>? manifest) {
    if (manifest == null || manifest.isEmpty) return const {};
    final zooms = <int>{};
    for (final entry in manifest.keys) {
      if (!entry.startsWith(MapTileConfig.assetsPrefix) || !entry.endsWith('.png')) continue;
      final parts = entry.split('/');
      if (parts.length < 4) continue;
      final zoom = int.tryParse(parts[2]);
      if (zoom != null) zooms.add(zoom);
    }
    return zooms;
  }

  Future<Iterable<GeoResult>> _buscarSugestoesOrigem(String texto) async {
    final q = texto.trim();
    if (q.isEmpty) {
      return const Iterable<GeoResult>.empty();
    }
    final referencia = _origemLatLng ?? _destinoLatLng ?? const LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
    try {
      final resultados = await _geo.searchNearby(
        query: q,
        lat: referencia.latitude,
        lng: referencia.longitude,
        limit: 3,
      );
      return resultados.take(3);
    } catch (e) {
      debugPrint('Erro ao buscar sugestoes de origem: ${friendlyError(e)}');
      return const Iterable<GeoResult>.empty();
    }
  }

  Future<Iterable<GeoResult>> _buscarSugestoesDestino(String texto) async {
    final q = texto.trim();
    if (q.isEmpty) {
      return const Iterable<GeoResult>.empty();
    }
    final referencia = _destinoLatLng ?? _origemLatLng ?? const LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
    try {
      final resultados = await _geo.searchNearby(
        query: q,
        lat: referencia.latitude,
        lng: referencia.longitude,
        limit: 3,
      );
      return resultados.take(3);
    } catch (e) {
      debugPrint('Erro ao buscar sugestoes de destino: ${friendlyError(e)}');
      return const Iterable<GeoResult>.empty();
    }
  }

  Future<void> _carregarPosicao() async {
    if (_posCarregada) return;
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return;
    }
    await _usarGPS(silencioso: true);
  }

  Future<void> _carregarCorridaAtiva() async {
    try {
      final user = ref.read(authProvider).valueOrNull;
      final perfilId = user?.perfilId ?? 0;
      if (perfilId == 0) return;
      final prefs = await SharedPreferences.getInstance();
      final corridaSalva = prefs.getInt(_prefsCorridaKey);
      final rides = RidesService();
      CorridaResumo? corrida;
      if (corridaSalva != null) {
        corrida = await rides.obterCorrida(corridaSalva);
      }
      corrida ??= await rides.buscarCorridaAtiva(perfilId: perfilId);
      final current = corrida;
      if (current != null) {
        final nextStatus = _normalizarStatus(current.status);
        if (nextStatus == 'concluida' || nextStatus == 'cancelada' || nextStatus == 'rejeitada') {
          _encerrarCorrida(limparEnderecos: nextStatus == 'concluida');
          return;
        }
        setState(() {
          _atualizarServerOffset(current.serverTime);
          _corridaAtiva = true;
          _corridaIdAtual = current.id;
          _statusCorrida = current.status;
          _corridaLugares = current.lugares;
          _corridaAceitaEm = nextStatus == 'aceita'
              ? (_corridaAceitaEm ?? current.atualizadoEm ?? _nowServer())
              : null;
          _corridaIniciadaEm = nextStatus == 'em_andamento'
              ? (_corridaIniciadaEm ?? current.atualizadoEm ?? _nowServer())
              : null;
          _motoristaNome = current.motoristaNome;
          _motoristaTelefone = current.motoristaTelefone;
          _origemEnderecoCorrida = current.origemEndereco;
          _destinoEnderecoCorrida = current.destinoEndereco;
          if (current.origemLat != null && current.origemLng != null) {
            _origemLatLng = LatLng(current.origemLat!, current.origemLng!);
          }
          if (current.destinoLat != null && current.destinoLng != null) {
            _destinoLatLng = LatLng(current.destinoLat!, current.destinoLng!);
          }
          if (current.motoristaLat != null && current.motoristaLng != null) {
            _motoristaLatLng = LatLng(current.motoristaLat!, current.motoristaLng!);
          }
          if (_origemCtrl.text.trim().isEmpty && current.origemEndereco != null && current.origemEndereco!.isNotEmpty) {
            _origemCtrl.text = current.origemEndereco!;
          }
        if (_destinoCtrl.text.trim().isEmpty && current.destinoEndereco != null && current.destinoEndereco!.isNotEmpty) {
          _destinoCtrl.text = current.destinoEndereco!;
        }
        _lugaresSolicitados = current.lugares;
      });
      _sincronizarMotoristasOnline();
      _origemTextoConfirmado = _origemCtrl.text.trim();
      _destinoTextoConfirmado = _destinoCtrl.text.trim();
      _sincronizarModalCorrida();
        if (_origemLatLng != null && _destinoLatLng != null) {
          _carregarRotaCorrida(_origemLatLng!, _destinoLatLng!);
        }
        if (_motoristaLatLng != null) {
          _atualizarRotaMotorista(current.status);
        }
        _avaliarTilesPara(_origemLatLng ?? _destinoLatLng);
        _salvarCorridaLocal(current.id);
        if (!_wsConnected) {
          _iniciarPollingCorrida();
        }
        _gerenciarTimerCancelamento();
        _gerenciarTimerFinalizacao();
      } else {
        _salvarCorridaLocal(null);
      }
    } catch (_) {
      // silencioso
    }
  }

  void _iniciarPollingCorrida() {
    _corridaTimer?.cancel();
    if (_corridaIdAtual == null) return;
    if (_wsConnected) return;
    _corridaPollInterval = PassengerSettings.corridaPollIntervalBase;
    _agendarPoll();
  }

  void _agendarPoll() {
    _corridaTimer?.cancel();
    _corridaTimer = Timer(_corridaPollInterval, () async {
      final sucesso = await _atualizarCorridaAtiva();
      if (sucesso) {
        _corridaPollInterval = PassengerSettings.corridaPollIntervalBase;
      } else {
        final next = _corridaPollInterval.inSeconds * 2;
        _corridaPollInterval = Duration(
          seconds: next.clamp(
            PassengerSettings.corridaPollIntervalMin.inSeconds,
            PassengerSettings.corridaPollIntervalMax.inSeconds,
          ),
        );
      }
      _agendarPoll();
    });
  }

  void _iniciarMotoristasOnlinePolling() {
    if (!mounted || !_podeMostrarMotoristasOnline()) return;
    _motoristasOnlineTimer?.cancel();
    _motoristasOnlineTimer = Timer.periodic(PassengerSettings.motoristasOnlinePollingInterval, (_) => _atualizarMotoristasOnline());
    unawaited(_atualizarMotoristasOnline());
  }

  void _pararMotoristasOnlinePolling({bool limpar = false}) {
    _motoristasOnlineTimer?.cancel();
    if (limpar && mounted) {
      setState(() {
        _motoristasOnline = [];
      });
    }
  }

  Future<void> _atualizarMotoristasOnline() async {
    if (!mounted || !_podeMostrarMotoristasOnline()) return;
    final referencia = _origemLatLng ??
        _mapDefaultCenter ??
        const LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
    if (_carregandoMotoristasOnline) return;
    _carregandoMotoristasOnline = true;
    try {
      final rides = RidesService();
      final lista = await rides.motoristasProximos(
        lat: _round6(referencia.latitude),
        lng: _round6(referencia.longitude),
        raioKm: 5,
        minutos: 10,
        limite: 50,
      );
      if (!mounted) return;
      setState(() {
        _motoristasOnline = lista;
      });
    } catch (e) {
      debugPrint('Erro ao carregar motoristas online: ${friendlyError(e)}');
    } finally {
      _carregandoMotoristasOnline = false;
    }
  }

  void _configurarRealtime() {
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    final tipo = user?.perfilTipo ?? '';
    final isPassenger = tipo == 'passageiro' || tipo == 'cliente';
    if (!isPassenger || perfilId == 0) {
      _stopRealtime();
      return;
    }
    if (_realtime != null && _wsPerfilId == perfilId) return;
    _stopRealtime();
    _wsPerfilId = perfilId;
    _realtime = RealtimeService(
      role: RealtimeRole.passenger,
      onConnected: _onRealtimeConnected,
      onDisconnected: _onRealtimeDisconnected,
      onEvent: _handleRealtimeEvent,
    );
    unawaited(_realtime!.connect());
  }

  void _stopRealtime() {
    _realtime?.disconnect(reconnect: false);
    _realtime = null;
    _wsConnected = false;
    _wsPerfilId = null;
  }

  void _onRealtimeConnected() {
    if (!mounted) return;
    setState(() => _wsConnected = true);
    _corridaTimer?.cancel();
    _realtime?.sendSync();
  }

  void _onRealtimeDisconnected() {
    if (!mounted) return;
    setState(() => _wsConnected = false);
    if (_corridaIdAtual != null) {
      _iniciarPollingCorrida();
    }
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == null) return;
    if (type == 'ride_update' || type == 'ride_assigned' || type == 'ride_created') {
      final raw = event['corrida'];
      if (raw is Map) {
        final corrida = CorridaResumo.fromJson(Map<String, dynamic>.from(raw));
        _aplicarCorridaResumo(corrida);
      } else if (raw == null) {
        _encerrarCorrida();
      }
      return;
    }
    if (type == 'driver_location') {
      final corridaId = event['corrida_id'];
      if (_corridaIdAtual == null) return;
      if (corridaId is int && _corridaIdAtual != null && corridaId != _corridaIdAtual) {
        return;
      }
      final lat = event['latitude'];
      final lng = event['longitude'];
      final bearing = event['bearing'];
      debugPrint('Passenger received driver_location: lat=$lat, lng=$lng, bearing=$bearing');
      if (lat is num && lng is num) {
        setState(() {
          _motoristaLatLng = LatLng(lat.toDouble(), lng.toDouble());
          if (bearing is num) {
            _motoristaBearing = bearing.toDouble();
          }
        });
        debugPrint('Passenger _motoristaBearing after WS update: $_motoristaBearing');
        _atualizarRotaMotorista(_statusCorrida);
      }
    }
  }

  void _aplicarCorridaResumo(CorridaResumo corrida) {
    if (!mounted) return;
    final nextStatus = _normalizarStatus(corrida.status);
    if (nextStatus == 'concluida' || nextStatus == 'cancelada' || nextStatus == 'rejeitada') {
      _encerrarCorrida(limparEnderecos: nextStatus == 'concluida');
      return;
    }
    setState(() {
      _atualizarServerOffset(corrida.serverTime);
      _corridaAtiva = true;
      _corridaIdAtual = corrida.id;
      _statusCorrida = corrida.status;
      _corridaLugares = corrida.lugares;
      _corridaAceitaEm = nextStatus == 'aceita'
          ? (_corridaAceitaEm ?? corrida.atualizadoEm ?? _nowServer())
          : null;
      _corridaIniciadaEm = nextStatus == 'em_andamento'
          ? (_corridaIniciadaEm ?? corrida.atualizadoEm ?? _nowServer())
          : null;
      _motoristaNome = corrida.motoristaNome;
      _motoristaTelefone = corrida.motoristaTelefone;
      _origemEnderecoCorrida = corrida.origemEndereco;
      _destinoEnderecoCorrida = corrida.destinoEndereco;
      if (corrida.origemLat != null && corrida.origemLng != null) {
        _origemLatLng = LatLng(corrida.origemLat!, corrida.origemLng!);
      }
      if (corrida.destinoLat != null && corrida.destinoLng != null) {
        _destinoLatLng = LatLng(corrida.destinoLat!, corrida.destinoLng!);
      }
      if (corrida.motoristaLat != null && corrida.motoristaLng != null) {
        _motoristaLatLng = LatLng(corrida.motoristaLat!, corrida.motoristaLng!);
      } else {
        _motoristaLatLng = null;
        _rotaMotorista = [];
      }
      if (corrida.motoristaBearing != null) {
        _motoristaBearing = corrida.motoristaBearing!;
      } else {
        _motoristaBearing = 0.0;
      }
      debugPrint('Passenger _motoristaBearing after initial load: $_motoristaBearing');
      if (_origemCtrl.text.trim().isEmpty && corrida.origemEndereco != null && corrida.origemEndereco!.isNotEmpty) {
        _origemCtrl.text = corrida.origemEndereco!;
      }
      if (_destinoCtrl.text.trim().isEmpty && corrida.destinoEndereco != null && corrida.destinoEndereco!.isNotEmpty) {
        _destinoCtrl.text = corrida.destinoEndereco!;
      }
      _lugaresSolicitados = corrida.lugares;
    });
    _sincronizarMotoristasOnline();
    _origemTextoConfirmado = _origemCtrl.text.trim();
    _destinoTextoConfirmado = _destinoCtrl.text.trim();
    _sincronizarModalCorrida();
    if (_origemLatLng != null && _destinoLatLng != null) {
      _carregarRotaCorrida(_origemLatLng!, _destinoLatLng!);
    }
    if (_motoristaLatLng != null) {
      _atualizarRotaMotorista(corrida.status);
    }
    _gerenciarTimerCancelamento();
    _gerenciarTimerFinalizacao();
    _salvarCorridaLocal(corrida.id);
  }

  Future<bool> _atualizarCorridaAtiva() async {
    if (_corridaIdAtual == null) return false;
    try {
      final rides = RidesService();
      final corrida = await rides.obterCorrida(_corridaIdAtual!);
      if (corrida == null) {
        if (!mounted) return false;
        setState(() {
          _encerrarCorrida();
        });
        debugPrint('Corrida não encontrada.');
        return false;
      }
      _aplicarCorridaResumo(corrida);
      return true;
    } catch (_) {
      return false;
    }
  }

  Widget _infoBox(BuildContext context, String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  Widget _buildCancelCountdown(BuildContext context, {bool compact = false}) {
    final remaining = _tempoRestanteCancelamento();
    if (remaining == null || remaining <= Duration.zero) {
      return const SizedBox.shrink();
    }
    final progress = _cancelamentoProgresso(remaining);
    final barHeight = compact ? 6.0 : 8.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(barHeight),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: barHeight,
            backgroundColor: Colors.green.shade100,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.green.shade600),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Você pode cancelar a corrida em ${_formatTempoRestante(remaining)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.green.shade800),
        ),
      ],
    );
  }

  Widget _buildFinalizarCountdown(BuildContext context, {bool compact = false}) {
    final remaining = _tempoRestanteFinalizacao();
    if (remaining == null || remaining <= Duration.zero) {
      return const SizedBox.shrink();
    }
    final progress = _finalizacaoProgresso(remaining);
    final barHeight = compact ? 6.0 : 8.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(barHeight),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: barHeight,
            backgroundColor: Colors.orange.shade100,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.orange.shade600),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Finalizacao liberada em ${_formatTempoRestante(remaining)}',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.orange.shade800),
        ),
      ],
    );
  }

  Widget _buildRideInfoCard(
    BuildContext context, {
    EdgeInsetsGeometry? margin,
  }) {
    if (!_corridaAtiva || _corridaIdAtual == null) {
      return const SizedBox.shrink();
    }
    final status = _statusLabel(_statusCorrida);
    final hint = _statusHint(_statusCorrida);
    final normalized = _normalizarStatus(_statusCorrida);
    final showDriver = normalized == 'aceita' || normalized == 'em_andamento';
    final driverName = showDriver
        ? (_motoristaNome?.trim().isNotEmpty == true ? _motoristaNome!.trim() : 'Motorista confirmado')
        : 'Aguardando motorista aceitar';
    final driverPhone = showDriver
        ? (_motoristaTelefone?.trim().isNotEmpty == true ? _motoristaTelefone!.trim() : 'Telefone não informado')
        : '—';
    final origemText = (_origemEnderecoCorrida?.trim().isNotEmpty == true ? _origemEnderecoCorrida! : _origemCtrl.text).trim();
    final destinoText = (_destinoEnderecoCorrida?.trim().isNotEmpty == true ? _destinoEnderecoCorrida! : _destinoCtrl.text).trim();
    final origem = origemText.isNotEmpty ? origemText : (_formatLatLng(_origemLatLng) ?? '—');
    final destino = destinoText.isNotEmpty ? destinoText : (_formatLatLng(_destinoLatLng) ?? '—');
    final link = showDriver ? _buildWhatsAppLink(_motoristaTelefone) : null;

    return Container(
      margin: margin ?? const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyedSubtree(
            key: _guiaModalStatusKey,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'STATUS',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(letterSpacing: 1, color: Colors.green.shade700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    status,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(hint, style: Theme.of(context).textTheme.bodySmall),
                  if (_cancelamentoBloqueado()) ...[
                    const SizedBox(height: 8),
                    _buildCancelCountdown(context),
                  ],
                  if (_finalizacaoBloqueada()) ...[
                    const SizedBox(height: 8),
                    _buildFinalizarCountdown(context),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          KeyedSubtree(
            key: _guiaModalMotoristaKey,
            child: _infoBox(
              context,
              'Motorista',
              [
                Text(driverName, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      driverPhone,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade700),
                    ),
                    if (link != null)
                      OutlinedButton.icon(
                        onPressed: () => _abrirWhatsApp(_motoristaTelefone),
                        icon: const Icon(Icons.chat_bubble_outline, size: 18),
                        label: const Text('WhatsApp'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          KeyedSubtree(
            key: _guiaModalRotaKey,
            child: _infoBox(
              context,
              'Rota',
              [
                Text('Origem: $origem', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text('Destino: $destino', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 4),
                Text(
                  'Quantos assentos você precisa para essa corrida? ${_formatarLugares(_corridaLugares)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarModalCorrida({bool iniciarGuia = false}) async {
    if (_modalAberto || !mounted) return;
    _modalAberto = true;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) {
      _modalAberto = false;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final guiaModalVisto = prefs.getBool(_prefsGuiaModalPassageiroKey) ?? false;
      final statusAtual = _normalizarStatus(_statusCorrida);
      final deveIniciarGuia = iniciarGuia || (!guiaModalVisto && statusAtual == 'aguardando');
      final modoGuia = iniciarGuia;
      var guiaIniciado = false;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black54,
        useRootNavigator: true,
        builder: (dialogContext) {
          return SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Dialog(
                  key: _guiaModalContainerKey,
                  backgroundColor: Theme.of(dialogContext).dialogTheme.backgroundColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  child: StatefulBuilder(
                    builder: (context, setModalState) {
                      _modalSetState = setModalState;
                      if (deveIniciarGuia && !guiaIniciado) {
                        guiaIniciado = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) async {
                          if (!dialogContext.mounted) return;
                          await showCoachMarks(dialogContext, _buildGuiaModalPassageiroSteps());
                          if (!dialogContext.mounted) return;
                          unawaited(prefs.setBool(_prefsGuiaModalPassageiroKey, true));
                          if (modoGuia && Navigator.of(dialogContext, rootNavigator: true).canPop()) {
                            Navigator.of(dialogContext, rootNavigator: true).pop();
                          }
                        });
                      }
                                              final origem = _origemLatLng;
                                              final destino = _destinoLatLng;
                                              final motorista = _mostrarMotoristaNoMapa() ? _motoristaLatLng : null;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.local_taxi, color: Colors.green, size: 24),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Corrida',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _buildRideInfoCard(
                                context,
                                margin: EdgeInsets.zero,
                              ),
                              const SizedBox(height: 12),
                              if (origem != null || destino != null || motorista != null)
                                SizedBox(
                                  key: _guiaModalMapaKey,
                                  height: 220,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Builder(
                                      builder: (context) {
                                        final bounds = MapTileConfig.tilesBounds;
                                      final rawPins = _pinsMapaModal();
                                      final pins = MapViewport.clampPinsToBounds(rawPins, bounds);
                                        final center = MapViewport.clampCenter(
                                          MapViewport.centerForPins(pins),
                                          bounds,
                                        );
                                        final minZoom = _effectiveMinZoom();
                                        final maxZoom = _effectiveMaxZoom();
                                        final zoom = MapViewport.zoomForPins(
                                          pins,
                                          minZoom: minZoom,
                                          maxZoom: maxZoom,
                                          fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
                                        );
                                        final fitBounds = MapViewport.boundsForPins(pins);
                                        final fit = fitBounds == null
                                            ? null
                                            : CameraFit.bounds(
                                                bounds: fitBounds,
                                                padding: const EdgeInsets.all(24),
                                                minZoom: minZoom,
                                                maxZoom: maxZoom,
                                              );
                                      final key = ValueKey(
                                        'pass-modal-${_rotaKey ?? 'sem-rota'}-${MapViewport.signatureForPins(
                                          MapViewport.collectPins([origem, destino, motorista]),
                                        )}',
                                      );
                                                                                return FlutterMap(
                                                                                  key: key,
                                                                                  options: MapOptions(
                                                                                    initialCenter: center,
                                                                                    initialZoom: zoom,
                                                                                    initialCameraFit: fit,
                                                                                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                                                                                    cameraConstraint: CameraConstraint.contain(bounds: bounds),
                                                                                    minZoom: minZoom,
                                                                                    maxZoom: maxZoom,
                                                                                  ),
                                                                                  children: [
                                                                                    TileLayer(
                                                                                      urlTemplate: _tileUrl,
                                                                                      tileProvider: _buildTileProvider(),
                                                                                      userAgentPackageName: 'com.example.vai_paqueta_app',
                                                                                      minZoom: minZoom,
                                                                                      maxZoom: maxZoom,
                                                                                      minNativeZoom: _effectiveMinNativeZoom(),
                                                                                      maxNativeZoom: _effectiveMaxNativeZoom(),
                                                                                      tileBounds: bounds,
                                                                                    ),
                                            if (_rotaGps.length >= 2)
                                              PolylineLayer(
                                                polylines: [
                                                  Polyline(
                                                    points: _rotaGps,
                                                    strokeWidth: 2.0,
                                                    color: Colors.lightBlueAccent.withValues(alpha: 0.8),
                                                  ),
                                                ],
                                              ),
                                            if (_rota.length >= 2)
                                              PolylineLayer(
                                                polylines: [
                                                  Polyline(points: _rota, strokeWidth: 3, color: Colors.blueAccent),
                                                ],
                                              ),
                                            if (_rotaMotorista.length >= 2)
                                              PolylineLayer(
                                                polylines: [
                                                  Polyline(
                                                    points: _rotaMotorista,
                                                    strokeWidth: 3,
                                                    color: Colors.orangeAccent,
                                                  ),
                                                ],
                                              ),
                                            MarkerLayer(
                                              markers: [
                                                if (_gpsLatLng != null)
                                                  Marker(
                                                    point: _gpsLatLng!,
                                                    width: 28,
                                                    height: 28,
                                                    child: _buildGpsMarker(),
                                                  ),
                                                if (origem != null)
                                                  Marker(
                                                    point: origem,
                                                    width: 36,
                                                    height: 36,
                                                    child: const Icon(Icons.place, color: Colors.green, size: 32),
                                                  ),
                                                if (destino != null)
                                                  Marker(
                                                    point: destino,
                                                    width: 36,
                                                    height: 36,
                                                    child: const Icon(Icons.flag, color: Colors.red, size: 30),
                                                  ),
                                                if (motorista != null)
                                                  Marker(
                                                    point: motorista,
                                                    width: 72, // Adjusted for 1536x1024 aspect ratio (1.5 * 48)
                                                    height: 48,
                                                    child: Transform.rotate(
                                                      angle: (_motoristaBearing) * (math.pi / 180),
                                                      child: Image.asset('assets/icons/ecotaxi.png', width: 72, height: 48), // Adjusted for 1536x1024 aspect ratio
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              if (_podeCancelarCorrida || _podeFinalizarCorrida) ...[
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Wrap(
                                    key: _guiaModalAcoesKey,
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      if (_podeCancelarCorrida)
                                        OutlinedButton.icon(
                                          onPressed: modoGuia || _loading ? null : _pedirCorrida,
                                          icon: const Icon(Icons.cancel),
                                          label: const Text('Cancelar'),
                                        ),
                                      if (_podeFinalizarCorrida)
                                        ElevatedButton.icon(
                                          onPressed: modoGuia || _loading ? null : _finalizarCorrida,
                                          icon: const Icon(Icons.flag),
                                          label: const Text('Finalizar'),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      _modalAberto = false;
      _modalSetState = null;
    }
  }

  void _atualizarRotaMotorista(String? status) {
    final motorista = _motoristaLatLng;
    if (motorista == null) {
      if (!mounted) return;
      setState(() {
        _rotaMotorista = [];
        _rotaMotoristaKey = null;
      });
      return;
    }
    final normalized = _normalizarStatus(status);
    if (normalized != 'aceita' && normalized != 'em_andamento') {
      if (!mounted) return;
      setState(() {
        _rotaMotorista = [];
        _rotaMotoristaKey = null;
      });
      return;
    }
    final alvo = normalized == 'em_andamento' ? _destinoLatLng : _origemLatLng;
    if (alvo == null) {
      if (!mounted) return;
      setState(() {
        _rotaMotorista = [];
        _rotaMotoristaKey = null;
      });
      return;
    }
    _carregarRotaMotorista(motorista, alvo);
  }

  Future<void> _salvarCorridaLocal(int? corridaId) async {
    final prefs = await SharedPreferences.getInstance();
    if (corridaId == null) {
      await prefs.remove(_prefsCorridaKey);
    } else {
      await prefs.setInt(_prefsCorridaKey, corridaId);
    }
  }

  Future<void> _trocarParaEcotaxista() async {
    setState(() {
      _trocandoPerfil = true;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: 'ecotaxista');
      if (!mounted) return;
      context.go('/motorista');
    } catch (e) {
      debugPrint('Erro ao trocar para EcoTaxista: ${friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() => _trocandoPerfil = false);
      }
    }
  }

  Future<void> _usarGPS({bool silencioso = false}) async {
    setState(() {
      _loading = true;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        final aceitou = await _mostrarConsentimentoLocalizacao();
        if (!aceitou) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        if (!mounted) return;
        if (!silencioso) {
          _showErrorSnackbar('Permissão de localização negada.');
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;

      final gpsLatLng = LatLng(pos.latitude, pos.longitude);
      final isOriginOk = await _geo.isInsideServiceArea(pos.latitude, pos.longitude);
      if (!isOriginOk) {
        if (!silencioso) {
          _showErrorSnackbar('Sua localização atual está fora da área de serviço.');
        }
        setState(() {
          _origemLatLng = null;
          _gpsLatLng = gpsLatLng;
        });
        _limparRotaGps();
        return;
      }

      setState(() {
        _gpsLatLng = gpsLatLng;
        _origemLatLng = gpsLatLng;
        _posCarregada = true;
      });
      _avaliarTilesPara(_origemLatLng);
      try {
        final res = await _geo.reverse(pos.latitude, pos.longitude);
        if (!mounted) return;
        setState(() {
          _origemCtrl.text = res.endereco.isNotEmpty ? res.endereco : _origemCtrl.text;
          _origemLatLng = LatLng(res.lat, res.lng);
        });
      } catch (_) {
        if (!silencioso) {
          _showErrorSnackbar('Origem definida pelo GPS (falha no endereço).');
        }
      }
      _origemTextoConfirmado = _origemCtrl.text.trim();
      await _atualizarRotaSePossivel();
      unawaited(_atualizarMotoristasOnline());
    } catch (e) {
      if (!mounted) return;
      if (!silencioso) {
        _showErrorSnackbar('Erro ao obter localização: ${friendlyError(e)}');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _finalizarCorrida() async {
    if (!_corridaAtiva || _corridaIdAtual == null) return;
    setState(() {
      _loading = true;
    });
    final refreshed = await _atualizarCorridaAtiva();
    if (!mounted) return;
    if (!refreshed) {
      setState(() => _loading = false);
      return;
    }
    if (!_podeFinalizarCorrida) {
      final remaining = _tempoRestanteFinalizacao();
      final msg = remaining != null && remaining > Duration.zero
          ? 'Aguarde ${_formatTempoRestante(remaining)} para finalizar.'
          : 'Corrida ainda nao pode ser finalizada.';
      _showErrorSnackbar(msg);
      setState(() => _loading = false);
      return;
    }
    try {
      final rides = RidesService();
      await rides.finalizarCorrida(_corridaIdAtual!);
      setState(() {
        _encerrarCorrida(limparEnderecos: true);
      });
    } catch (e) {
      _showErrorSnackbar('Erro ao finalizar: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  Future<void> _pedirCorrida() async {
    if (_corridaAtiva && _corridaIdAtual != null) {
      setState(() {
        _loading = true;
      });
      final refreshed = await _atualizarCorridaAtiva();
      if (!mounted) return;
      if (!refreshed) {
        setState(() => _loading = false);
        return;
      }
      if (!_podeCancelarCorrida) {
        final remaining = _tempoRestanteCancelamento();
        final status = _normalizarStatus(_statusCorrida);
        final msg = remaining != null && remaining > Duration.zero && status == 'aceita'
            ? 'Aguarde ${_formatTempoRestante(remaining)} para cancelar.'
            : 'Corrida já aceita. Não é possível cancelar agora.';
        _showErrorSnackbar(msg);
        setState(() => _loading = false);
        return;
      }
      try {
        final rides = RidesService();
        await rides.cancelarCorrida(_corridaIdAtual!);
        setState(() {
          _encerrarCorrida();
        });
      } catch (e) {
        if (e is DioException) {
          await _atualizarCorridaAtiva();
        }
        _showErrorSnackbar('Erro ao cancelar: ${friendlyError(e)}');
      } finally {
        setState(() => _loading = false);
      }
      return;
    }

    setState(() {
      _loading = true;
    });
    int perfilId = 0;
    try {
      try {
        final pos = await Geolocator.getCurrentPosition();
        final isPassengerOk = await _geo.isInsideServiceArea(pos.latitude, pos.longitude);
        if (!isPassengerOk) {
          _showErrorSnackbar('Você precisa estar na ilha para pedir uma corrida.');
          return;
        }
      } catch (e) {
        _showErrorSnackbar('Não foi possível obter sua localização atual.');
        return;
      }

      final user = ref.read(authProvider).valueOrNull;
      perfilId = user?.perfilId ?? 0;
      if (perfilId == 0) {
        _showErrorSnackbar('Perfil do usuário não encontrado.');
        return;
      }
      if (_lugaresSolicitados < 1 || _lugaresSolicitados > 2) {
        _showErrorSnackbar('Selecione 1 ou 2 assentos.');
        return;
      }
      if (_origemLatLng == null && _origemCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_origemCtrl.text);
        _origemLatLng = LatLng(res.lat, res.lng);
        _origemCtrl.text = res.endereco;
        _origemTextoConfirmado = _origemCtrl.text.trim();
        await _avaliarTilesPara(_origemLatLng);
      }
      if (_destinoLatLng == null && _destinoCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_destinoCtrl.text);
        _destinoLatLng = LatLng(res.lat, res.lng);
        _destinoCtrl.text = res.endereco;
        _destinoTextoConfirmado = _destinoCtrl.text.trim();
        await _avaliarTilesPara(_destinoLatLng);
      }
      if (_origemLatLng == null || _destinoLatLng == null) {
        _showErrorSnackbar('Defina origem e destino.');
        return;
      }

      final isOriginOk = await _geo.isInsideServiceArea(_origemLatLng!.latitude, _origemLatLng!.longitude);
      if (!isOriginOk) {
        _showErrorSnackbar('O endereço de origem está fora da área de serviço.');
        return;
      }

      final isDestOk = await _geo.isInsideServiceArea(_destinoLatLng!.latitude, _destinoLatLng!.longitude);
      if (!isDestOk) {
        _showErrorSnackbar('O endereço de destino está fora da área de serviço.');
        return;
      }

      await _carregarRotaCorrida(_origemLatLng!, _destinoLatLng!);

      final rides = RidesService();
      final corrida = await rides.solicitar(
        perfilId: perfilId,
        origemLat: _round6(_origemLatLng!.latitude),
        origemLng: _round6(_origemLatLng!.longitude),
        destinoLat: _round6(_destinoLatLng!.latitude),
        destinoLng: _round6(_destinoLatLng!.longitude),
        lugares: _lugaresSolicitados,
        origemEndereco: _origemCtrl.text,
        destinoEndereco: _destinoCtrl.text,
      );

      setState(() {
        _atualizarServerOffset(corrida.serverTime);
        _corridaAtiva = true;
        _corridaIdAtual = corrida.id;
        _statusCorrida = corrida.status;
        _corridaAceitaEm = null;
        _motoristaLatLng = null;
        _corridaLugares = corrida.lugares;
        _lugaresSolicitados = corrida.lugares;
      });
      _sincronizarMotoristasOnline();
      _sincronizarModalCorrida();
      _salvarCorridaLocal(_corridaIdAtual);
      _iniciarPollingCorrida();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mostrarAvisoPagamento(rideId: corrida.id);
      });
    } catch (e) {
      if (e is DioException) {
        final data = e.response?.data;
        if (data is Map && data['corrida'] is Map) {
          try {
            final corrida = CorridaResumo.fromJson(
              Map<String, dynamic>.from(data['corrida'] as Map),
            );
            _aplicarCorridaResumo(corrida);
            return;
          } catch (_) {
            // segue com tratamento padrão
          }
        }
        final status = e.response?.statusCode;
        if (status != null && status >= 500 && perfilId != 0) {
          try {
            final corrida = await RidesService().buscarCorridaAtiva(perfilId: perfilId);
            if (corrida != null) {
              _aplicarCorridaResumo(corrida);
              return;
            }
          } catch (_) {
            // ignora fallback
          }
        }
      }
      _showErrorSnackbar('Erro ao pedir corrida: ${friendlyError(e)}');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final media = MediaQuery.of(context);
    final keyboardInset = media.viewInsets.bottom;
    final baseMapHeight = math.min(420.0, media.size.height * 0.45).toDouble();
    final reducedMapHeight = math.max(120.0, baseMapHeight - (keyboardInset * 0.75)).toDouble();
    final mapHeight = keyboardInset > 0 ? reducedMapHeight : baseMapHeight;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Passageiro'),
            auth.when(
              data: (user) => Text(
                user != null ? 'Conta: ${user.email}' : 'Não autenticado',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              loading: () => Text(
                'Verificando conta...',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              error: (_, __) => Text(
                'Erro na conta',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            key: _guiaConfigKey,
            tooltip: 'Editar dados',
            icon: const Icon(Icons.settings),
            onPressed: () => context.goNamed('perfil'),
          ),
          _buildGuiaIconButton(onPressed: _mostrarGuiaPassageiroManual),
          if (_trocandoPerfil)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            )
          else
            IconButton(
              key: _guiaTrocarKey,
              tooltip: 'Ir para EcoTaxista',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _trocarParaEcotaxista,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AnimatedContainer(
                key: _guiaMapaKey,
                height: mapHeight,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                child: Builder(
                  builder: (context) {
                    final bounds = MapTileConfig.tilesBounds;
                    final rawPins = _pinsMapaPrincipal();
                    final pins = MapViewport.clampPinsToBounds(rawPins, bounds);
                    final center = MapViewport.clampCenter(
                      MapViewport.centerForPins(pins),
                      bounds,
                    );
                    final minZoom = _effectiveMinZoom();
                    final maxZoom = _effectiveMaxZoom();
                    final zoom = MapViewport.zoomForPins(
                      pins,
                      minZoom: minZoom,
                      maxZoom: maxZoom,
                      fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
                    );
                    final fitBounds = MapViewport.boundsForPins(pins);
                    final fit = fitBounds == null
                        ? null
                        : CameraFit.bounds(
                            bounds: fitBounds,
                            padding: const EdgeInsets.all(24),
                            minZoom: minZoom,
                            maxZoom: maxZoom,
                          );
                    _mapDefaultCenter = center;
                    _mapDefaultZoom = zoom;
                    _mapDefaultFit = fit;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: center,
                          initialZoom: zoom,
                          initialCameraFit: fit,
                          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                          onPositionChanged: (position, hasGesture) {
                            _mapLastCenter = position.center;
                            _mapLastZoom = position.zoom;
                            if (hasGesture) {
                              _stopMapAnimation();
                              _scheduleMapReset();
                            }
                          },
                          cameraConstraint: CameraConstraint.contain(bounds: bounds),
                          minZoom: minZoom,
                          maxZoom: maxZoom,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: _tileUrl,
                            userAgentPackageName: 'com.example.vai_paqueta_app',
                            tileProvider: _buildTileProvider(),
                            minZoom: minZoom,
                            maxZoom: maxZoom,
                            minNativeZoom: _effectiveMinNativeZoom(),
                            maxNativeZoom: _effectiveMaxNativeZoom(),
                            tileBounds: bounds,
                          ),
                          if (_rotaGps.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _rotaGps,
                                  strokeWidth: 2.2,
                                  color: Colors.lightBlueAccent.withValues(alpha: 0.8),
                                ),
                              ],
                            ),
                          if (_rota.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: _rota,
                                  strokeWidth: 4,
                                  color: Colors.blueAccent,
                                ),
                              ],
                            ),
                          if (_rotaMotorista.length >= 2)
                            PolylineLayer(
                              polylines: <Polyline>[
                                Polyline(
                                  points: _rotaMotorista,
                                  strokeWidth: 3,
                                  color: Colors.orangeAccent,
                                ),
                              ],
                            ),
                          if (_motoristasOnline.isNotEmpty && _podeMostrarMotoristasOnline())
                            MarkerLayer(
                              markers: _motoristasOnline
                                  .map(
                                    (motorista) => Marker(
                                      point: LatLng(motorista.latitude, motorista.longitude),
                                      width: 48,
                                      height: 32,
                                      child: Opacity(
                                        opacity: 0.85,
                                        child: Transform.rotate(
                                          angle: (motorista.bearing ?? 0) * (math.pi / 180),
                                          child: Image.asset(
                                            'assets/icons/ecotaxi.png',
                                            width: 48,
                                            height: 32,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          if (_gpsLatLng != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _gpsLatLng!,
                                  width: 28,
                                  height: 28,
                                  child: _buildGpsMarker(),
                                ),
                              ],
                            ),
                          if (_origemLatLng != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _origemLatLng!,
                                  width: 40,
                                  height: 40,
                                  child: const Icon(Icons.place, color: Colors.green, size: 36),
                                ),
                              ],
                            ),
                          if (_destinoLatLng != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _destinoLatLng!,
                                  width: 40,
                                  height: 40,
                                  child: const Icon(Icons.flag, color: Colors.red, size: 32),
                                ),
                              ],
                            ),
                          if (_motoristaLatLng != null && _mostrarMotoristaNoMapa())
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _motoristaLatLng!,
                                  width: 72, // Adjusted for 1536x1024 aspect ratio (1.5 * 48)
                                  height: 48,
                                  child: Transform.rotate(
                                    angle: (_motoristaBearing) * (math.pi / 180),
                                    child: Image.asset('assets/icons/ecotaxi.png', width: 72, height: 48), // Adjusted for 1536x1024 aspect ratio
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + keyboardInset),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Autocomplete<GeoResult>(
                      displayStringForOption: (option) => option.endereco,
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        _debounceOrigem?.cancel();
                        final completer = Completer<Iterable<GeoResult>>();
                        _debounceOrigem = Timer(PassengerSettings.suggestionDebounce, () async {
                          final results = await _buscarSugestoesOrigem(textEditingValue.text);
                          if (!completer.isCompleted) {
                            completer.complete(results);
                          }
                        });
                        return completer.future;
                      },
                      onSelected: (GeoResult selection) {
                        if (!mounted) return;
                        setState(() {
                          _origemCtrl.text = selection.endereco;
                          _origemLatLng = LatLng(selection.lat, selection.lng);
                        });
                        _origemTextoConfirmado = _origemCtrl.text.trim();
                        _avaliarTilesPara(_origemLatLng);
                        _atualizarRotaSePossivel();
                        FocusScope.of(context).unfocus();
                      },
                      fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _origemCtrl.text != textEditingController.text) {
                            final originalSelection = textEditingController.selection;
                            textEditingController.text = _origemCtrl.text;
                            textEditingController.selection = originalSelection;
                          }
                        });
                        return TextField(
                          key: _guiaOrigemKey,
                          controller: textEditingController,
                          focusNode: focusNode,
                          onChanged: (text) {
                            final trimmed = text.trim();
                            if (_origemLatLng != null && trimmed != _origemTextoConfirmado) {
                              if (mounted) {
                                setState(() {
                                  _origemLatLng = null;
                                  _origemTextoConfirmado = '';
                                });
                              }
                              _limparRotaCorrida();
                              _limparRotaGps();
                            }
                            _origemCtrl.text = text;
                          },
                          onEditingComplete: () {
                            _confirmarOrigemDigitada();
                            onFieldSubmitted();
                          },
                          decoration: InputDecoration(
                            labelText: 'Endereço atual (origem)',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              key: _guiaGpsKey,
                              icon: const Icon(Icons.gps_fixed),
                              onPressed: _loading ? null : _usarGPS,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Autocomplete<GeoResult>(
                      displayStringForOption: (option) => option.endereco,
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        _debounceDestino?.cancel();
                        final completer = Completer<Iterable<GeoResult>>();
                        _debounceDestino = Timer(PassengerSettings.suggestionDebounce, () async {
                          final results = await _buscarSugestoesDestino(textEditingValue.text);
                          if (!completer.isCompleted) {
                            completer.complete(results);
                          }
                        });
                        return completer.future;
                      },
                      onSelected: (GeoResult selection) {
                        if (!mounted) return;
                        setState(() {
                          _destinoCtrl.text = selection.endereco;
                          _destinoLatLng = LatLng(selection.lat, selection.lng);
                        });
                        _destinoTextoConfirmado = _destinoCtrl.text.trim();
                        _avaliarTilesPara(_destinoLatLng);
                        _atualizarRotaSePossivel();
                        FocusScope.of(context).unfocus();
                      },
                      fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _destinoCtrl.text != textEditingController.text) {
                            final originalSelection = textEditingController.selection;
                            textEditingController.text = _destinoCtrl.text;
                            textEditingController.selection = originalSelection;
                          }
                        });
                        return TextField(
                          key: _guiaDestinoKey,
                          controller: textEditingController,
                          focusNode: focusNode,
                          onChanged: (text) {
                            final trimmed = text.trim();
                            if (_destinoLatLng != null && trimmed != _destinoTextoConfirmado) {
                              if (mounted) {
                                setState(() {
                                  _destinoLatLng = null;
                                  _destinoTextoConfirmado = '';
                                });
                              }
                              _limparRotaCorrida();
                            }
                            _destinoCtrl.text = text;
                          },
                          onEditingComplete: () {
                            _confirmarDestinoDigitado();
                            onFieldSubmitted();
                          },
                          decoration: const InputDecoration(
                            labelText: 'Endereço de ida (destino)',
                            border: OutlineInputBorder(),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      key: _guiaLugaresKey,
                      initialValue: _lugaresSolicitados,
                      decoration: const InputDecoration(
                        labelText: 'Quantos assentos você precisa para essa corrida?',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 assento')),
                        DropdownMenuItem(value: 2, child: Text('2 assentos')),
                      ],
                      onChanged: _corridaAtiva || _loading
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() => _lugaresSolicitados = value);
                            },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Máximo de 2 assentos por corrida.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    if (_cancelamentoBloqueado()) ...[
                      const SizedBox(height: 8),
                      _buildCancelCountdown(context, compact: true),
                    ],
                    if (_finalizacaoBloqueada()) ...[
                      const SizedBox(height: 8),
                      _buildFinalizarCountdown(context, compact: true),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      key: _guiaPedirKey,
                      onPressed: _loading || (_corridaAtiva && !_podeCancelarCorrida) ? null : _pedirCorrida,
                      icon: Icon(
                        _corridaAtiva
                            ? (_podeCancelarCorrida ? Icons.cancel : Icons.timelapse)
                            : Icons.local_taxi,
                      ),
                      label: Text(
                        _loading
                            ? 'Enviando...'
                            : _corridaAtiva
                                ? (_podeCancelarCorrida
                                    ? 'Cancelar'
                                    : 'Corrida em andamento')
                                : 'Pedir corrida',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PassengerModalSnapshot {
  _PassengerModalSnapshot({
    required this.corridaAtiva,
    required this.corridaIdAtual,
    required this.statusCorrida,
    required this.corridaLugares,
    required this.corridaAceitaEm,
    required this.corridaIniciadaEm,
    required this.motoristaNome,
    required this.motoristaTelefone,
    required this.origemEnderecoCorrida,
    required this.destinoEnderecoCorrida,
    required this.origemLatLng,
    required this.destinoLatLng,
    required this.motoristaLatLng,
    required this.motoristaBearing,
    required this.rota,
    required this.rotaKey,
    required this.rotaMotorista,
    required this.rotaMotoristaKey,
    required this.origemCtrlText,
    required this.destinoCtrlText,
    required this.origemTextoConfirmado,
    required this.destinoTextoConfirmado,
  });

  final bool corridaAtiva;
  final int? corridaIdAtual;
  final String? statusCorrida;
  final int corridaLugares;
  final DateTime? corridaAceitaEm;
  final DateTime? corridaIniciadaEm;
  final String? motoristaNome;
  final String? motoristaTelefone;
  final String? origemEnderecoCorrida;
  final String? destinoEnderecoCorrida;
  final LatLng? origemLatLng;
  final LatLng? destinoLatLng;
  final LatLng? motoristaLatLng;
  final double motoristaBearing;
  final List<LatLng> rota;
  final String? rotaKey;
  final List<LatLng> rotaMotorista;
  final String? rotaMotoristaKey;
  final String origemCtrlText;
  final String destinoCtrlText;
  final String origemTextoConfirmado;
  final String destinoTextoConfirmado;

  factory _PassengerModalSnapshot.fromState(_PassengerPageState state) {
    return _PassengerModalSnapshot(
      corridaAtiva: state._corridaAtiva,
      corridaIdAtual: state._corridaIdAtual,
      statusCorrida: state._statusCorrida,
      corridaLugares: state._corridaLugares,
      corridaAceitaEm: state._corridaAceitaEm,
      corridaIniciadaEm: state._corridaIniciadaEm,
      motoristaNome: state._motoristaNome,
      motoristaTelefone: state._motoristaTelefone,
      origemEnderecoCorrida: state._origemEnderecoCorrida,
      destinoEnderecoCorrida: state._destinoEnderecoCorrida,
      origemLatLng: state._origemLatLng,
      destinoLatLng: state._destinoLatLng,
      motoristaLatLng: state._motoristaLatLng,
      motoristaBearing: state._motoristaBearing,
      rota: List<LatLng>.from(state._rota),
      rotaKey: state._rotaKey,
      rotaMotorista: List<LatLng>.from(state._rotaMotorista),
      rotaMotoristaKey: state._rotaMotoristaKey,
      origemCtrlText: state._origemCtrl.text,
      destinoCtrlText: state._destinoCtrl.text,
      origemTextoConfirmado: state._origemTextoConfirmado,
      destinoTextoConfirmado: state._destinoTextoConfirmado,
    );
  }

  void restore(_PassengerPageState state) {
    state._corridaAtiva = corridaAtiva;
    state._corridaIdAtual = corridaIdAtual;
    state._statusCorrida = statusCorrida;
    state._corridaLugares = corridaLugares;
    state._corridaAceitaEm = corridaAceitaEm;
    state._corridaIniciadaEm = corridaIniciadaEm;
    state._motoristaNome = motoristaNome;
    state._motoristaTelefone = motoristaTelefone;
    state._origemEnderecoCorrida = origemEnderecoCorrida;
    state._destinoEnderecoCorrida = destinoEnderecoCorrida;
    state._origemLatLng = origemLatLng;
    state._destinoLatLng = destinoLatLng;
    state._motoristaLatLng = motoristaLatLng;
    state._motoristaBearing = motoristaBearing;
    state._rota = List<LatLng>.from(rota);
    state._rotaKey = rotaKey;
    state._rotaMotorista = List<LatLng>.from(rotaMotorista);
    state._rotaMotoristaKey = rotaMotoristaKey;
    state._origemCtrl.text = origemCtrlText;
    state._destinoCtrl.text = destinoCtrlText;
    state._origemTextoConfirmado = origemTextoConfirmado;
    state._destinoTextoConfirmado = destinoTextoConfirmado;
  }
}

class _TileSource {
  final String template;
  final bool usingAssets;
  final double? minZoom;
  final double? maxZoom;
  final int? minNativeZoom;
  final int? maxNativeZoom;

  _TileSource({
    required this.template,
    required this.usingAssets,
    this.minZoom,
    this.maxZoom,
    this.minNativeZoom,
    this.maxNativeZoom,
  });
}
