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

import '../../core/map_config.dart';
import '../../services/geo_service.dart';
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
  String? _mensagem;
  bool _corridaAtiva = false;
  int? _corridaIdAtual;
  String? _statusCorrida;
  bool _modalAberto = false;
  StateSetter? _modalSetState;
  TileProvider _tileProvider = NetworkTileProvider();
  String _tileUrl = MapTileConfig.networkTemplate;
  double? _tileMinZoom;
  double? _tileMaxZoom;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  bool _posCarregada = false;
  final GeoService _geo = GeoService();
  List<GeoResult> _sugestoesOrigem = [];
  List<GeoResult> _sugestoesDestino = [];
  final Distance _distance = const Distance();
  List<_EnderecoOffline> _enderecosOffline = [];
  bool _enderecosCarregados = false;
  Timer? _debounceOrigem;
  Timer? _debounceDestino;
  bool _trocandoPerfil = false;
  double _round6(double v) => double.parse(v.toStringAsFixed(6));
  Timer? _corridaTimer;
  bool _appPausado = false;
  Duration _corridaPollInterval = const Duration(seconds: 10);
  bool get _podeCancelarCorrida {
    return _corridaAtiva &&
        _corridaIdAtual != null &&
        _normalizarStatus(_statusCorrida) == 'aguardando';
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

  String? _formatLatLng(LatLng? pos) {
    if (pos == null) return null;
    return '${pos.latitude.toStringAsFixed(6)}, ${pos.longitude.toStringAsFixed(6)}';
  }

  String? _buildWhatsAppLink(String? telefone) {
    final digits = (telefone ?? '').replaceAll(RegExp(r'\D+'), '');
    if (digits.isEmpty) return null;
    var normalized = digits;
    if (digits.length <= 11 && !digits.startsWith('55')) {
      normalized = '55$digits';
    }
    if (normalized.length < 12) return null;
    return 'https://wa.me/$normalized';
  }

  Future<void> _abrirWhatsApp(String? telefone) async {
    final link = _buildWhatsAppLink(telefone);
    if (link == null) return;
    final uri = Uri.parse(link);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      setState(() => _mensagem = 'Não foi possível abrir o WhatsApp.');
    }
  }

  void _encerrarCorrida({bool limparEnderecos = false}) {
    _corridaAtiva = false;
    _corridaIdAtual = null;
    _statusCorrida = null;
    _motoristaLatLng = null;
    _motoristaNome = null;
    _motoristaTelefone = null;
    _origemEnderecoCorrida = null;
    _destinoEnderecoCorrida = null;
    _rotaMotorista = [];
    _rota = [];
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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _appPausado = true;
      _corridaTimer?.cancel();
    } else if (state == AppLifecycleState.resumed && _appPausado) {
      _appPausado = false;
      if (_corridaIdAtual != null) {
        _atualizarCorridaAtiva();
        _iniciarPollingCorrida();
      }
    }
  }

  Future<void> _configurarFonteTiles() async {
    final source = await _resolverFonteTiles();
    if (!mounted) return;

    setState(() {
      _tileProvider = source.provider;
      _tileUrl = source.template;
      _tileMinZoom = source.minZoom;
      _tileMaxZoom = source.maxZoom;
      _tileMinNativeZoom = source.minNativeZoom;
      _tileMaxNativeZoom = source.maxNativeZoom;

      if (MapTileConfig.useAssets && !source.usingAssets) {
        _mensagem ??= 'Tiles locais não encontrados, carregando mapa online.';
      }
    });
  }

  Future<_TileSource> _resolverFonteTiles() async {
    if (MapTileConfig.useAssets) {
      final manifest = await _carregarManifesto();
      final assetZooms = _extrairZooms(manifest);
      if (assetZooms.isNotEmpty) {
        final minZoom = assetZooms.reduce(min);
        final maxZoom = assetZooms.reduce(max);
        return _TileSource(
          template: MapTileConfig.assetsTemplate,
          provider: AssetTileProvider(),
          usingAssets: true,
          minZoom: minZoom.toDouble(),
          maxZoom: maxZoom.toDouble(),
          minNativeZoom: minZoom,
          maxNativeZoom: maxZoom,
        );
      }
    }

    return _TileSource(
      template: MapTileConfig.networkTemplate,
      provider: NetworkTileProvider(),
      usingAssets: false,
    );
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
        setState(() {
          _corridaAtiva = true;
          _corridaIdAtual = current.id;
          _statusCorrida = current.status;
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
            _atualizarRotaMotorista(current.status);
          }
          if (_origemCtrl.text.trim().isEmpty && current.origemEndereco != null && current.origemEndereco!.isNotEmpty) {
            _origemCtrl.text = current.origemEndereco!;
          }
          if (_destinoCtrl.text.trim().isEmpty && current.destinoEndereco != null && current.destinoEndereco!.isNotEmpty) {
            _destinoCtrl.text = current.destinoEndereco!;
          }
        });
        _sincronizarModalCorrida();
        _salvarCorridaLocal(current.id);
        _iniciarPollingCorrida();
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
    _corridaPollInterval = const Duration(seconds: 10);
    _agendarPoll();
  }

  void _agendarPoll() {
    _corridaTimer?.cancel();
    _corridaTimer = Timer(_corridaPollInterval, () async {
      final sucesso = await _atualizarCorridaAtiva();
      if (sucesso) {
        _corridaPollInterval = const Duration(seconds: 10);
      } else {
        final next = _corridaPollInterval.inSeconds * 2;
        _corridaPollInterval = Duration(seconds: next.clamp(10, 30));
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
          _mensagem = 'Corrida não encontrada.';
        });
        return false;
      }
      if (!mounted) return false;
      setState(() {
        _statusCorrida = corrida.status;
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
          _atualizarRotaMotorista(corrida.status);
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
      });
      _sincronizarModalCorrida();
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
                                    child: FlutterMap(
                                      options: MapOptions(
                                        initialCenter: origem ?? motorista ?? destino ?? const LatLng(-22.763, -43.106),
                                        initialZoom: 14,
                                        interactionOptions: const InteractionOptions(flags: ~InteractiveFlag.rotate),
                                      ),
                                      children: [
                                        TileLayer(
                                          urlTemplate: _tileUrl,
                                          tileProvider: _tileProvider,
                                          userAgentPackageName: 'com.example.vai_paqueta_app',
                                          minZoom: _tileMinZoom ?? 0,
                                          maxZoom: _tileMaxZoom ?? double.infinity,
                                          minNativeZoom: _tileMinNativeZoom ?? 0,
                                          maxNativeZoom: _tileMaxNativeZoom ?? 19,
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
                                              Polyline(points: _rotaMotorista, strokeWidth: 3, color: Colors.orangeAccent),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (_podeCancelarCorrida) ...[
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: _loading ? null : _pedirCorrida,
                                    icon: const Icon(Icons.cancel),
                                    label: const Text('Cancelar corrida'),
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

  void _atualizarRotaMotorista(String status) {
    if (_motoristaLatLng == null) {
      _rotaMotorista = [];
      return;
    }
    LatLng? alvo;
    if (status == 'em_andamento') {
      alvo = _destinoLatLng;
    } else {
      alvo = _origemLatLng;
    }
    if (alvo == null) {
      _rotaMotorista = [];
      return;
    }
    _rotaMotorista = [_motoristaLatLng!, alvo];
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
        setState(() => _mensagem = 'Erro ao trocar para EcoTaxista: $e');
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
        setState(() => _mensagem = 'Permissão de localização negada.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _origemLatLng = LatLng(pos.latitude, pos.longitude);
        _posCarregada = true;
      });
      try {
        final res = await _geo.reverse(pos.latitude, pos.longitude);
        if (!mounted) return;
        setState(() {
          _origemCtrl.text = res.endereco.isNotEmpty ? res.endereco : _origemCtrl.text;
          if (!silencioso) {
            _mensagem = res.endereco.isNotEmpty ? res.endereco : 'Origem definida pelo GPS.';
          }
        });
      } catch (_) {
        if (!silencioso) {
          if (!mounted) return;
          setState(() => _mensagem = 'Origem definida pelo GPS (falha no endereço, use o texto digitado).');
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!silencioso) _mensagem = 'Erro ao obter localização: $e';
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
    _debounceOrigem?.cancel();
    _debounceOrigem = Timer(const Duration(milliseconds: 300), () => _buscarSugestoesOrigem(texto));
  }

  void _onDestinoChanged(String texto) {
    _debounceDestino?.cancel();
    _debounceDestino = Timer(const Duration(milliseconds: 300), () => _buscarSugestoesDestino(texto));
  }

  Future<void> _pedirCorrida() async {
    if (_corridaAtiva && _corridaIdAtual != null) {
      if (!_podeCancelarCorrida) {
        setState(() => _mensagem = 'Corrida já aceita. Não é possível cancelar agora.');
        return;
      }
      setState(() {
        _loading = true;
        _mensagem = null;
      });
      try {
        final rides = RidesService();
        await rides.cancelarCorrida(_corridaIdAtual!);
        setState(() {
          _encerrarCorrida();
        });
      } catch (e) {
        setState(() => _mensagem = 'Erro ao cancelar: $e');
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
        setState(() => _mensagem = 'Perfil do usuário não encontrado.');
        return;
      }
      if (_origemLatLng == null && _origemCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_origemCtrl.text);
        _origemLatLng = LatLng(res.lat, res.lng);
        _origemCtrl.text = res.endereco;
        _sugestoesOrigem = [];
      }
      if (_destinoLatLng == null && _destinoCtrl.text.isNotEmpty) {
        final res = await _geo.forward(_destinoCtrl.text);
        _destinoLatLng = LatLng(res.lat, res.lng);
        _destinoCtrl.text = res.endereco;
        _sugestoesDestino = [];
      }
      if (_origemLatLng == null || _destinoLatLng == null) {
        setState(() => _mensagem = 'Defina origem e destino.');
        return;
      }

      final rota = _aStarRoute(_origemLatLng!, _destinoLatLng!);
      setState(() => _rota = rota);

      final rides = RidesService();
      final corrida = await rides.solicitar(
        perfilId: perfilId,
        origemLat: _round6(_origemLatLng!.latitude),
        origemLng: _round6(_origemLatLng!.longitude),
        destinoLat: _round6(_destinoLatLng!.latitude),
        destinoLng: _round6(_destinoLatLng!.longitude),
        origemEndereco: _origemCtrl.text,
        destinoEndereco: _destinoCtrl.text,
      );

      setState(() {
        _corridaAtiva = true;
        _corridaIdAtual = corrida.id;
        _statusCorrida = corrida.status;
        _motoristaLatLng = null;
      });
      _sincronizarModalCorrida();
      _salvarCorridaLocal(_corridaIdAtual);
      _iniciarPollingCorrida();
    } catch (e) {
      setState(() => _mensagem = 'Erro ao pedir corrida: $e');
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
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: _origemLatLng ?? _destinoLatLng ?? const LatLng(-22.763, -43.106),
                      initialZoom: 14,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: _tileUrl,
                        userAgentPackageName: 'com.example.vai_paqueta_app',
                        tileProvider: _tileProvider,
                        minZoom: _tileMinZoom ?? 0,
                        maxZoom: _tileMaxZoom ?? double.infinity,
                        minNativeZoom: _tileMinNativeZoom ?? 0,
                        maxNativeZoom: _tileMaxNativeZoom ?? 19,
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
                    if (_mensagem != null) Text(_mensagem!),
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
                                ? (_podeCancelarCorrida ? 'Cancelar corrida' : 'Corrida em andamento')
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
  final TileProvider provider;
  final bool usingAssets;
  final double? minZoom;
  final double? maxZoom;
  final int? minNativeZoom;
  final int? maxNativeZoom;

  const _TileSource({
    required this.template,
    required this.provider,
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
