import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/error_messages.dart';
import '../../core/driver_settings.dart';
import '../../core/map_config.dart';
import '../../core/map_viewport.dart';
import '../../services/driver_background_service.dart';
import '../../services/map_tile_cache_service.dart';
import '../../services/notification_service.dart';
import '../../services/route_service.dart';
import '../../services/realtime_service.dart';
import '../../widgets/coach_mark.dart';
import '../auth/auth_provider.dart';
import 'driver_service.dart';

class DriverPage extends ConsumerStatefulWidget {
  const DriverPage({super.key});

  @override
  ConsumerState<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends ConsumerState<DriverPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _prefsRecebendoCorridasKey = 'driver_recebendo_corridas';
  static const _prefsLocalizacaoBgKey = 'driver_localizacao_bg';
  static const _prefsConsentimentoBgKey = 'driver_localizacao_bg_consentimento';
  static const _prefsConsentimentoNotificacaoKey = 'driver_notificacao_consentimento';
  static const _prefsGuiaMotoristaKey = 'motorista_guia_visto';
  final GlobalKey _guiaConfigKey = GlobalKey();
  final GlobalKey _guiaTrocarKey = GlobalKey();
  final GlobalKey _guiaRecebimentoKey = GlobalKey();
  final GlobalKey _guiaLocalizacaoBgKey = GlobalKey();
  final GlobalKey _guiaMapaKey = GlobalKey();
  final GlobalKey _guiaModalStatusKey = GlobalKey();
  final GlobalKey _guiaModalPassageiroKey = GlobalKey();
  final GlobalKey _guiaModalWhatsKey = GlobalKey();
  final GlobalKey _guiaModalRotaKey = GlobalKey();
  final GlobalKey _guiaModalMapaKey = GlobalKey();
  final GlobalKey _guiaModalAcoesKey = GlobalKey();
  bool _enviando = false;
  LatLng? _posicao;
  bool _tileUsingAssets = MapTileConfig.useAssets;
  String _tileUrl = MapTileConfig.useAssets ? MapTileConfig.assetsTemplate : MapTileConfig.networkTemplate;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  int? _assetsMinNativeZoom;
  int? _assetsMaxNativeZoom;
  bool _usandoFallbackRede = false;
  Timer? _pingTimer;
  Timer? _pollTimer;
  final RouteService _routeService = RouteService();
  List<LatLng> _rotaMotorista = [];
  List<LatLng> _rotaCorrida = [];
  String? _rotaMotoristaKey;
  String? _rotaCorridaKey;
  bool _modalAberto = false;
  Map<String, dynamic>? _corridaAtual;
  int? _ultimaCorridaAlertada;
  bool _trocandoPerfil = false;
  bool _appPausado = false;
  StateSetter? _modalSetState;
  bool _backgroundAtivo = false;
  bool _recebendoCorridas = false;
  bool _enviarLocalizacaoBg = false;
  bool _consentimentoLocalizacaoBg = false;
  bool _guiaAtivo = false;
  bool _avisoVelocidadeAberto = false;
  DateTime? _ultimoAvisoVelocidadeEm;
  LatLng? _ultimaAmostraVelocidade;
  DateTime? _ultimaAmostraVelocidadeEm;
  StreamSubscription<String?>? _notificationTapSub;
  RealtimeService? _realtime;
  bool _wsConnected = false;
  int? _wsPerfilId;
  ProviderSubscription<AsyncValue<dynamic>>? _authSub;
  bool _exibirRotasNoMapaPrincipal = true;
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _posicaoStreamSub;
  final MapController _mapController = MapController();
  Timer? _mapResetTimer;
  AnimationController? _mapResetAnimation;
  LatLng? _mapDefaultCenter;
  double? _mapDefaultZoom;
  LatLng? _mapLastCenter;
  double? _mapLastZoom;
  bool _mapUserInteracting = false;
  double _compassBearing = 0.0;
  double? _velocidadeKmh;

  Future<void> _carregarPreferencias() async {
    final prefs = await SharedPreferences.getInstance();
    final recebendo = prefs.getBool(_prefsRecebendoCorridasKey) ?? false;
    final consentimentoBg = prefs.getBool(_prefsConsentimentoBgKey) ?? false;
    final localizacaoBgSalva = prefs.getBool(_prefsLocalizacaoBgKey);
    var localizacaoBg = localizacaoBgSalva ?? false;
    if (!consentimentoBg) {
      localizacaoBg = false;
      if (localizacaoBgSalva == true) {
        await prefs.setBool(_prefsLocalizacaoBgKey, false);
      }
    }
    if (!mounted) return;
    setState(() {
      _recebendoCorridas = recebendo;
      _enviarLocalizacaoBg = localizacaoBg;
      _consentimentoLocalizacaoBg = consentimentoBg;
    });
    _configurarRealtime();
    if (_recebendoCorridas) {
      _verificarCorrida();
      _iniciarAutoPing();
      _iniciarPollingCorrida();
    }
  }

  Future<void> _salvarPreferencias({
    bool? recebendoCorridas,
    bool? localizacaoBg,
    bool? consentimentoLocalizacaoBg,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (recebendoCorridas != null) {
      await prefs.setBool(_prefsRecebendoCorridasKey, recebendoCorridas);
    }
    if (localizacaoBg != null) {
      await prefs.setBool(_prefsLocalizacaoBgKey, localizacaoBg);
    }
    if (consentimentoLocalizacaoBg != null) {
      await prefs.setBool(_prefsConsentimentoBgKey, consentimentoLocalizacaoBg);
    }
  }

  Future<void> _mostrarGuiaMotoristaSeNecessario() async {
    final prefs = await SharedPreferences.getInstance();
    final jaViu = prefs.getBool(_prefsGuiaMotoristaKey) ?? false;
    if (jaViu || !mounted) return;
    if (_modalAberto) return;
    final verGuia = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Conheça o app'),
          content: const Text('Quer ver um guia rápido do modo Ecotaxista?'),
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
      await _mostrarGuiaMotorista();
    }
    await prefs.setBool(_prefsGuiaMotoristaKey, true);
  }

  Future<void> _mostrarGuiaMotorista() async {
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    _pausarAtualizacoesParaGuia();
    try {
      final concluido = await showCoachMarks(context, [
        CoachMarkStep(
          targetKey: _guiaConfigKey,
          title: 'Configurações',
          description: 'Edite seus dados do perfil e encontre o botão Sair.',
        ),
        CoachMarkStep(
          targetKey: _guiaTrocarKey,
          title: 'Trocar perfil',
          description: 'Mude para o modo Passageiro.',
        ),
        CoachMarkStep(
          targetKey: _guiaRecebimentoKey,
          title: 'Receber corridas',
          description: 'Ative para ficar disponível e receber solicitações.',
        ),
        CoachMarkStep(
          targetKey: _guiaLocalizacaoBgKey,
          title: 'Localização em segundo plano',
          description: 'Mantém o envio de localização com o app fechado.',
        ),
        CoachMarkStep(
          targetKey: _guiaMapaKey,
          title: 'Mapa e corrida',
          description:
              'Mostra você, origem, destino e rotas. Quando aparecer corrida, você verá botões para aceitar, rejeitar, iniciar e finalizar, além do WhatsApp.',
        ),
      ]);
      if (!concluido || !mounted) return;
      await _mostrarGuiaModalCorrida();
    } finally {
      _retomarAtualizacoesAposGuia();
    }
  }

