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

import '../../core/map_config.dart';
import '../auth/auth_provider.dart';
import 'driver_service.dart';

class DriverPage extends ConsumerStatefulWidget {
  const DriverPage({super.key});

  @override
  ConsumerState<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends ConsumerState<DriverPage> with WidgetsBindingObserver {
  String? _status;
  bool _enviando = false;
  LatLng? _posicao;
  TileProvider _tileProvider = NetworkTileProvider();
  String _tileUrl = MapTileConfig.networkTemplate;
  double? _tileMinZoom;
  double? _tileMaxZoom;
  int? _tileMinNativeZoom;
  int? _tileMaxNativeZoom;
  Timer? _pingTimer;
  Timer? _pollTimer;
  bool _modalAberto = false;
  Map<String, dynamic>? _corridaAtual;
  bool _trocandoPerfil = false;
  bool _appPausado = false;
  StateSetter? _modalSetState;
  Future<void> _logout() async {
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
        setState(() => _status = 'Permissão de localização negada.');
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (e) {
      setState(() => _status = 'Erro ao obter localização: $e');
      return null;
    }
  }

  Future<void> _configurarFonteTiles() async {
    if (MapTileConfig.useAssets) {
      final manifest = await _carregarManifesto();
      final zooms = _extrairZooms(manifest);
      if (zooms.isNotEmpty) {
        final minZoom = zooms.reduce((a, b) => a < b ? a : b);
        final maxZoom = zooms.reduce((a, b) => a > b ? a : b);
        setState(() {
          _tileProvider = AssetTileProvider();
          _tileUrl = MapTileConfig.assetsTemplate;
          _tileMinZoom = minZoom.toDouble();
          _tileMaxZoom = maxZoom.toDouble();
          _tileMinNativeZoom = minZoom;
          _tileMaxNativeZoom = maxZoom;
        });
        return;
      }
    }
    setState(() {
      _tileProvider = NetworkTileProvider();
      _tileUrl = MapTileConfig.networkTemplate;
      _tileMinZoom = null;
      _tileMaxZoom = null;
      _tileMinNativeZoom = null;
      _tileMaxNativeZoom = null;
    });
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
        _status = 'Posição atualizada';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configurarFonteTiles();
    _atualizarPosicao();
    _verificarCorrida();
    _iniciarAutoPing();
    _iniciarPollingCorrida();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _appPausado = true;
      _pingTimer?.cancel();
      _pollTimer?.cancel();
    } else if (state == AppLifecycleState.resumed && _appPausado) {
      _appPausado = false;
      _atualizarPosicao();
      _iniciarAutoPing();
      _iniciarPollingCorrida();
    }
  }

