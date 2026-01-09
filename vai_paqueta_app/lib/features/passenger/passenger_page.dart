import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/error_messages.dart';
import '../../core/map_config.dart';
import '../../core/map_viewport.dart';
import '../../widgets/message_banner.dart';
import '../../services/geo_service.dart';
import '../../services/route_service.dart';
import '../rides/rides_service.dart';
import '../auth/auth_provider.dart';

class PassengerPage extends ConsumerStatefulWidget {
  const PassengerPage({super.key});

  @override
  ConsumerState<PassengerPage> createState() => _PassengerPageState();
}

class _PassengerPageState extends ConsumerState<PassengerPage> with WidgetsBindingObserver {
  static const _prefsCorridaKey = 'corrida_ativa_id';
  final _origemCtrl = TextEditingController();
  final _destinoCtrl = TextEditingController();
  LatLng? _origemLatLng;
  LatLng? _destinoLatLng;
  LatLng? _motoristaLatLng;
  String? _motoristaNome;
  String? _motoristaTelefone;
  String? _origemEnderecoCorrida;
  String? _destinoEnderecoCorrida;
  List<LatLng> _rota = [];
  List<LatLng> _rotaMotorista = [];
  bool _loading = false;
  AppMessage? _mensagem;
  bool _corridaAtiva = false;
  int? _corridaIdAtual;
  String? _statusCorrida;
  DateTime? _corridaAceitaEm;
  DateTime? _corridaIniciadaEm;
  int _corridaLugares = 1;
  bool _modalAberto = false;
  StateSetter? _modalSetState;
  bool _paymentWarningOpen = false;
  int? _paymentWarningRideId;
  bool _tileUsingAssets = MapTileConfig.useAssets;
  String _tileUrl = MapTileConfig.useAssets ? MapTileConfig.assetsTemplate : MapTileConfig.networkTemplate;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  _TileSource? _assetTileSource;
  _TileSource? _networkTileSource;
  bool _usandoFallbackRede = false;
  bool _alertaTiles = false;
  bool _posCarregada = false;
  int _lugaresSolicitados = 1;
  final GeoService _geo = GeoService();
  final RouteService _routeService = RouteService();
  List<GeoResult> _sugestoesOrigem = [];
  List<GeoResult> _sugestoesDestino = [];
  final Distance _distance = const Distance();
  String? _rotaKey;
  String? _rotaMotoristaKey;
  List<_EnderecoOffline> _enderecosOffline = [];
  bool _enderecosCarregados = false;
  Timer? _debounceOrigem;
  Timer? _debounceDestino;
  bool _trocandoPerfil = false;
  double _round6(double v) => double.parse(v.toStringAsFixed(6));
  Timer? _corridaTimer;
  Timer? _cancelUnlockTimer;
  Timer? _finalUnlockTimer;
  bool _appPausado = false;
  Duration _corridaPollInterval = const Duration(seconds: 4);
  static const Duration _tempoMinimoCancelamentoAposAceite = Duration(minutes: 2);
  static const Duration _tempoMinimoFinalizarAposInicio = Duration(minutes: 3);
  Duration _serverTimeOffset = Duration.zero;
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
    return _tileUsingAssets ? AssetTileProvider() : NetworkTileProvider();
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
    return lugares == 1 ? '1 lugar' : '$lugares lugares';
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
    if (_corridaAceitaEm == null) return _tempoMinimoCancelamentoAposAceite;
    final elapsed = _nowServer().difference(_corridaAceitaEm!);
    final remaining = _tempoMinimoCancelamentoAposAceite - elapsed;
    if (remaining <= Duration.zero) return Duration.zero;
    return remaining;
  }

  Duration? _tempoRestanteFinalizacao() {
    if (_normalizarStatus(_statusCorrida) != 'em_andamento') return null;
    if (_corridaIniciadaEm == null) return _tempoMinimoFinalizarAposInicio;
    final elapsed = _nowServer().difference(_corridaIniciadaEm!);
    final remaining = _tempoMinimoFinalizarAposInicio - elapsed;
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
    final totalSeconds = _tempoMinimoCancelamentoAposAceite.inSeconds;
    if (totalSeconds <= 0) return 1;
    final elapsed = (totalSeconds - remaining.inSeconds).clamp(0, totalSeconds);
    return elapsed / totalSeconds;
  }

  double _finalizacaoProgresso(Duration remaining) {
    final totalSeconds = _tempoMinimoFinalizarAposInicio.inSeconds;
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
    _cancelUnlockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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
    _finalUnlockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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

  void _setMessage(String text, MessageTone tone) {
    if (!mounted) {
      _mensagem = AppMessage(text, tone);
      return;
    }
    setState(() => _mensagem = AppMessage(text, tone));
  }

  void _setMessageRaw(String text, MessageTone tone) {
    _mensagem = AppMessage(text, tone);
  }

  void _clearMessage() {
    if (!mounted) {
      _mensagem = null;
      return;
    }
    setState(() => _mensagem = null);
  }

  void _clearInputMessage() {
    if (_mensagem == null) return;
    if (_mensagem!.tone == MessageTone.error || _mensagem!.tone == MessageTone.warning) {
      _clearMessage();
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
      setState(() => _mensagem = const AppMessage('Não foi possível abrir o WhatsApp.', MessageTone.error));
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
    _lugaresSolicitados = 1;
    if (limparEnderecos) {
      _origemCtrl.clear();
      _destinoCtrl.clear();
      _origemLatLng = null;
      _destinoLatLng = null;
      _sugestoesOrigem = [];
      _sugestoesDestino = [];
    }
    _salvarCorridaLocal(null);
    _corridaTimer?.cancel();
    _cancelUnlockTimer?.cancel();
    _finalUnlockTimer?.cancel();
    _fecharModalCorrida();
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
  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    context.go('/auth');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configurarFonteTiles();
    _carregarEnderecosOffline();
    _carregarCorridaAtiva();
    _carregarPosicao();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _origemCtrl.dispose();
    _destinoCtrl.dispose();
    _debounceOrigem?.cancel();
    _debounceDestino?.cancel();
    _corridaTimer?.cancel();
    _cancelUnlockTimer?.cancel();
    _finalUnlockTimer?.cancel();
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
    } else if (state == AppLifecycleState.resumed && _appPausado) {
      _appPausado = false;
      if (_corridaIdAtual != null) {
        _atualizarCorridaAtiva();
        _iniciarPollingCorrida();
      }
      _gerenciarTimerCancelamento();
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
        LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
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
      final minZoom = assetZooms.isNotEmpty ? assetZooms.reduce(min) : MapTileConfig.assetsMinZoom;
      final maxZoom = assetZooms.isNotEmpty ? assetZooms.reduce(max) : MapTileConfig.assetsMaxZoom;
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
      _alertaTiles = false;
      return;
    }
    if (MapTileConfig.allowNetworkFallback && _networkTileSource != null) {
      _applyTileSource(_networkTileSource!, usandoFallback: true);
      _setMessage('Mapa offline indisponível aqui. Usando mapa online.', MessageTone.info);
      return;
    }
    if (!_alertaTiles) {
      _setMessage('Área fora do mapa offline. Ajuste o GPS ou baixe mais tiles.', MessageTone.warning);
      _alertaTiles = true;
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

  Future<void> _carregarEnderecosOffline() async {
    if (_enderecosCarregados) return;
    try {
      final jsonStr = await rootBundle.loadString('assets/addresses.json');
      final data = json.decode(jsonStr) as List<dynamic>;
      _enderecosOffline = data
          .map(
            (e) => _EnderecoOffline(
              displayName: _buildDisplayName(e),
              lat: (e['lat'] as num).toDouble(),
              lng: (e['lng'] as num).toDouble(),
              searchText: _normalizeTexto("${e['street'] ?? ''} ${e['housenumber'] ?? ''}"),
            ),
          )
          .where((e) => e.displayName.isNotEmpty)
          .toList();
      _enderecosCarregados = true;
    } catch (_) {
      _enderecosOffline = [];
      _enderecosCarregados = true;
    }
  }

  Future<void> _garantirEnderecos() async {
    if (_enderecosCarregados) return;
    await _carregarEnderecosOffline();
  }

  List<GeoResult> _filtrarEnderecos(String texto, {LatLng? referencia}) {
    if (_enderecosOffline.isEmpty) return const [];
    final q = _normalizeTexto(texto);
    if (q.isEmpty) return const [];

    final list = <(_EnderecoOffline, double?)>[];
    for (final e in _enderecosOffline) {
      if (!e.searchText.contains(q)) continue;
      double? dist;
      if (referencia != null) {
        dist = _distance(LatLng(e.lat, e.lng), referencia) / 1000.0;
      }
      list.add((e, dist));
    }

    list.sort((a, b) {
      if (a.$2 != null && b.$2 != null) {
        final cmp = a.$2!.compareTo(b.$2!);
        if (cmp != 0) return cmp;
      }
      return a.$1.displayName.compareTo(b.$1.displayName);
    });

    return list.take(8).map((item) {
      final e = item.$1;
      return GeoResult(lat: e.lat, lng: e.lng, endereco: e.displayName);
    }).toList();
  }

  String _normalizeTexto(String value) {
    final lower = value.toLowerCase();
    return lower.replaceAll(RegExp('[^a-z0-9\\u00C0-\\u017F\\s]+'), ' ').replaceAll(RegExp('\\s+'), ' ').trim();
  }

  String _buildDisplayName(Map<String, dynamic> e) {
    final street = (e['street'] ?? '').toString().trim();
    final number = e['housenumber']?.toString().trim() ?? '';
    if (street.isEmpty) return '';
    if (number.isNotEmpty) return '$street, $number';
    return street;
  }

  Future<void> _carregarPosicao() async {
    if (_posCarregada) return;
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
        _sincronizarModalCorrida();
        if (_origemLatLng != null && _destinoLatLng != null) {
          _carregarRotaCorrida(_origemLatLng!, _destinoLatLng!);
        }
        if (_motoristaLatLng != null) {
          _atualizarRotaMotorista(current.status);
        }
        _avaliarTilesPara(_origemLatLng ?? _destinoLatLng);
        _salvarCorridaLocal(current.id);
        _iniciarPollingCorrida();
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
    _corridaPollInterval = const Duration(seconds: 4);
    _agendarPoll();
  }

  void _agendarPoll() {
    _corridaTimer?.cancel();
    _corridaTimer = Timer(_corridaPollInterval, () async {
      final sucesso = await _atualizarCorridaAtiva();
      if (sucesso) {
        _corridaPollInterval = const Duration(seconds: 4);
      } else {
        final next = _corridaPollInterval.inSeconds * 2;
        _corridaPollInterval = Duration(seconds: next.clamp(4, 20));
      }
      _agendarPoll();
    });
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
          _mensagem = const AppMessage('Corrida não encontrada.', MessageTone.info);
        });
        return false;
      }
      if (!mounted) return false;
      final nextStatus = _normalizarStatus(corrida.status);
      setState(() {
        _atualizarServerOffset(corrida.serverTime);
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
        if (corrida.status == 'concluida' || corrida.status == 'cancelada' || corrida.status == 'rejeitada') {
          _encerrarCorrida(limparEnderecos: corrida.status == 'concluida');
        }
        if (_origemCtrl.text.trim().isEmpty && corrida.origemEndereco != null && corrida.origemEndereco!.isNotEmpty) {
          _origemCtrl.text = corrida.origemEndereco!;
        }
        if (_destinoCtrl.text.trim().isEmpty && corrida.destinoEndereco != null && corrida.destinoEndereco!.isNotEmpty) {
          _destinoCtrl.text = corrida.destinoEndereco!;
        }
        _lugaresSolicitados = corrida.lugares;
      });
      _sincronizarModalCorrida();
      if (_origemLatLng != null && _destinoLatLng != null) {
        _carregarRotaCorrida(_origemLatLng!, _destinoLatLng!);
      }
      if (_motoristaLatLng != null) {
        _atualizarRotaMotorista(corrida.status);
      }
      _gerenciarTimerCancelamento();
      _gerenciarTimerFinalizacao();
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
          'Cancelamento liberado em ${_formatTempoRestante(remaining)}',
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

  Widget _buildRideInfoCard(BuildContext context, {EdgeInsetsGeometry? margin}) {
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
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
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
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1, color: Colors.green.shade700),
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
          const SizedBox(height: 12),
          _infoBox(
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
                  Text(driverPhone, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade700)),
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
          const SizedBox(height: 12),
          _infoBox(
            context,
            'Rota',
            [
              Text('Origem: $origem', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('Destino: $destino', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text(
                'Quantos lugares você precisa para essa corrida? ${_formatarLugares(_corridaLugares)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarModalCorrida() async {
    if (_modalAberto || !mounted) return;
    _modalAberto = true;
    await Future<void>.delayed(Duration.zero);
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
                  child: StatefulBuilder(
                    builder: (dialogContext, setModalState) {
                      _modalSetState = setModalState;
                      final origem = _origemLatLng;
                      final destino = _destinoLatLng;
                      final motorista = _motoristaLatLng;
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
                              _buildRideInfoCard(context, margin: EdgeInsets.zero),
                              const SizedBox(height: 12),
                              if (origem != null || destino != null || motorista != null)
                                SizedBox(
                                  height: 220,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Builder(
                                      builder: (context) {
                                        final bounds = MapTileConfig.tilesBounds;
                                        final rawPins = MapViewport.collectPins([origem, destino, motorista]);
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
                                          'pass-modal-${fitBounds == null ? zoom.toStringAsFixed(2) : 'fit'}-${MapViewport.signatureForPins(pins)}',
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
                                                if (motorista != null)
                                                  Marker(
                                                    point: motorista,
                                                    width: 36,
                                                    height: 36,
                                                    child: const Icon(Icons.local_taxi, color: Colors.orange, size: 30),
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
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      if (_podeCancelarCorrida)
                                        OutlinedButton.icon(
                                          onPressed: _loading ? null : _pedirCorrida,
                                          icon: const Icon(Icons.cancel),
                                          label: const Text('Cancelar'),
                                        ),
                                      if (_podeFinalizarCorrida)
                                        ElevatedButton.icon(
                                          onPressed: _loading ? null : _finalizarCorrida,
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
      _mensagem = null;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: 'ecotaxista');
      if (!mounted) return;
      context.go('/motorista');
    } catch (e) {
      if (mounted) {
        setState(
          () => _mensagem = AppMessage(
            'Erro ao trocar para EcoTaxista: ${friendlyError(e)}',
            MessageTone.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _trocandoPerfil = false);
      }
    }
  }

  Future<void> _usarGPS({bool silencioso = false}) async {
    setState(() {
      if (!silencioso) _mensagem = null;
      _loading = true;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        if (!mounted) return;
        setState(() => _mensagem = const AppMessage('Permissão de localização negada.', MessageTone.error));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _origemLatLng = LatLng(pos.latitude, pos.longitude);
        _posCarregada = true;
      });
      _avaliarTilesPara(_origemLatLng);
      try {
        final res = await _geo.reverse(pos.latitude, pos.longitude);
        if (!mounted) return;
        setState(() {
          _origemCtrl.text = res.endereco.isNotEmpty ? res.endereco : _origemCtrl.text;
          if (!silencioso) {
            _mensagem = AppMessage(
              res.endereco.isNotEmpty ? res.endereco : 'Origem definida pelo GPS.',
              MessageTone.info,
            );
          }
        });
      } catch (_) {
        if (!silencioso) {
          if (!mounted) return;
          setState(
            () => _mensagem = const AppMessage(
              'Origem definida pelo GPS (falha no endereço, use o texto digitado).',
              MessageTone.info,
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!silencioso) {
          _mensagem = AppMessage(
            'Erro ao obter localização: ${friendlyError(e)}',
            MessageTone.error,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buscarSugestoesOrigem(String texto) async {
    await _garantirEnderecos();
    _sugestoesOrigem = [];
    setState(() {});
    if (texto.trim().length < 1) return;
    final resultados = _filtrarEnderecos(texto, referencia: _origemLatLng ?? _destinoLatLng);
    setState(() => _sugestoesOrigem = resultados);
  }

  Future<void> _buscarSugestoesDestino(String texto) async {
    await _garantirEnderecos();
    _sugestoesDestino = [];
    setState(() {});
    if (texto.trim().length < 1) return;
    final resultados = _filtrarEnderecos(texto, referencia: _origemLatLng ?? _destinoLatLng);
    setState(() => _sugestoesDestino = resultados);
  }

  void _onOrigemChanged(String texto) {
    _clearInputMessage();
    _debounceOrigem?.cancel();
    _debounceOrigem = Timer(const Duration(milliseconds: 300), () => _buscarSugestoesOrigem(texto));
  }

  void _onDestinoChanged(String texto) {
    _clearInputMessage();
    _debounceDestino?.cancel();
    _debounceDestino = Timer(const Duration(milliseconds: 300), () => _buscarSugestoesDestino(texto));
  }

  Future<void> _finalizarCorrida() async {
    if (!_corridaAtiva || _corridaIdAtual == null) return;
    setState(() {
      _loading = true;
      _mensagem = null;
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
      setState(
        () => _mensagem = AppMessage(
          msg,
          MessageTone.warning,
        ),
      );
      setState(() => _loading = false);
      return;
    }
    try {
      final rides = RidesService();
      await rides.finalizarCorrida(_corridaIdAtual!);
      setState(() {
        _encerrarCorrida(limparEnderecos: true);
        _mensagem = const AppMessage('Corrida finalizada.', MessageTone.success);
      });
    } catch (e) {
      setState(
        () => _mensagem = AppMessage('Erro ao finalizar: ${friendlyError(e)}', MessageTone.error),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pedirCorrida() async {
    if (_corridaAtiva && _corridaIdAtual != null) {
      setState(() {
        _loading = true;
        _mensagem = null;
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
        setState(
          () => _mensagem = AppMessage(
            msg,
            MessageTone.warning,
          ),
        );
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
        setState(
          () => _mensagem = AppMessage('Erro ao cancelar: ${friendlyError(e)}', MessageTone.error),
        );
      } finally {
        setState(() => _loading = false);
      }
      return;
    }

    setState(() {
      _loading = true;
      _mensagem = null;
    });
    try {
      final user = ref.read(authProvider).valueOrNull;
      final perfilId = user?.perfilId ?? 0;
      if (perfilId == 0) {
        setState(
          () => _mensagem = const AppMessage('Perfil do usuário não encontrado.', MessageTone.error),
        );
        return;
      }
      if (_lugaresSolicitados < 1 || _lugaresSolicitados > 2) {
        setState(() => _mensagem = const AppMessage('Selecione 1 ou 2 lugares.', MessageTone.warning));
        return;
      }
      if (_origemLatLng == null && _origemCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_origemCtrl.text);
        _origemLatLng = LatLng(res.lat, res.lng);
        _origemCtrl.text = res.endereco;
        _sugestoesOrigem = [];
        await _avaliarTilesPara(_origemLatLng);
      }
      if (_destinoLatLng == null && _destinoCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_destinoCtrl.text);
        _destinoLatLng = LatLng(res.lat, res.lng);
        _destinoCtrl.text = res.endereco;
        _sugestoesDestino = [];
        await _avaliarTilesPara(_destinoLatLng);
      }
      if (_origemLatLng == null || _destinoLatLng == null) {
        setState(() => _mensagem = const AppMessage('Defina origem e destino.', MessageTone.warning));
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
      _sincronizarModalCorrida();
      _salvarCorridaLocal(_corridaIdAtual);
      _iniciarPollingCorrida();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mostrarAvisoPagamento(rideId: corrida.id);
      });
    } catch (e) {
      setState(
        () => _mensagem = AppMessage('Erro ao pedir corrida: ${friendlyError(e)}', MessageTone.error),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  List<LatLng> _aStarRoute(LatLng start, LatLng goal) {
    final dLat = (goal.latitude - start.latitude).abs();
    final dLng = (goal.longitude - start.longitude).abs();
    final step = max(dLat, dLng) / 50.0 + 1e-5;
    final minLat = min(start.latitude, goal.latitude) - step * 5;
    final minLng = min(start.longitude, goal.longitude) - step * 5;
    final maxLat = max(start.latitude, goal.latitude) + step * 5;
    final maxLng = max(start.longitude, goal.longitude) + step * 5;

    int toRow(double lat) => ((lat - minLat) / step).round();
    int toCol(double lng) => ((lng - minLng) / step).round();
    double rowToLat(int r) => minLat + r * step;
    double colToLng(int c) => minLng + c * step;

    final startNode = Point<int>(toRow(start.latitude), toCol(start.longitude));
    final goalNode = Point<int>(toRow(goal.latitude), toCol(goal.longitude));

    final open = PriorityQueue<_Node>((a, b) => a.f.compareTo(b.f));
    final gScore = <Point<int>, double>{startNode: 0};
    final cameFrom = <Point<int>, Point<int>>{};

    open.add(_Node(startNode, _heuristic(startNode, goalNode)));
    const List<Point<int>> directions = [
      Point<int>(1, 0),
      Point<int>(-1, 0),
      Point<int>(0, 1),
      Point<int>(0, -1),
      Point<int>(1, 1),
      Point<int>(1, -1),
      Point<int>(-1, 1),
      Point<int>(-1, -1),
    ];
    const maxIter = 20000;
    var iter = 0;

    while (open.isNotEmpty && iter < maxIter) {
      iter++;
      final current = open.removeFirst().point;
      if (current == goalNode) {
        return _reconstructPath(cameFrom, current).map((p) => LatLng(rowToLat(p.x), colToLng(p.y))).toList();
      }

      for (final d in directions) {
        final Point<int> neighbor = Point<int>(current.x + d.x, current.y + d.y);
        if (neighbor.x < 0 ||
            neighbor.y < 0 ||
            rowToLat(neighbor.x) < minLat ||
            rowToLat(neighbor.x) > maxLat ||
            colToLng(neighbor.y) < minLng ||
            colToLng(neighbor.y) > maxLng) {
          continue;
        }

        final tentativeG = gScore[current]! + _heuristic(current, neighbor);
        if (tentativeG < (gScore[neighbor] ?? double.infinity)) {
          cameFrom[neighbor] = current;
          gScore[neighbor] = tentativeG;
          final f = tentativeG + _heuristic(neighbor, goalNode);
          open.add(_Node(neighbor, f));
        }
      }
    }
    return [start, goal];
  }

  double _heuristic(Point<int> a, Point<int> b) {
    final dx = (a.x - b.x).abs();
    final dy = (a.y - b.y).abs();
    return sqrt((dx * dx) + (dy * dy));
  }

  Iterable<Point<int>> _reconstructPath(Map<Point<int>, Point<int>> cameFrom, Point<int> current) sync* {
    var cur = current;
    yield cur;
    while (cameFrom.containsKey(cur)) {
      cur = cameFrom[cur]!;
      yield cur;
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
            tooltip: 'Editar dados',
            icon: const Icon(Icons.settings),
            onPressed: () => context.goNamed('perfil'),
          ),
          if (loggedIn)
            IconButton(
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
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            )
          else
            IconButton(
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
              child: SizedBox(
                height: 220,
                child: Builder(
                  builder: (context) {
                    final bounds = MapTileConfig.tilesBounds;
                    final rawPins = MapViewport.collectPins([_origemLatLng, _destinoLatLng, _motoristaLatLng]);
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
                      'pass-main-${fitBounds == null ? zoom.toStringAsFixed(2) : 'fit'}-${MapViewport.signatureForPins(pins)}',
                    );
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: FlutterMap(
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
                            userAgentPackageName: 'com.example.vai_paqueta_app',
                            tileProvider: _buildTileProvider(),
                            minZoom: MapTileConfig.displayMinZoom.toDouble(),
                            maxZoom: MapTileConfig.displayMaxZoom.toDouble(),
                            minNativeZoom: _tileMinNativeZoom ?? MapTileConfig.assetsMinZoom,
                            maxNativeZoom: _tileMaxNativeZoom ?? MapTileConfig.assetsMaxZoom,
                            tileBounds: bounds,
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
                          if (_motoristaLatLng != null)
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: _motoristaLatLng!,
                                  width: 40,
                                  height: 40,
                                  child: const Icon(Icons.local_taxi, color: Colors.orange, size: 34),
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
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _origemCtrl,
                      onChanged: _onOrigemChanged,
                      decoration: InputDecoration(
                        labelText: 'Endereço atual (origem)',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.gps_fixed),
                          onPressed: _loading ? null : _usarGPS,
                        ),
                      ),
                    ),
                    if (_sugestoesOrigem.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 150),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: const BorderRadius.all(Radius.circular(8)),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _sugestoesOrigem.length,
                          itemBuilder: (context, index) {
                            final s = _sugestoesOrigem[index];
                            return ListTile(
                              dense: true,
                              title: Text(s.endereco),
                              onTap: () {
                                _clearInputMessage();
                                setState(() {
                                  _origemCtrl.text = s.endereco;
                                  _origemLatLng = LatLng(s.lat, s.lng);
                                  _sugestoesOrigem = [];
                                });
                              },
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _destinoCtrl,
                      onChanged: _onDestinoChanged,
                      decoration: const InputDecoration(
                        labelText: 'Endereço de ida (destino)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_sugestoesDestino.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 150),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: const BorderRadius.all(Radius.circular(8)),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _sugestoesDestino.length,
                          itemBuilder: (context, index) {
                            final s = _sugestoesDestino[index];
                            return ListTile(
                              dense: true,
                              title: Text(s.endereco),
                              onTap: () {
                                _clearInputMessage();
                                setState(() {
                                  _destinoCtrl.text = s.endereco;
                                  _destinoLatLng = LatLng(s.lat, s.lng);
                                  _sugestoesDestino = [];
                                });
                              },
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: _lugaresSolicitados,
                      decoration: const InputDecoration(
                        labelText: 'Quantos lugares você precisa para essa corrida?',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 lugar')),
                        DropdownMenuItem(value: 2, child: Text('2 lugares')),
                      ],
                      onChanged: _corridaAtiva || _loading
                          ? null
                          : (value) {
                              if (value == null) return;
                              _clearInputMessage();
                              setState(() => _lugaresSolicitados = value);
                            },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Máximo de 2 lugares por corrida.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    if (_mensagem != null)
                      MessageBanner(
                        message: _mensagem!,
                        onClose: _clearMessage,
                      ),
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

class _EnderecoOffline {
  final String displayName;
  final double lat;
  final double lng;
  final String searchText;

  const _EnderecoOffline({
    required this.displayName,
    required this.lat,
    required this.lng,
    required this.searchText,
  });
}

class _Node {
  final Point<int> point;
  final double f;
  _Node(this.point, this.f);
}
