import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../device/device_provider.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _loading = false;
  String? _mensagem;

  Future<void> _escolherPerfil(String tipo) async {
    setState(() {
      _loading = true;
      _mensagem = null;
    });
    try {
      await ref.read(deviceProvider.notifier).ensureRegistrado(tipo: tipo);
      setState(() => _mensagem = 'Entrou como ${tipo == "passageiro" ? "Passageiro" : "EcoTaxista"}');
      if (!mounted) return;
      if (tipo == 'passageiro') {
        context.go('/passageiro');
      } else {
        context.go('/motorista');
      }
    } catch (e) {
      setState(() => _mensagem = 'Erro ao registrar: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vai Paquetá'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              device.when(
                data: (info) => Text('UUID: ${info?.deviceUuid ?? "registrando..."}'),
                loading: () => const Text('Registrando dispositivo...'),
                error: (e, _) => Text('Erro: $e'),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _loading ? null : () => _escolherPerfil('passageiro'),
                  icon: const Icon(Icons.person),
                  label: Text(_loading ? 'Aguarde...' : 'Entrar como Passageiro'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _loading ? null : () => _escolherPerfil('ecotaxista'),
                  icon: const Icon(Icons.local_taxi),
                  label: Text(_loading ? 'Aguarde...' : 'Entrar como EcoTaxista'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              if (_mensagem != null) ...[
                const SizedBox(height: 16),
                Text(_mensagem!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