  double _round6(double value) => double.parse(value.toStringAsFixed(6));

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<void> _enviarPing({bool silencioso = false}) async {
    if (_enviando) return;
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    final perfilTipo = user?.perfilTipo;
    if (perfilId == 0 || perfilTipo != 'ecotaxista') {
      if (mounted) setState(() => _status = 'Use um perfil de ecotaxista para enviar pings.');
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
        setState(() => _status = 'Ping enviado!');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Erro ao enviar ping: $e');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _iniciarAutoPing() {
    _pingTimer?.cancel();
    _enviarPing(silencioso: true);
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) => _enviarPing(silencioso: true));
    setState(() => _status = 'Auto ping a cada 10s ligado');
  }

  void _iniciarPollingCorrida() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _verificarCorrida());
  }

  Future<void> _verificarCorrida() async {
    final user = ref.read(authProvider).valueOrNull;
    final perfilId = user?.perfilId ?? 0;
    if (perfilId == 0 || user?.perfilTipo != 'ecotaxista') return;
    try {
      final service = DriverService();
      final corrida = await service.corridaAtribuida(perfilId);
      if (corrida != null && corrida.isNotEmpty) {
        _corridaAtual = corrida;
        if (_modalAberto) {
          _modalSetState?.call(() {});
        } else {
          _mostrarModalCorrida(corrida);
        }
      } else {
        _corridaAtual = null;
        if (_modalAberto && mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          _modalAberto = false;
          _modalSetState = null;
        }
      }
    } catch (e) {
      // silencioso para polling
      debugPrint('Erro ao verificar corrida: $e');
    }
  }

  Future<void> _mostrarModalCorrida(Map<String, dynamic> corrida) async {
    if (_modalAberto) return;
    _modalAberto = true;
    _corridaAtual = corrida;
    if (!mounted) {
      _modalAberto = false;
      return;
    }
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
                  child: StatefulBuilder(builder: (dialogContext, setModalState) {
                    _modalSetState = setModalState;
                    final corridaAtual = _corridaAtual ?? corrida;
                    final statusRaw = corridaAtual['status'] as String?;
                    final status = _normalizarStatus(statusRaw);
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
                            if (passageiroNome != null)
                              Text('Passageiro: $passageiroNome', style: Theme.of(context).textTheme.bodyMedium),
                            if (corridaAtual['origem_endereco'] != null)
                              Text('Origem: ${corridaAtual['origem_endereco']}', style: Theme.of(context).textTheme.bodyMedium),
                            if (corridaAtual['destino_endereco'] != null)
                              Text('Destino: ${corridaAtual['destino_endereco']}', style: Theme.of(context).textTheme.bodyMedium),
                            if (corridaAtual['id'] != null) Text('Corrida #${corridaAtual['id']}'),
                            if (statusRaw != null) Text('Status: $statusRaw'),
                            const SizedBox(height: 12),
                            if (origem != null || destino != null || motoristaPos != null)
                              SizedBox(
                                height: 220,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: FlutterMap(
                                    options: MapOptions(
                                      initialCenter: origem ?? motoristaPos ?? destino ?? const LatLng(-22.763, -43.106),
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
                                          if (motoristaPos != null)
                                            Marker(
                                              point: motoristaPos,
                                              width: 36,
                                              height: 36,
                                              child: const Icon(Icons.local_taxi, color: Colors.orange, size: 30),
                                            ),
                                        ],
                                      ),
                                      if (origem != null && motoristaPos != null)
                                        PolylineLayer(
                                          polylines: [
                                            Polyline(points: [motoristaPos, origem], strokeWidth: 3, color: Colors.orangeAccent),
                                          ],
                                        ),
                                      if (origem != null && destino != null)
                                        PolylineLayer(
                                          polylines: [
                                            Polyline(points: [origem, destino], strokeWidth: 3, color: Colors.blueAccent),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (status == 'aguardando')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.check),
                                    label: const Text('Aceitar'),
                                    onPressed: () => _acaoCorrida('aceitar'),
                                  ),
                                if (status == 'aguardando' || status == 'aceita')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.close),
                                    label: const Text('Rejeitar'),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400),
                                    onPressed: () => _acaoCorrida('rejeitar'),
                                  ),
                                if (status == 'aceita')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Iniciar'),
                                    onPressed: () => _acaoCorrida('iniciar'),
                                  ),
                                if (status == 'em_andamento')
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.flag),
                                    label: const Text('Finalizar'),
                                    onPressed: () => _acaoCorrida('finalizar'),
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
            setState(() => _status = 'Corrida enviada para outro motorista.');
          }
          _verificarCorrida();
          return;
        default:
          return;
      }
      if (nova != null) {
        _corridaAtual = nova;
      }
      _modalSetState?.call(() {});
      if (!mounted) return;
      setState(() => _status = 'Status da corrida atualizado.');
      if (acao == 'finalizar' || (nova != null && nova['status'] == 'concluida')) {
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
      setState(() => _status = 'Erro ao atualizar corrida: $e');
    }
  }

  Future<void> _trocarParaPassageiro() async {
    setState(() {
      _trocandoPerfil = true;
      _status = null;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: 'passageiro');
      if (!mounted) return;
      context.go('/passageiro');
    } catch (e) {
      if (mounted) setState(() => _status = 'Erro ao trocar para Passageiro: $e');
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
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Ir para Passageiro',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _trocarParaPassageiro,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            auth.when(
              data: (user) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user != null ? 'Conta: ${user.email}' : 'Faça login para usar o app'),
                  if (user != null && user.perfilTipo.isNotEmpty) Text('Modo: ${user.perfilTipo}'),
                  TextButton.icon(
                    onPressed: () => context.goNamed('perfil'),
                    icon: const Icon(Icons.settings),
                    label: const Text('Editar dados'),
                  ),
                ],
              ),
              loading: () => const Text('Verificando conta...'),
              error: (e, _) => Text('Erro na conta: $e'),
            ),
            const SizedBox(height: 16),
            if (_status != null) Text(_status!),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _posicao == null
                    ? Container(
                        color: Colors.grey.shade100,
                        child: const Center(child: Text('Localização não disponível')),
                      )
                    : FlutterMap(
                        options: MapOptions(
                          initialCenter: _posicao!,
                          initialZoom: 15,
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
                              Marker(
                                point: _posicao!,
                                width: 40,
                                height: 40,
                                child: const Icon(Icons.location_pin, color: Colors.red, size: 36),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'O app envia sua localização automaticamente a cada 10s e verifica corridas atribuídas.',
            ),
          ],
        ),
      ),
    );
  }
}