  void _pausarAtualizacoesParaGuia() {
    if (_guiaAtivo) return;
    _guiaAtivo = true;
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    if (_backgroundAtivo) {
      DriverBackgroundService.stop();
      _backgroundAtivo = false;
    }
  }

  void _retomarAtualizacoesAposGuia() {
    if (!_guiaAtivo) return;
    _guiaAtivo = false;
    if (!mounted) return;
    if (_recebendoCorridas) {
      _verificarCorrida(force: true);
      _iniciarAutoPing();
      _iniciarPollingCorrida();
    }
  }

  List<CoachMarkStep> _buildGuiaCorridaSteps() {
    return [
      CoachMarkStep(
        targetKey: _guiaModalStatusKey,
        title: 'Status da corrida',
        description: 'Mostra se esta aguardando, aceita, em andamento ou concluida.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalPassageiroKey,
        title: 'Passageiro',
        description: 'Veja o nome e o telefone do passageiro.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalWhatsKey,
        title: 'WhatsApp',
        description: 'Fale com o passageiro direto no WhatsApp.',
        highlightPadding: const EdgeInsets.all(6),
      ),
        CoachMarkStep(
          targetKey: _guiaModalRotaKey,
          title: 'Rota',
          description: 'Confirme origem, destino e quantidade de assentos.',
        ),
      CoachMarkStep(
        targetKey: _guiaModalMapaKey,
        title: 'Mapa da corrida',
        description: 'Mostra voce, origem, destino e as rotas.',
      ),
      CoachMarkStep(
        targetKey: _guiaModalAcoesKey,
        title: 'Acoes',
        description:
            'Use Aceitar ou Rejeitar. Depois aparecem Iniciar e Finalizar conforme a corrida avanca.',
      ),
    ];
  }

  Map<String, dynamic> _buildCorridaGuia() {
    final baseLat = _posicao?.latitude ?? MapTileConfig.defaultCenterLat;
    final baseLng = _posicao?.longitude ?? MapTileConfig.defaultCenterLng;
    return {
      'id': 123,
      'status': 'aguardando',
      'origem_lat': baseLat + 0.0012,
      'origem_lng': baseLng + 0.0012,
      'destino_lat': baseLat - 0.0015,
      'destino_lng': baseLng - 0.0010,
      'origem_endereco': 'Praia Jose Bonifacio, Paqueta',
      'destino_endereco': 'Cais da Barca, Paqueta',
      'lugares': 1,
      'motorista_lat': baseLat,
      'motorista_lng': baseLng,
      'cliente': {
        'id': 42,
        'nome': 'Passageiro Exemplo',
        'telefone': '(21) 99999-0000',
      },
    };
  }

  Future<void> _mostrarGuiaModalCorrida() async {
    if (!mounted) return;
    if (_modalAberto || _corridaAtual != null) return;
    await _mostrarModalCorrida(_buildCorridaGuia(), guia: true);
  }

