import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/error_messages.dart';
import '../../core/map_config.dart';
import '../../core/map_viewport.dart';
import '../../services/driver_background_service.dart';
import '../../services/map_tile_cache_service.dart';
import '../../services/notification_service.dart';
import '../../services/route_service.dart';
import '../../widgets/message_banner.dart';
import '../../widgets/coach_mark.dart';
import '../auth/auth_provider.dart';
import 'driver_service.dart';

class DriverPage extends ConsumerStatefulWidget {
  const DriverPage({super.key});

  @override
  ConsumerState<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends ConsumerState<DriverPage> with WidgetsBindingObserver {
  static const _prefsRecebendoCorridasKey = 'driver_recebendo_corridas';
  static const _prefsLocalizacaoBgKey = 'driver_localizacao_bg';
  static const _prefsConsentimentoBgKey = 'driver_localizacao_bg_consentimento';
  static const _prefsGuiaMotoristaKey = 'motorista_guia_visto';
  final GlobalKey _guiaConfigKey = GlobalKey();
  final GlobalKey _guiaLogoutKey = GlobalKey();
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
  AppMessage? _status;
  bool _enviando = false;
  LatLng? _posicao;
  bool _tileUsingAssets = MapTileConfig.useAssets;
  String _tileUrl = MapTileConfig.useAssets ? MapTileConfig.assetsTemplate : MapTileConfig.networkTemplate;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  int? _assetsMinNativeZoom;
  int? _assetsMaxNativeZoom;
  bool _usandoFallbackRede = false;
  bool _alertaTiles = false;
  Timer? _pingTimer;
  Timer? _pollTimer;
  final RouteService _routeService = RouteService();
  List<LatLng> _rotaMotorista = [];
  List<LatLng> _rotaCorrida = [];
  String? _rotaMotoristaKey;
  String? _rotaCorridaKey;
  bool _modalAberto = false;
  Map<String, dynamic>? _corridaAtual;
  bool _trocandoPerfil = false;
  bool _appPausado = false;
  StateSetter? _modalSetState;
  bool _backgroundAtivo = false;
  bool _recebendoCorridas = true;
  bool _enviarLocalizacaoBg = false;
  bool _consentimentoLocalizacaoBg = false;
  bool _guiaAtivo = false;
  StreamSubscription<String?>? _notificationTapSub;

  void _clearStatus() {
    if (!mounted) {
      _status = null;
      return;
    }
    setState(() => _status = null);
  }

  Future<void> _carregarPreferencias() async {
    final prefs = await SharedPreferences.getInstance();
    final recebendo = prefs.getBool(_prefsRecebendoCorridasKey) ?? true;
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
          description: 'Edite seus dados do perfil.',
        ),
        CoachMarkStep(
          targetKey: _guiaTrocarKey,
          title: 'Trocar perfil',
          description: 'Mude para o modo Passageiro.',
        ),
        CoachMarkStep(
          targetKey: _guiaLogoutKey,
          title: 'Sair',
          description: 'Encerre sua sessão no app.',
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
      _iniciarAutoPing(showStatus: false);
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
        description: 'Confirme origem, destino e quantidade de lugares.',
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
              child: const Text('Aceitar e continuar'),
            ),
          ],
        );
      },
    );
    return result ?? false;
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
      if (mounted) {
        setState(
          () => _status = const AppMessage(
            'Permissão de localização necessária para enviar em segundo plano.',
            MessageTone.warning,
          ),
        );
      }
      return false;
    }
    if (permission == LocationPermission.whileInUse && mounted) {
      setState(
        () => _status = const AppMessage(
          'Para enviar em segundo plano, permita localização o tempo todo nas permissões do app.',
          MessageTone.info,
        ),
      );
    }
    return true;
  }

  TileProvider _buildTileProvider() {
    return _tileUsingAssets ? AssetTileProvider() : MapTileCacheService.networkTileProvider();
  }
  Future<void> _logout() async {
    await DriverBackgroundService.stop();
    _backgroundAtivo = false;
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    context.go('/auth');
  }

  Future<Position?> _posicaoAtual() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        setState(() => _status = const AppMessage('Permissão de localização negada.', MessageTone.error));
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (e) {
      setState(() => _status = AppMessage('Erro ao obter localização: ${friendlyError(e)}', MessageTone.error));
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
      await _avaliarTilesPara(_posicao ?? LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng));
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
    _modalSetState?.call(() {});
  }

  Future<void> _carregarRotaCorrida(LatLng origem, LatLng destino) async {
    final key = _buildRouteKey(origem, destino);
    if (_rotaCorridaKey == key) return;
    _rotaCorridaKey = key;
    final rota = await _fetchRoute(origem, destino);
    if (!mounted) return;
    setState(() => _rotaCorrida = rota);
    _modalSetState?.call(() {});
  }

  void _limparRotas() {
    if (!mounted) return;
    setState(() {
      _rotaMotorista = [];
      _rotaCorrida = [];
      _rotaMotoristaKey = null;
      _rotaCorridaKey = null;
    });
    _modalSetState?.call(() {});
  }

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
      _alertaTiles = false;
      return;
    }
    if (MapTileConfig.allowNetworkFallback) {
      setState(() {
        _tileUsingAssets = false;
        _tileUrl = MapTileConfig.networkTemplate;
        _tileMinNativeZoom = null;
        _tileMaxNativeZoom = null;
        _usandoFallbackRede = true;
        _status = const AppMessage('Mapa offline indisponível aqui. Usando mapa online.', MessageTone.info);
      });
      return;
    }
    if (!_alertaTiles) {
      setState(() {
        _status = const AppMessage(
          'Área fora do mapa offline. Ajuste o GPS ou baixe mais tiles.',
          MessageTone.warning,
        );
      });
      _alertaTiles = true;
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
    if (!ok && mounted) {
      setState(() => _status = const AppMessage('Não foi possível abrir o WhatsApp.', MessageTone.error));
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

  Future<void> _atualizarPosicao() async {
    if (!mounted) return;
    setState(() {
      _status = null;
    });
    final pos = await _posicaoAtual();
    if (pos != null) {
      if (!mounted) return;
      setState(() {
        _posicao = LatLng(pos.latitude, pos.longitude);
        _status = const AppMessage('Posição atualizada.', MessageTone.success);
      });
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
    NotificationService.requestPermissions();
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
    _carregarPreferencias();
    WidgetsBinding.instance.addPostFrameCallback((_) => _mostrarGuiaMotoristaSeNecessario());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    DriverBackgroundService.stop();
    _backgroundAtivo = false;
    _notificationTapSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _appPausado = true;
      _pingTimer?.cancel();
      _pollTimer?.cancel();
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
      if (_recebendoCorridas) {
        _verificarCorrida();
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

  String _formatarLugares(int lugares) {
    return lugares == 1 ? '1 lugar' : '$lugares lugares';
  }

  Future<void> _enviarPing({bool silencioso = false}) async {
    if (_enviando) return;
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    final perfilTipo = user?.perfilTipo;
    if (perfilId == 0 || perfilTipo != 'ecotaxista') {
      if (mounted) {
        setState(
          () => _status = const AppMessage(
            'Use um perfil de ecotaxista para enviar pings.',
            MessageTone.warning,
          ),
        );
      }
      return;
    }

    if (mounted) {
      setState(() {
        _enviando = true;
        if (!silencioso) _status = null;
      });
    }

    final pos = await _posicaoAtual();
    if (pos == null) {
      if (mounted) setState(() => _enviando = false);
      return;
    }

    try {
      final service = DriverService();
      await service.enviarPing(
        perfilId: perfilId,
        latitude: _round6(pos.latitude),
        longitude: _round6(pos.longitude),
        precisao: pos.accuracy,
      );
      if (!silencioso && mounted) {
        setState(() => _status = const AppMessage('Ping enviado!', MessageTone.success));
      } else if (silencioso && mounted) {
        if (_status?.tone == MessageTone.error) {
          setState(() => _status = null);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = AppMessage('Erro ao enviar ping: ${friendlyError(e)}', MessageTone.error));
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _iniciarAutoPing({bool showStatus = true}) {
    if (_guiaAtivo) return;
    if (!_recebendoCorridas) return;
    _pingTimer?.cancel();
    _enviarPing(silencioso: true);
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) => _enviarPing(silencioso: true));
    if (showStatus) {
      setState(() => _status = const AppMessage('Auto ping a cada 10s ligado.', MessageTone.info));
    }
  }

  void _iniciarPollingCorrida() {
    if (_guiaAtivo) return;
    if (!_recebendoCorridas) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _verificarCorrida());
  }

  Future<void> _verificarCorrida({bool force = false}) async {
    if (_appPausado && !force) return;
    if (_guiaAtivo && !force) return;
    if (!_recebendoCorridas && !force) return;
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
      if (corrida != null && corrida.isNotEmpty) {
        _corridaAtual = corrida;
        _atualizarRotas(corrida);
        if (_modalAberto) {
          _modalSetState?.call(() {});
        } else {
          _mostrarModalCorrida(corrida);
        }
      } else {
        _corridaAtual = null;
        _limparRotas();
        if (_modalAberto && mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          _modalAberto = false;
          _modalSetState = null;
        }
      }
    } catch (e) {
      // silencioso para polling
      debugPrint('Erro ao verificar corrida: ${friendlyError(e)}');
    }
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
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (ctx, anim, __) {
          return SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Material(
                  color: Theme.of(context).dialogBackgroundColor,
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
                                  if (corridaAtual['id'] != null) ...[
                                    const SizedBox(height: 6),
                                    Text('Corrida #${corridaAtual['id']}', style: Theme.of(context).textTheme.bodySmall),
                                  ],
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
                                final lugaresLabel = _formatarLugares(lugares);
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
                                      Text('Lugares: $lugaresLabel', style: Theme.of(context).textTheme.bodyMedium),
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
                                                  width: 36,
                                                  height: 36,
                                                  child: const Icon(Icons.local_taxi, color: Colors.orange, size: 30),
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
          _modalSetState?.call(() {});
          if (_modalAberto && mounted) {
            Navigator.of(context, rootNavigator: true).pop();
            _modalAberto = false;
          }
          if (mounted) {
            setState(() => _status = const AppMessage('Corrida enviada para outro motorista.', MessageTone.info));
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
      _modalSetState?.call(() {});
      if (!mounted) return;
      setState(() => _status = const AppMessage('Status da corrida atualizado.', MessageTone.info));
      if (acao == 'finalizar' || (nova != null && nova['status'] == 'concluida')) {
        _limparRotas();
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
      if (!mounted) return;
      setState(() => _status = AppMessage('Erro ao atualizar corrida: ${friendlyError(e)}', MessageTone.error));
    }
  }

  void _onNotificationTap(String? payload) {
    if (_guiaAtivo) return;
    _verificarCorrida(force: true);
  }

  void _setRecebimentoCorridas(bool ativo) {
    if (_recebendoCorridas == ativo) return;
    setState(() {
      _recebendoCorridas = ativo;
      _status = AppMessage(
        ativo ? 'Recebimento de corridas ligado.' : 'Recebimento de corridas desligado.',
        MessageTone.info,
      );
    });
    _salvarPreferencias(recebendoCorridas: ativo);
    if (ativo) {
      _verificarCorrida(force: true);
      _iniciarAutoPing(showStatus: false);
      _iniciarPollingCorrida();
      return;
    }
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
      _setLocalizacaoSegundoPlano(false, showStatus: false, forceRebuild: true);
      return;
    }
    final permissaoOk = await _garantirPermissaoLocalizacao();
    if (!permissaoOk) {
      _setLocalizacaoSegundoPlano(false, showStatus: false, forceRebuild: true);
      return;
    }
    _setLocalizacaoSegundoPlano(true);
  }

  void _setLocalizacaoSegundoPlano(
    bool ativo, {
    bool showStatus = true,
    bool salvarPreferencias = true,
    bool forceRebuild = false,
  }) {
    final mudou = _enviarLocalizacaoBg != ativo;
    if (mounted && (mudou || showStatus || forceRebuild)) {
      setState(() {
        if (mudou) {
          _enviarLocalizacaoBg = ativo;
        }
        if (showStatus) {
          _status = AppMessage(
            ativo
                ? 'Envio de localização em segundo plano ligado.'
                : 'Envio de localização em segundo plano desligado.',
            MessageTone.info,
          );
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
      _status = null;
    });
    try {
      await DriverBackgroundService.stop();
      _backgroundAtivo = false;
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: 'passageiro');
      if (!mounted) return;
      context.go('/passageiro');
    } catch (e) {
      if (mounted) {
        setState(() => _status = AppMessage('Erro ao trocar para Passageiro: ${friendlyError(e)}', MessageTone.error));
      }
    } finally {
      if (mounted) setState(() => _trocandoPerfil = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final loggedIn = auth.valueOrNull != null;
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
          if (loggedIn)
            IconButton(
              key: _guiaLogoutKey,
              tooltip: 'Sair',
              icon: const Icon(Icons.logout),
              onPressed: _logout,
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
      body: Padding(
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
                    onChanged: _setRecebimentoCorridas,
                    title: const Text('Ativar recebimento de corridas'),
                    subtitle: const Text('Fique disponível para receber novas corridas.'),
                  ),
                  Divider(height: 1, color: Colors.grey.shade200),
                  SwitchListTile.adaptive(
                    key: _guiaLocalizacaoBgKey,
                    value: _enviarLocalizacaoBg,
                    onChanged: _onToggleLocalizacaoSegundoPlano,
                    title: const Text('Enviar localização em segundo plano'),
                    subtitle: const Text(
                      'Permite que o app continue enviando sua localização mesmo em segundo plano, '
                      'para te conectar às corridas mais próximas.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              key: _guiaMapaKey,
              height: 220,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _posicao == null
                    ? Container(
                        color: Colors.grey.shade100,
                        child: const Center(child: Text('Localização não disponível')),
                      )
                    : Builder(
                        builder: (context) {
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
                            'driver-main-${fitBounds == null ? zoom.toStringAsFixed(2) : 'fit'}-${MapViewport.signatureForPins(pins)}',
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
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: _posicao!,
                                    width: 40,
                                    height: 40,
                                    child: const Icon(Icons.location_pin, color: Colors.red, size: 36),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _recebendoCorridas
                  ? 'O app envia sua localização automaticamente a cada 10s e verifica corridas atribuídas.'
                  : 'Recebimento de corridas pausado. Ative para enviar sua localização e verificar corridas atribuídas.',
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              MessageBanner(
                message: _status!,
                onClose: _clearStatus,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
