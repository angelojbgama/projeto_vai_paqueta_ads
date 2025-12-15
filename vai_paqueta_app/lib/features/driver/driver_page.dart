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
import '../device/device_provider.dart';
import 'driver_service.dart';

class DriverPage extends ConsumerStatefulWidget {
  const DriverPage({super.key});

  @override
  ConsumerState<DriverPage> createState() => _DriverPageState();
}

class _DriverPageState extends ConsumerState<DriverPage> {
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
    _configurarFonteTiles();
    _atualizarPosicao();
    _verificarCorrida();
    _iniciarAutoPing();
    _iniciarPollingCorrida();
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  double _round6(double value) => double.parse(value.toStringAsFixed(6));

  Future<void> _enviarPing({bool silencioso = false}) async {
    if (_enviando) return;
    final device = ref.read(deviceProvider).valueOrNull;
    if (device == null || device.perfilTipo != 'ecotaxista') {
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
        perfilId: device.perfilId,
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
    if (_modalAberto) return;
    final device = ref.read(deviceProvider).valueOrNull;
    if (device == null || device.perfilTipo != 'ecotaxista') return;
    try {
      final service = DriverService();
      final corrida = await service.corridaAtribuida(device.perfilId);
      if (corrida != null && corrida.isNotEmpty) {
        _corridaAtual = corrida;
        _mostrarModalCorrida(corrida);
      }
    } catch (e) {
      // silencioso para polling
      debugPrint('Erro ao verificar corrida: $e');
    }
  }

  Future<void> _mostrarModalCorrida(Map<String, dynamic> corrida) async {
    _modalAberto = true;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.local_taxi, color: Colors.green, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    'Nova corrida',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (corrida['origem_endereco'] != null)
                Text('Origem: ${corrida['origem_endereco']}', style: Theme.of(context).textTheme.bodyMedium),
              if (corrida['destino_endereco'] != null)
                Text('Destino: ${corrida['destino_endereco']}', style: Theme.of(context).textTheme.bodyMedium),
              if (corrida['id'] != null) Text('Corrida #${corrida['id']}'),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        );
      },
    );
    _modalAberto = false;
  }

  Future<void> _trocarParaPassageiro() async {
    setState(() {
      _trocandoPerfil = true;
      _status = null;
    });
    try {
      await ref.read(deviceProvider.notifier).ensureRegistrado(tipo: 'passageiro');
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
    final device = ref.watch(deviceProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ecotaxista'),
        actions: [
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
            device.when(
              data: (info) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('UUID: ${info?.deviceUuid ?? "-"}'),
                  Text('Perfil: ${info?.perfilTipo ?? "-"}'),
                ],
              ),
              loading: () => const Text('Registrando dispositivo...'),
              error: (e, _) => Text('Erro: $e'),
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