  Future<bool> _mostrarConsentimentoLocalizacaoBg() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Localização em segundo plano'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Para manter você disponível para corridas mesmo com o app fechado, '
                'o Vai Paqueta precisa acessar sua localização em segundo plano.',
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.near_me, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Conectar você a corridas próximas enquanto estiver disponível.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Enviar sua posição periodicamente, mesmo em segundo plano.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.toggle_off, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Você pode desativar a qualquer momento nas configurações do Ecotaxista.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Se você negar, o app continua funcionando, mas você só receberá corridas com o app aberto.',
              ),
              const SizedBox(height: 12),
              const Text('Ao continuar, solicitaremos a permissão de localização em segundo plano.'),
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

  Future<bool> _mostrarConsentimentoLocalizacaoForeground() async {
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
                'Para receber corridas e mostrar sua posição no mapa, o Vai Paquetá precisa acessar '
                'sua localização enquanto o app estiver aberto.',
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.map_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Mostra você no mapa e calcula rotas.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.directions_car_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Usa sua posição para receber corridas quando você estiver disponível.',
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

  Future<bool> _mostrarConsentimentoNotificacao() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Permitir notificações'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ative as notificações para receber avisos de corridas e atualizações importantes.',
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.notifications_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Alertas quando houver corrida disponível.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Você pode ajustar isso nas configurações do Android.',
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

  Future<void> _solicitarPermissaoNotificacao() async {
    final prefs = await SharedPreferences.getInstance();
    final jaPediu = prefs.getBool(_prefsConsentimentoNotificacaoKey) ?? false;
    if (jaPediu) return;
    final aceitou = await _mostrarConsentimentoNotificacao();
    await prefs.setBool(_prefsConsentimentoNotificacaoKey, true);
    if (!aceitou) return;
    await NotificationService.requestPermissions();
  }

  Future<bool> _garantirConsentimentoLocalizacaoBg() async {
    if (_consentimentoLocalizacaoBg) return true;
    final aceitou = await _mostrarConsentimentoLocalizacaoBg();
    if (!aceitou) return false;
    if (!mounted) return false;
    setState(() => _consentimentoLocalizacaoBg = true);
    await _salvarPreferencias(consentimentoLocalizacaoBg: true);
    return true;
  }

  Future<bool> _garantirPermissaoLocalizacao() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  Future<bool> _garantirPermissaoLocalizacaoForeground() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      final aceitou = await _mostrarConsentimentoLocalizacaoForeground();
      if (!aceitou) return false;
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  TileProvider _buildTileProvider() {
    return _tileUsingAssets ? AssetTileProvider() : MapTileCacheService.networkTileProvider();
  }

  Future<Position?> _posicaoAtual({
    bool solicitarPermissao = false,
  }) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && solicitarPermissao) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (e) {
      return null;
    }
  }

  Future<void> _configurarFonteTiles() async {
    if (MapTileConfig.useAssets) {
      final manifest = await _carregarManifesto();
      final zooms = _extrairZooms(manifest);
      final minZoom = zooms.isNotEmpty ? zooms.reduce((a, b) => a < b ? a : b) : MapTileConfig.assetsMinZoom;
      final maxZoom = zooms.isNotEmpty ? zooms.reduce((a, b) => a > b ? a : b) : MapTileConfig.assetsMaxZoom;
      if (!mounted) return;
      setState(() {
        _tileUsingAssets = true;
        _tileUrl = MapTileConfig.assetsTemplate;
        _tileMinNativeZoom = minZoom;
        _tileMaxNativeZoom = maxZoom;
        _assetsMinNativeZoom = _tileMinNativeZoom;
        _assetsMaxNativeZoom = _tileMaxNativeZoom;
        _usandoFallbackRede = false;
      });
      await _avaliarTilesPara(_posicao ?? const LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng));
      return;
    }
    if (!mounted) return;
    setState(() {
      _tileUsingAssets = false;
      _tileUrl = MapTileConfig.networkTemplate;
      _tileMinNativeZoom = null;
      _tileMaxNativeZoom = null;
      _usandoFallbackRede = false;
    });
  }

  String _buildRouteKey(LatLng start, LatLng end) {
    return '${start.latitude.toStringAsFixed(6)},${start.longitude.toStringAsFixed(6)}'
        '|${end.latitude.toStringAsFixed(6)},${end.longitude.toStringAsFixed(6)}';
  }

  Future<List<LatLng>> _fetchRoute(LatLng start, LatLng end) async {
    return _routeService.fetchRoute(start: start, end: end);
  }

  Future<void> _carregarRotaMotorista(LatLng start, LatLng end) async {
    final key = _buildRouteKey(start, end);
    if (_rotaMotoristaKey == key) return;
    _rotaMotoristaKey = key;
    final rota = await _fetchRoute(start, end);
    if (!mounted) return;
    setState(() => _rotaMotorista = rota);
    if (_modalAberto) {
      _modalSetState?.call(() {});
    }
  }

  Future<void> _carregarRotaCorrida(LatLng origem, LatLng destino) async {
    final key = _buildRouteKey(origem, destino);
    if (_rotaCorridaKey == key) return;
    _rotaCorridaKey = key;
    final rota = await _fetchRoute(origem, destino);
    if (!mounted) return;
    setState(() => _rotaCorrida = rota);
    if (_modalAberto) {
      _modalSetState?.call(() {});
    }
  }

  void _limparRotas() {
    if (!mounted) return;
    setState(() {
      _rotaMotorista = [];
      _rotaCorrida = [];
                          _rotaMotoristaKey = null;
                          _rotaCorridaKey = null;    });
                  if (_modalAberto) {
                    _modalSetState?.call(() {});
                  }  }

  void _atualizarRotas(Map<String, dynamic> corrida) {
    final origem = _latLngFromMap(corrida, 'origem_lat', 'origem_lng');
    final destino = _latLngFromMap(corrida, 'destino_lat', 'destino_lng');
    if (origem != null && destino != null) {
      _carregarRotaCorrida(origem, destino);
    } else {
      _rotaCorridaKey = null;
      if (mounted) setState(() => _rotaCorrida = []);
    }
    final status = _normalizarStatus(corrida['status'] as String?);
    final motorista = _posicao ?? _latLngFromMap(corrida, 'motorista_lat', 'motorista_lng');
    final alvo = status == 'em_andamento' ? destino : origem;
    if (motorista != null && alvo != null) {
      _carregarRotaMotorista(motorista, alvo);
    } else {
      _rotaMotoristaKey = null;
      if (mounted) setState(() => _rotaMotorista = []);
    }
  }

  Future<Map<String, dynamic>?> _carregarManifesto() async {
    try {
      final jsonStr = await rootBundle.loadString('AssetManifest.json');
      return json.decode(jsonStr) as Map<String, dynamic>;
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
        return status?.trim().isNotEmpty == true ? status!.trim() : 'Status atualizado';
    }
  }

  String _statusHintMotorista(String? status) {
    switch (_normalizarStatus(status)) {
      case 'aguardando':
        return 'Corrida aguardando sua confirmação.';
      case 'aceita':
        return 'Siga até a origem e inicie a corrida.';
      case 'em_andamento':
        return 'Leve o passageiro ao destino.';
      case 'concluida':
        return 'Corrida concluída.';
      case 'cancelada':
        return 'Corrida cancelada.';
      case 'rejeitada':
        return 'Corrida rejeitada.';
      default:
        return 'Status atualizado.';
    }
  }

  String? _formatLatLng(LatLng? pos) {
    if (pos == null) return null;
    return '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}';
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
      if (_usandoFallbackRede) {
        setState(() {
          _tileUsingAssets = true;
          _tileUrl = MapTileConfig.assetsTemplate;
          _tileMinNativeZoom = _assetsMinNativeZoom ?? MapTileConfig.assetsMinZoom;
          _tileMaxNativeZoom = _assetsMaxNativeZoom ?? MapTileConfig.assetsMaxZoom;
          _usandoFallbackRede = false;
        });
      }
      return;
    }
    if (MapTileConfig.allowNetworkFallback) {
      setState(() {
        _tileUsingAssets = false;
        _tileUrl = MapTileConfig.networkTemplate;
        _tileMinNativeZoom = null;
        _tileMaxNativeZoom = null;
        _usandoFallbackRede = true;
      });
      return;
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
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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

  double? _extrairVelocidadeMps(Position pos) {
    final now = pos.timestamp ?? DateTime.now();
    double? speedMps;
    if (pos.speed.isFinite && pos.speed > 0) {
      speedMps = pos.speed;
    } else if (_ultimaAmostraVelocidade != null && _ultimaAmostraVelocidadeEm != null) {
      final segundos = now.difference(_ultimaAmostraVelocidadeEm!).inMilliseconds / 1000;
      if (segundos >= 1) {
        final distancia = Geolocator.distanceBetween(
          _ultimaAmostraVelocidade!.latitude,
          _ultimaAmostraVelocidade!.longitude,
          pos.latitude,
          pos.longitude,
        );
        speedMps = distancia / segundos;
      }
    }
    _ultimaAmostraVelocidade = LatLng(pos.latitude, pos.longitude);
    _ultimaAmostraVelocidadeEm = now;
    return speedMps;
  }

  Future<void> _avaliarVelocidade(Position pos) async {
    if (!mounted) return;
    if (_appPausado || _guiaAtivo) return;
    if (_avisoVelocidadeAberto) return;
    if (!_corridaEmAndamento()) return;
    final speedMps = _extrairVelocidadeMps(pos);
    if (speedMps == null || !speedMps.isFinite) return;
    final speedKmh = speedMps * 3.6;
    if (speedKmh < DriverSettings.speedWarningThresholdKmh) return;
    final agora = DateTime.now();
    if (_ultimoAvisoVelocidadeEm != null &&
        agora.difference(_ultimoAvisoVelocidadeEm!) < DriverSettings.speedWarningCooldown) {
      return;
    }
    await _mostrarAvisoVelocidade(speedKmh);
  }

  Future<void> _mostrarAvisoVelocidade(double velocidadeKmh) async {
    if (!mounted || _avisoVelocidadeAberto) return;
    _avisoVelocidadeAberto = true;
    _ultimoAvisoVelocidadeEm = DateTime.now();
    try {
      await NotificationService.showSpeedWarning(
        speedKmh: velocidadeKmh,
        limitKmh: DriverSettings.speedWarningThresholdKmh,
        timeoutAfterMs: DriverSettings.speedWarningAutoClose.inMilliseconds,
      );
    } finally {
      _avisoVelocidadeAberto = false;
    }
  }

  bool _corridaEmAndamento() {
    final status = _normalizarStatus(_corridaAtual?['status']?.toString());
    return status == 'em_andamento';
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

  void _updateMapDefaultFromPosition(LatLng pos) {
    final bounds = MapTileConfig.tilesBounds;
    final rawPins = MapViewport.collectPins([pos]);
    final pins = MapViewport.clampPinsToBounds(rawPins, bounds);
    final center = MapViewport.clampCenter(MapViewport.centerForPins(pins), bounds);
    final zoom = MapViewport.zoomForPins(
      pins,
      minZoom: MapTileConfig.displayMinZoom.toDouble(),
      maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
      fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
    );
    _mapDefaultCenter = center;
    _mapDefaultZoom = zoom;
    if (!_mapUserInteracting && _recebendoCorridas && _mapResetAnimation == null) {
      _mapController.move(center, zoom);
    }
  }

  Future<void> _iniciarStreamVelocidade({bool solicitarPermissao = false}) async {
    await _posicaoStreamSub?.cancel();
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && solicitarPermissao) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _velocidadeKmh = null;
        });
      }
      return;
    }
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );
    _posicaoStreamSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      _onPosicaoStream,
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _velocidadeKmh = null;
        });
      },
    );
  }

  void _onPosicaoStream(Position pos) {
    if (!mounted || _appPausado || _guiaAtivo) return;
    final speedMps = _extrairVelocidadeMps(pos);
    final currentSpeedKmh = (speedMps != null && speedMps.isFinite) ? speedMps * 3.6 : null;
    setState(() {
      _posicao = LatLng(pos.latitude, pos.longitude);
      _velocidadeKmh = currentSpeedKmh;
    });
    _updateMapDefaultFromPosition(_posicao!);
    if (_modalAberto) {
      _modalSetState?.call(() {});
    }
    unawaited(_avaliarVelocidade(pos));
  }

  Future<void> _atualizarPosicao() async {
    if (!mounted) return;
    final pos = await _posicaoAtual();
    if (pos != null) {
      setState(() {
        _posicao = LatLng(pos.latitude, pos.longitude);
      });
      _updateMapDefaultFromPosition(_posicao!);
      if (_modalAberto) {
        _modalSetState?.call(() {});
      }
      unawaited(_avaliarVelocidade(pos));
      await _avaliarTilesPara(_posicao);
      if (_corridaAtual != null) {
        _atualizarRotas(_corridaAtual!);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationTapSub = NotificationService.onNotificationTap.listen(_onNotificationTap);
    final pendingTap = NotificationService.consumePendingPayload();
    if (pendingTap != null) {
      _onNotificationTap(pendingTap);
    }
    _configurarFonteTiles();
    if (!MapTileConfig.useAssets) {
      MapTileCacheService.prefetchDefault();
    }
    _atualizarPosicao();
    _iniciarStreamVelocidade();
    _carregarPreferencias();
    _configurarRealtime();
    _authSub = ref.listenManual(authProvider, (_, __) {
      if (!mounted) return;
      _configurarRealtime();
    });
    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (!mounted) return;
      setState(() {
        _compassBearing = event.heading ?? 0;
      });
      if (_modalAberto) { // Check if modal is still open
        _modalSetState?.call(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _solicitarPermissaoNotificacao();
      if (!mounted) return;
      await _mostrarGuiaMotoristaSeNecessario();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    _mapResetTimer?.cancel();
    _mapResetAnimation?.dispose();
    DriverBackgroundService.stop();
    _backgroundAtivo = false;
    _notificationTapSub?.cancel();
    _authSub?.close();
    _compassSub?.cancel();
    _posicaoStreamSub?.cancel();
    _stopRealtime();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _appPausado = true;
      _pingTimer?.cancel();
      _pollTimer?.cancel();
      _mapResetTimer?.cancel();
      _stopMapAnimation();
      _mapUserInteracting = false;
      _posicaoStreamSub?.cancel();
      final user = ref.read(authProvider).valueOrNull;
      final perfilId = user?.perfilId ?? 0;
      final perfilTipo = user?.perfilTipo ?? '';
      if (perfilId != 0 &&
          perfilTipo == 'ecotaxista' &&
          _recebendoCorridas &&
          _enviarLocalizacaoBg &&
          _consentimentoLocalizacaoBg &&
          !_guiaAtivo) {
        DriverBackgroundService.start(perfilId: perfilId, perfilTipo: perfilTipo);
        _backgroundAtivo = true;
      }
    } else if (state == AppLifecycleState.resumed && _appPausado) {
      _appPausado = false;
      if (_backgroundAtivo) {
        DriverBackgroundService.stop();
        _backgroundAtivo = false;
      }
      _atualizarPosicao();
      _iniciarStreamVelocidade();
      if (_recebendoCorridas) {
        if (_wsConnected) {
          _realtime?.sendSync();
        } else {
          _verificarCorrida();
        }
        _iniciarAutoPing();
        _iniciarPollingCorrida();
      }
      if (_corridaAtual != null && !_modalAberto) {
        _mostrarModalCorrida(_corridaAtual!);
      }
    }
  }

  double _round6(double value) => double.parse(value.toStringAsFixed(6));

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  LatLng? _latLngFromMap(Map<String, dynamic> data, String latKey, String lngKey) {
    final lat = _asDouble(data[latKey]);
    final lng = _asDouble(data[lngKey]);
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<void> _enviarPing({bool silencioso = false}) async {
    if (_enviando) return;
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    final perfilTipo = user?.perfilTipo;
    if (perfilId == 0 || perfilTipo != 'ecotaxista') {
      return;
    }

    if (mounted) {
      setState(() {
        _enviando = true;
      });
    }

    final pos = await _posicaoAtual(
      solicitarPermissao: !silencioso,
    );
    if (pos == null) {
      if (mounted) setState(() => _enviando = false);
      return;
    }

    if (mounted) {
      setState(() {
        _posicao = LatLng(pos.latitude, pos.longitude);
      });
    }
    if (_modalAberto) { // Guard for _modalSetState
      _modalSetState?.call(() {});
    }
    unawaited(_avaliarTilesPara(_posicao));
    unawaited(_avaliarVelocidade(pos));

    final speedMps = _extrairVelocidadeMps(pos);
    final currentSpeedKmh = (speedMps != null && speedMps.isFinite) ? speedMps * 3.6 : null;
    if (mounted) {
      setState(() {
        _velocidadeKmh = currentSpeedKmh;
      });
    }

    if (_corridaAtual != null) {
      _atualizarRotas(_corridaAtual!);
    }

    try {
      final lat = _round6(pos.latitude);
      final lng = _round6(pos.longitude);
      if (_wsConnected && _realtime != null) {
        final corridaId = _corridaAtual?['id'];
        _realtime!.sendPing(
          latitude: lat,
          longitude: lng,
          precisaoM: pos.accuracy,
          corridaId: corridaId is int ? corridaId : null,
          bearing: _compassBearing,
        );
      } else {
        final service = DriverService();
        await service.enviarPing(
          perfilId: perfilId,
          latitude: lat,
          longitude: lng,
          precisao: pos.accuracy,
          bearing: _compassBearing,
        );
      }
    } catch (e) {
      debugPrint('Erro ao enviar ping: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _iniciarAutoPing() {
    if (_guiaAtivo) return;
    if (!_recebendoCorridas) return;
    final intervalo = _wsConnected ? DriverSettings.pingIntervalWs : DriverSettings.pingIntervalHttp;
    _pingTimer?.cancel();
    _enviarPing(silencioso: true);
    _pingTimer = Timer.periodic(intervalo, (_) => _enviarPing(silencioso: true));
  }

  void _iniciarPollingCorrida() {
    if (_guiaAtivo) return;
    if (!_recebendoCorridas) return;
    if (_wsConnected) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(DriverSettings.corridaPollingInterval, (_) => _verificarCorrida());
  }

  void _configurarRealtime() {
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    final isDriver = user?.perfilTipo == 'ecotaxista';
    if (!isDriver || perfilId == 0 || !_recebendoCorridas) {
      _stopRealtime();
      return;
    }
    if (_realtime != null && _wsPerfilId == perfilId) return;
    _stopRealtime();
    _wsPerfilId = perfilId;
    _realtime = RealtimeService(
      role: RealtimeRole.driver,
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
    _pollTimer?.cancel();
    _realtime?.sendSync();
    _iniciarAutoPing();
  }

  void _onRealtimeDisconnected() {
    if (!mounted) return;
    setState(() => _wsConnected = false);
    _iniciarAutoPing();
    if (_recebendoCorridas) {
      _iniciarPollingCorrida();
    }
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == null) return;
    if (type == 'ride_update' || type == 'ride_assigned' || type == 'ride_created') {
      final raw = event['corrida'];
      if (raw is Map) {
        final corrida = Map<String, dynamic>.from(raw);
        _aplicarCorridaAtual(corrida);
      } else if (raw == null) {
        _aplicarCorridaAtual(null);
      }
    }
  }

  void _aplicarCorridaAtual(Map<String, dynamic>? corrida) {
    if (corrida == null || corrida.isEmpty) {
      _corridaAtual = null;
      _ultimaCorridaAlertada = null;
      _limparRotas();
      if (_modalAberto && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _modalAberto = false;
        _modalSetState = null;
      }
      return;
    }
    final status = _normalizarStatus(corrida['status']?.toString());
    if (!['aguardando', 'aceita', 'em_andamento'].contains(status)) {
      _corridaAtual = null;
      _ultimaCorridaAlertada = null;
      _limparRotas();
      if (_modalAberto && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _modalAberto = false;
        _modalSetState = null;
      }
      return;
    }
    _corridaAtual = corrida;
    _alertarNovaCorridaSeNecessario(corrida);
    _atualizarRotas(corrida);
    if (_modalAberto) {
      _modalSetState?.call(() {});
    } else {
      _mostrarModalCorrida(corrida);
    }
  }

  Future<void> _verificarCorrida({bool force = false}) async {
    if (_appPausado && !force) return;
    if (_guiaAtivo && !force) return;
    if (!_recebendoCorridas && !force) return;
    if (_wsConnected && !force) return;
    final authState = ref.read(authProvider);
    var user = authState.valueOrNull;
    if (user == null && authState.isLoading) {
      try {
        user = await ref.read(authProvider.future);
      } catch (_) {
        return;
      }
    }
    final perfilId = user?.perfilId ?? 0;
    if (perfilId == 0 || user?.perfilTipo != 'ecotaxista') return;
    try {
      final service = DriverService();
      final corrida = await service.corridaAtribuida(perfilId);
      if (_guiaAtivo) return;
      _aplicarCorridaAtual(corrida);
    } catch (e) {
      // silencioso para polling
      debugPrint('Erro ao verificar corrida: ${friendlyError(e)}');
    }
  }

  Future<void> _alertarNovaCorridaSeNecessario(Map<String, dynamic> corrida) async {
    final status = _normalizarStatus(corrida['status']?.toString());
    final corridaId = corrida['id'] is int ? corrida['id'] as int : null;
    if (status != 'aguardando' || corridaId == null) return;
    if (_ultimaCorridaAlertada == corridaId) return;
    _ultimaCorridaAlertada = corridaId;
    try {
      await NotificationService.showRideAvailable(
        id: corridaId,
        title: 'Nova corrida disponível',
        body: 'Confirme para aceitar a corrida.',
        payload: 'ride:$corridaId',
      );
    } catch (_) {}
    await SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _mostrarModalCorrida(Map<String, dynamic> corrida, {bool guia = false}) async {
    if (_modalAberto) return;
    _modalAberto = true;
    final corridaAnterior = _corridaAtual;
    _corridaAtual = corrida;
    if (!mounted) {
      _modalAberto = false;
      _corridaAtual = corridaAnterior;
      return;
    }
    await Future<void>.delayed(Duration.zero);
    var guiaIniciado = false;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Corrida',
        barrierColor: Colors.black54,
        transitionDuration: UiTimings.modalTransition,
        pageBuilder: (ctx, anim, __) {
          return SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Material(
                  color: Theme.of(context).dialogTheme.backgroundColor,
                  borderRadius: BorderRadius.circular(16),
                  child: StatefulBuilder(builder: (dialogContext, setModalState) {
                    _modalSetState = setModalState;
                    if (guia && !guiaIniciado) {
                      guiaIniciado = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                        if (!mounted) return;
                        await showCoachMarks(dialogContext, _buildGuiaCorridaSteps());
                        if (mounted && Navigator.of(dialogContext, rootNavigator: true).canPop()) {
                          Navigator.of(dialogContext, rootNavigator: true).pop();
                        }
                      });
                    }
                    final corridaAtual = _corridaAtual ?? corrida;
                    final statusRaw = corridaAtual['status'] as String?;
                    final status = _normalizarStatus(statusRaw);
                    final statusLabel = _statusLabel(statusRaw);
                    final statusHint = _statusHintMotorista(statusRaw);
                    final origem = (() {
                      final lat = _asDouble(corridaAtual['origem_lat']);
                      final lng = _asDouble(corridaAtual['origem_lng']);
                      if (lat == null || lng == null) return null;
                      return LatLng(lat, lng);
                    })();
                    final destino = (() {
                      final lat = _asDouble(corridaAtual['destino_lat']);
                      final lng = _asDouble(corridaAtual['destino_lng']);
                      if (lat == null || lng == null) return null;
                      return LatLng(lat, lng);
                    })();
                    final passageiroNome = (() {
                      final cliente = corridaAtual['cliente'];
                      if (cliente is Map<String, dynamic>) {
                        final nome = (cliente['nome'] as String?)?.trim();
                        if (nome != null && nome.isNotEmpty) return nome;
                        final id = cliente['id'];
                        if (id != null) return 'Passageiro #$id';
                      }
                      return null;
                    })();
                    final passageiroTelefone = (() {
                      final cliente = corridaAtual['cliente'];
                      if (cliente is Map<String, dynamic>) {
                        final telefone = (cliente['telefone'] as String?)?.trim();
                        if (telefone != null && telefone.isNotEmpty) return telefone;
                      }
                      return null;
                    })();
                    final origemEndereco = (corridaAtual['origem_endereco'] as String?)?.trim();
                    final destinoEndereco = (corridaAtual['destino_endereco'] as String?)?.trim();
                    final origemTexto = origemEndereco != null && origemEndereco.isNotEmpty
                        ? origemEndereco
                        : (_formatLatLng(origem) ?? '—');
                    final destinoTexto = destinoEndereco != null && destinoEndereco.isNotEmpty
                        ? destinoEndereco
                        : (_formatLatLng(destino) ?? '—');
                    final passengerWhatsLink = _buildWhatsAppLink(passageiroTelefone);
                    final motoristaPos = _posicao ?? (() {
                      final lat = _asDouble(corridaAtual['motorista_lat']);
                      final lng = _asDouble(corridaAtual['motorista_lng']);
                      if (lat == null || lng == null) return null;
                      return LatLng(lat, lng);
                    })();
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
                            Container(
                              key: _guiaModalStatusKey,
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
                                    statusLabel,
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(statusHint, style: Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final passengerCard = KeyedSubtree(
                                  key: _guiaModalPassageiroKey,
                                  child: _infoBox(
                                    context,
                                    'Passageiro',
                                    [
                                      Text(passageiroNome ?? 'Passageiro confirmado',
                                          style: Theme.of(context).textTheme.bodyMedium),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            passageiroTelefone ?? 'Telefone não informado',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(color: Colors.grey.shade700),
                                          ),
                                          if (passengerWhatsLink != null)
                                            OutlinedButton.icon(
                                              key: _guiaModalWhatsKey,
                                              onPressed: guia ? null : () => _abrirWhatsApp(passageiroTelefone),
                                              icon: const Icon(Icons.chat_bubble_outline, size: 18),
                                              label: const Text('WhatsApp'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                                final lugares = _asInt(corridaAtual['lugares']) ?? 1;
                                final routeCard = KeyedSubtree(
                                  key: _guiaModalRotaKey,
                                  child: _infoBox(
                                    context,
                                    'Rota',
                                    [
                                      Text('Origem: $origemTexto', style: Theme.of(context).textTheme.bodyMedium),
                                      const SizedBox(height: 4),
                                      Text('Destino: $destinoTexto', style: Theme.of(context).textTheme.bodyMedium),
                                      const SizedBox(height: 4),
                                      Text('Assentos: $lugares', style: Theme.of(context).textTheme.bodyMedium),
                                    ],
                                  ),
                                );
                                if (constraints.maxWidth >= 520) {
                                  return Row(
                                    children: [
                                      Expanded(child: passengerCard),
                                      const SizedBox(width: 12),
                                      Expanded(child: routeCard),
                                    ],
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    passengerCard,
                                    const SizedBox(height: 12),
                                    routeCard,
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 12),
                            if (origem != null || destino != null || motoristaPos != null)
                              SizedBox(
                                key: _guiaModalMapaKey,
                                height: 220,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Builder(
                                    builder: (context) {
                                      final bounds = MapTileConfig.tilesBounds;
                                      final rawPins = MapViewport.collectPins([origem, destino, motoristaPos]);
                                      final pins = MapViewport.clampPinsToBounds(rawPins, bounds);
                                      final center = MapViewport.clampCenter(
                                        MapViewport.centerForPins(pins),
                                        bounds,
                                      );
                                      final zoom = MapViewport.zoomForPins(
                                        pins,
                                        minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                        maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                        fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
                                      );
                                      final fitBounds = MapViewport.boundsForPins(pins);
                                      final fit = fitBounds == null
                                          ? null
                                          : CameraFit.bounds(
                                              bounds: fitBounds,
                                              padding: const EdgeInsets.all(24),
                                              minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                              maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                            );
                                      final key = ValueKey(
                                        'driver-modal-${fitBounds == null ? zoom.toStringAsFixed(2) : 'fit'}-${MapViewport.signatureForPins(pins)}',
                                      );
                                      return FlutterMap(
                                        key: key,
                                        options: MapOptions(
                                          initialCenter: center,
                                          initialZoom: zoom,
                                          initialCameraFit: fit,
                                          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                                          cameraConstraint: CameraConstraint.contain(bounds: bounds),
                                          minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                          maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                        ),
                                        children: [
                                          TileLayer(
                                            urlTemplate: _tileUrl,
                                            tileProvider: _buildTileProvider(),
                                            userAgentPackageName: 'com.example.vai_paqueta_app',
                                            minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                            maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                            minNativeZoom: _tileMinNativeZoom ?? MapTileConfig.assetsMinZoom,
                                            maxNativeZoom: _tileMaxNativeZoom ?? MapTileConfig.assetsMaxZoom,
                                            tileBounds: bounds,
                                          ),
                                          if (_rotaCorrida.length >= 2)
                                            PolylineLayer(
                                              polylines: [
                                                Polyline(
                                                  points: _rotaCorrida,
                                                  strokeWidth: 3,
                                                  color: Colors.blueAccent,
                                                ),
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
                                              if (motoristaPos != null)
                                                                                                  Marker(
                                                                                                    point: motoristaPos,
                                                                                                    width: 54, // Adjusted for 1536x1024 aspect ratio (1.5 * 36)
                                                                                                    height: 36,
                                                                                                                                                                                                        child: Transform.rotate(
                                                                                                                                                                                                          angle: (_compassBearing) * (math.pi / 180),
                                                                                                                                                                                                          child: Image.asset('assets/icons/ecotaxi.png', width: 54, height: 36), // Adjusted for 1536x1024 aspect ratio
                                                                                                                                                                                                        ),                                                                                                  ),                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Wrap(
                              key: _guiaModalAcoesKey,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (status == 'aguardando')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.check),
                                    label: const Text('Aceitar'),
                                    onPressed: guia ? null : () => _acaoCorrida('aceitar'),
                                  ),
                                if (status == 'aguardando' || status == 'aceita')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.close),
                                    label: const Text('Rejeitar'),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400),
                                    onPressed: guia ? null : () => _acaoCorrida('rejeitar'),
                                  ),
                                if (status == 'aceita')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Iniciar'),
                                    onPressed: guia ? null : () => _acaoCorrida('iniciar'),
                                  ),
                                if (status == 'em_andamento')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.flag),
                                    label: const Text('Finalizar'),
                                    onPressed: guia ? null : () => _acaoCorrida('finalizar'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (ctx, anim, secondary, child) {
          return FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
      );
    } finally {
      _modalAberto = false;
      _modalSetState = null;
      if (guia) {
        _corridaAtual = corridaAnterior;
      }
    }
  }

  Future<void> _acaoCorrida(String acao) async {
    final user = ref.read(authProvider).valueOrNull;
    final corridaId = _corridaAtual?['id'] as int?;
    final perfilId = user?.perfilId ?? 0;
    if (perfilId == 0 || corridaId == null) return;
    try {
      final service = DriverService();
      Map<String, dynamic>? nova;
      switch (acao) {
        case 'aceitar':
          if (mounted) {
            setState(() {
              _exibirRotasNoMapaPrincipal = true;
            });
          }
          nova = await service.aceitarCorrida(corridaId: corridaId, motoristaId: perfilId);
          break;
        case 'iniciar':
          nova = await service.iniciarCorrida(corridaId: corridaId, motoristaId: perfilId);
          break;
        case 'finalizar':
          nova = await service.finalizarCorrida(corridaId: corridaId, motoristaId: perfilId);
          break;
        case 'rejeitar':
          await service.reatribuirCorrida(corridaId, excluirMotoristaId: perfilId);
          _corridaAtual = null;
          _limparRotas();
          _modalSetState?.call(() {});
          if (_modalAberto && mounted) {
            Navigator.of(context, rootNavigator: true).pop();
            _modalAberto = false;
          }
          _verificarCorrida();
          return;
        default:
          return;
      }
      if (nova != null) {
        _corridaAtual = nova;
        _atualizarRotas(nova);
      }
      if (_modalAberto) {
        _modalSetState?.call(() {});
      }
      if (!mounted) return;
      if (acao == 'finalizar' || (nova != null && nova['status'] == 'concluida')) {
        _corridaAtual = null;
        _limparRotas();
        if (mounted) {
          setState(() {
            _exibirRotasNoMapaPrincipal = false;
          });
        }
        if (_modalAberto) {
          Navigator.of(context, rootNavigator: true).pop();
          _modalAberto = false;
          _modalSetState = null;
        }
      }
      if (nova != null && nova['status'] == 'em_andamento' && !_modalAberto) {
        _mostrarModalCorrida(nova);
      }
      if (_modalAberto && nova == null && acao != 'rejeitar') {
        _modalAberto = false;
      }
    } catch (e) {
      debugPrint('Erro ao atualizar corrida: ${friendlyError(e)}');
    }
  }

  void _onNotificationTap(String? payload) {
    if (_guiaAtivo) return;
    _verificarCorrida(force: true);
  }

  void _onToggleRecebimentoCorridas(bool ativo) {
    if (!ativo) {
      _setRecebimentoCorridas(false);
      return;
    }
    unawaited(_habilitarRecebimentoCorridas());
  }

  Future<void> _habilitarRecebimentoCorridas() async {
    final permissaoOk = await _garantirPermissaoLocalizacaoForeground();
    if (!permissaoOk) {
      _setRecebimentoCorridas(false, forceRebuild: true);
      return;
    }
    _setRecebimentoCorridas(true);
    _iniciarStreamVelocidade();
  }

  void _setRecebimentoCorridas(
    bool ativo, {
    bool salvarPreferencias = true,
    bool forceRebuild = false,
  }) {
    final mudou = _recebendoCorridas != ativo;
    if (mounted && (mudou || forceRebuild)) {
      setState(() {
        if (mudou) {
          _recebendoCorridas = ativo;
        }
      });
    }
    if (salvarPreferencias) {
      _salvarPreferencias(recebendoCorridas: ativo);
    }
    if (ativo) {
      _configurarRealtime();
      _verificarCorrida(force: true);
      _iniciarAutoPing();
      _iniciarPollingCorrida();
      return;
    }
    _configurarRealtime();
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    if (_backgroundAtivo) {
      DriverBackgroundService.stop();
      _backgroundAtivo = false;
    }
  }

  void _onToggleLocalizacaoSegundoPlano(bool ativo) {
    if (!ativo) {
      _setLocalizacaoSegundoPlano(false);
      return;
    }
    unawaited(_habilitarLocalizacaoSegundoPlano());
  }

  Future<void> _habilitarLocalizacaoSegundoPlano() async {
    final consentimentoOk = await _garantirConsentimentoLocalizacaoBg();
    if (!consentimentoOk) {
      _setLocalizacaoSegundoPlano(false, forceRebuild: true);
      return;
    }
    final permissaoOk = await _garantirPermissaoLocalizacao();
    if (!permissaoOk) {
      _setLocalizacaoSegundoPlano(false, forceRebuild: true);
      return;
    }
    _setLocalizacaoSegundoPlano(true);
  }

  void _setLocalizacaoSegundoPlano(
    bool ativo, {
    bool salvarPreferencias = true,
    bool forceRebuild = false,
  }) {
    final mudou = _enviarLocalizacaoBg != ativo;
    if (mounted && (mudou || forceRebuild)) {
      setState(() {
        if (mudou) {
          _enviarLocalizacaoBg = ativo;
        }
      });
    }
    if (salvarPreferencias) {
      _salvarPreferencias(localizacaoBg: ativo);
    }
    if (!ativo && _backgroundAtivo) {
      DriverBackgroundService.stop();
      _backgroundAtivo = false;
    }
  }

  Future<void> _trocarParaPassageiro() async {
    setState(() {
      _trocandoPerfil = true;
    });
    try {
      await DriverBackgroundService.stop();
      _backgroundAtivo = false;
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: 'passageiro');
      if (!mounted) return;
      context.go('/passageiro');
    } catch (e) {
      debugPrint('Erro ao trocar para Passageiro: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _trocandoPerfil = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Ecotaxista'),
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
          if (_trocandoPerfil)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              key: _guiaTrocarKey,
              tooltip: 'Ir para Passageiro',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _trocarParaPassageiro,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                elevation: 0,
                color: Colors.grey.shade50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      key: _guiaRecebimentoKey,
                      value: _recebendoCorridas,
                      onChanged: _onToggleRecebimentoCorridas,
                      title: const Text('Receber Corridas'),
                      subtitle: const Text('Fique disponível para corridas.'),
                    ),
                    Divider(height: 1, color: Colors.grey.shade200),
                    SwitchListTile.adaptive(
                      key: _guiaLocalizacaoBgKey,
                      value: _enviarLocalizacaoBg,
                      onChanged: _onToggleLocalizacaoSegundoPlano,
                      title: const Text('Receber corridas em segundo plano'),
                      subtitle: const Text('Enviar localização e receber corridas com app em segundo plano.'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SizedBox(
                      key: _guiaMapaKey,
                      child: AspectRatio(
                        aspectRatio: 1.0,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Builder(
                            builder: (context) {
                              Widget mapChild;
                              if (_posicao == null) {
                                mapChild = Container(
                                  color: Colors.grey.shade100,
                                  child: const Center(child: Text('Localização não disponível')),
                                );
                              } else if (_recebendoCorridas) {
                                final bounds = MapTileConfig.tilesBounds;
                                final rawPins = MapViewport.collectPins([_posicao]);
                                final pins = MapViewport.clampPinsToBounds(rawPins, bounds);
                                final center = MapViewport.clampCenter(
                                  MapViewport.centerForPins(pins),
                                  bounds,
                                );
                                final zoom = MapViewport.zoomForPins(
                                  pins,
                                  minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                  maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                  fallbackZoom: MapTileConfig.assetsSampleZoom.toDouble(),
                                );
                                _mapDefaultCenter = center;
                                _mapDefaultZoom = zoom;
                                final fitBounds = MapViewport.boundsForPins(pins);
                                final fit = fitBounds == null
                                    ? null
                                    : CameraFit.bounds(
                                        bounds: fitBounds,
                                        padding: const EdgeInsets.all(24),
                                        minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                        maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                      );
                                mapChild = FlutterMap(
                                  mapController: _mapController,
                                  options: MapOptions(
                                    initialCenter: center,
                                    initialZoom: zoom,
                                    initialCameraFit: fit,
                                    interactionOptions: const InteractionOptions(
                                      flags: InteractiveFlag.drag |
                                          InteractiveFlag.pinchZoom |
                                          InteractiveFlag.doubleTapZoom |
                                          InteractiveFlag.flingAnimation,
                                    ),
                                    onPositionChanged: (position, hasGesture) {
                                      _mapLastCenter = position.center;
                                      _mapLastZoom = position.zoom;
                                      if (hasGesture) {
                                        _stopMapAnimation();
                                        _scheduleMapReset();
                                      }
                                    },
                                    cameraConstraint: CameraConstraint.contain(bounds: bounds),
                                    minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                    maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                  ),
                                  children: [
                                    TileLayer(
                                      urlTemplate: _tileUrl,
                                      tileProvider: _buildTileProvider(),
                                      userAgentPackageName: 'com.example.vai_paqueta_app',
                                      minZoom: MapTileConfig.displayMinZoom.toDouble(),
                                      maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                                      minNativeZoom: _tileMinNativeZoom ?? MapTileConfig.assetsMinZoom,
                                      maxNativeZoom: _tileMaxNativeZoom ?? MapTileConfig.assetsMaxZoom,
                                      tileBounds: bounds,
                                    ),
                                    if (_exibirRotasNoMapaPrincipal && _rotaMotorista.length >= 2)
                                      PolylineLayer(
                                        polylines: [
                                          Polyline(
                                            points: _rotaMotorista,
                                            strokeWidth: 3,
                                            color: Colors.orangeAccent,
                                          ),
                                        ],
                                      ),
                                    if (_exibirRotasNoMapaPrincipal && _rotaCorrida.length >= 2)
                                      PolylineLayer(
                                        polylines: [
                                          Polyline(
                                            points: _rotaCorrida,
                                            strokeWidth: 3,
                                            color: Colors.blueAccent,
                                          ),
                                        ],
                                      ),
                                    MarkerLayer(
                                      markers: [
                                        Marker(
                                          point: _posicao!,
                                          width: 54,
                                          height: 36,
                                          child: Transform.rotate(
                                            angle: (_compassBearing) * (math.pi / 180),
                                            child: Image.asset('assets/icons/ecotaxi.png', width: 54, height: 36),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              } else {
                                mapChild = Container(
                                  color: Colors.grey.shade100,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Text(
                                          'Você está offline para corridas.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.grey, fontSize: 16),
                                        ),
                                        SizedBox(height: 8),
                                        Text.rich(
                                          TextSpan(
                                            children: [
                                              const TextSpan(
                                                text: 'Ative "Receber Corridas" ',
                                                style: TextStyle(color: Colors.grey, fontSize: 14),
                                              ),
                                              const WidgetSpan(
                                                alignment: PlaceholderAlignment.middle,
                                                child: Icon(Icons.toggle_on, color: Colors.grey, size: 20),
                                              ),
                                              const TextSpan(
                                                text: ' para ficar disponível.',
                                                style: TextStyle(color: Colors.grey, fontSize: 14),
                                              ),
                                            ],
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        SizedBox(height: 4),
                                        Text.rich(
                                          TextSpan(
                                            children: [
                                              const TextSpan(
                                                text: 'Ative "Receber corridas em segundo plano" ',
                                                style: TextStyle(color: Colors.grey, fontSize: 14),
                                              ),
                                              const WidgetSpan(
                                                alignment: PlaceholderAlignment.middle,
                                                child: Icon(Icons.toggle_on, color: Colors.grey, size: 20),
                                              ),
                                              const TextSpan(
                                                text: ' para sempre estar disponível.',
                                                style: TextStyle(color: Colors.grey, fontSize: 14),
                                              ),
                                            ],
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }

                              return Stack(
                                children: [
                                  Positioned.fill(child: mapChild),
                                  Positioned(
                                    right: 12,
                                    bottom: 12,
                                    child: _SpeedometerCard(
                                      speedKmh: _velocidadeKmh,
                                      warningKmh: DriverSettings.speedWarningThresholdKmh,
                                      compact: true,
                                      backgroundColor: Colors.black.withOpacity(0.2),
                                      borderColor: Colors.transparent,
                                      textColor: Colors.white,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

          ],
        ),
      ),
    ),
    );
  }
}

class _SpeedometerCard extends StatelessWidget {
  const _SpeedometerCard({
    required this.speedKmh,
    required this.warningKmh,
    this.compact = false,
    this.backgroundColor,
    this.borderColor,
    this.textColor,
  });

  final double? speedKmh;
  final double warningKmh;
  final bool compact;
  final Color? backgroundColor;
  final Color? borderColor;
  final Color? textColor;

  Color _resolveSpeedColor(Color base, double speed, double warning) {
    if (speed <= 0) return base;
    if (speed >= warning) return Colors.redAccent;
    if (speed >= warning * 0.8) return Colors.orangeAccent;
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speed = speedKmh ?? 0;
    final maxKmh = math.max(warningKmh * 1.3, 120);
    final progress = (speed / maxKmh).clamp(0.0, 1.0);
    final baseColor = theme.colorScheme.primary;
    final accentColor = _resolveSpeedColor(baseColor, speed, warningKmh);
    final displaySpeed = speedKmh == null ? '--' : speedKmh!.toStringAsFixed(0);
    final displayTitle = compact ? 'Veloc.' : 'Velocímetro';
    final primaryTextColor = textColor ?? theme.textTheme.bodyMedium?.color;
    final secondaryTextColor = textColor != null ? textColor!.withOpacity(0.85) : Colors.grey.shade600;

    return Card(
      elevation: 0,
      color: backgroundColor ?? Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor ?? Colors.grey.shade200),
      ),
      child: Padding(
        padding: compact ? const EdgeInsets.all(8) : const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayTitle,
              style: (compact ? theme.textTheme.labelMedium : theme.textTheme.titleMedium)
                  ?.copyWith(color: primaryTextColor),
            ),
            SizedBox(height: compact ? 4 : 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final size = math.min(constraints.maxWidth, compact ? 120.0 : 180.0);
                return SizedBox.square(
                  dimension: size,
                  child: CustomPaint(
                    painter: _SpeedometerPainter(
                      progress: progress,
                      progressColor: accentColor,
                      backgroundColor: Colors.grey.shade300,
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displaySpeed,
                            style: (compact ? theme.textTheme.headlineSmall : theme.textTheme.displaySmall)?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                            ),
                          ),
                          Text(
                            'km/h',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: secondaryTextColor,
                              fontSize: compact ? 10 : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (speedKmh == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Aguardando sinal GPS',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: secondaryTextColor,
                    fontSize: compact ? 10 : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpeedometerPainter extends CustomPainter {
  _SpeedometerPainter({
    required this.progress,
    required this.progressColor,
    required this.backgroundColor,
  });

  final double progress;
  final Color progressColor;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final strokeWidth = size.width * 0.08;
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = 3 * math.pi / 4;
    const sweepAngle = 3 * math.pi / 2;

    final basePaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, sweepAngle, false, basePaint);

    final progressPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, sweepAngle * progress, false, progressPaint);

    final tickPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = strokeWidth * 0.18
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 10; i += 1) {
      final t = i / 10;
      final angle = startAngle + sweepAngle * t;
      final inner = center + Offset(math.cos(angle), math.sin(angle)) * (radius - strokeWidth * 0.4);
      final outer = center + Offset(math.cos(angle), math.sin(angle)) * (radius + strokeWidth * 0.1);
      canvas.drawLine(inner, outer, tickPaint);
    }

    final needleAngle = startAngle + sweepAngle * progress;
    final needleLength = radius - strokeWidth * 0.9;
    final needlePaint = Paint()
      ..color = progressColor
      ..strokeWidth = strokeWidth * 0.35
      ..strokeCap = StrokeCap.round;
    final needleEnd = center + Offset(math.cos(needleAngle), math.sin(needleAngle)) * needleLength;
    canvas.drawLine(center, needleEnd, needlePaint);

    final hubPaint = Paint()..color = progressColor;
    canvas.drawCircle(center, strokeWidth * 0.35, hubPaint);
  }

  @override
  bool shouldRepaint(_SpeedometerPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
