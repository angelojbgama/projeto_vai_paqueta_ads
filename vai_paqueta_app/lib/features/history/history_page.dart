import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/device_provider.dart';
import '../rides/rides_service.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  List<CorridaResumo> _corridas = [];
  bool _loading = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final device = ref.read(deviceProvider).valueOrNull;
    if (device == null) {
      setState(() => _erro = 'Dispositivo não registrado.');
      return;
    }
    setState(() {
      _loading = true;
      _erro = null;
    });
    try {
      final service = RidesService();
      final dados = await service.listarCorridas(perfilId: device.perfilId);
      setState(() => _corridas = dados);
    } catch (e) {
      setState(() => _erro = 'Erro ao carregar histórico: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Histórico'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _erro != null
              ? Center(child: Text(_erro!))
              : ListView.separated(
                  itemCount: _corridas.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final c = _corridas[index];
                    return ListTile(
                      title: Text('Corrida ${c.id}'),
                      subtitle: Text('Status: ${c.status}'),
                      trailing: const Icon(Icons.chevron_right),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _carregar,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

