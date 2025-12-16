import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_provider.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _loading = false;
  String? _mensagem;

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    context.go('/auth');
  }

  Future<void> _escolherPerfil(String tipo) async {
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      if (mounted) context.go('/auth');
      return;
    }
    setState(() {
      _loading = true;
      _mensagem = null;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(tipo: tipo);
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
    final auth = ref.watch(authProvider);
    final loggedIn = auth.valueOrNull != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Vai Paquetá'),
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
          if (loggedIn)
            IconButton(
              tooltip: 'Sair',
              onPressed: _logout,
              icon: const Icon(Icons.logout),
            )
          else
            IconButton(
              tooltip: 'Login / Cadastro',
              onPressed: () => context.go('/auth'),
              icon: const Icon(Icons.person),
            ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              auth.when(
                data: (user) => Text(user != null ? 'Conta: ${user.email}' : 'Não autenticado'),
                loading: () => const Text('Verificando conta...'),
                error: (e, _) => Text('Erro de conta: $e'),
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
