import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_config.dart';
import '../auth/auth_provider.dart';
import '../device/device_provider.dart';

class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage> {
  String? _erro;
  String? _detalhe;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // Aguarda o primeiro frame para não modificar providers durante o build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    if (_started) return;
    _started = true;
    try {
      // Garante que o usuário esteja autenticado antes de registrar device.
      final user = await ref.read(authProvider.future);
      if (!mounted) return;
      if (user == null) {
        context.go('/auth');
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Falha ao verificar login.';
        _detalhe = e.toString();
      });
      return;
    }
    final notifier = ref.read(deviceProvider.notifier);
    try {
      final info = await notifier.ensureRegistrado();
      if (!mounted) return;
      if (info?.perfilTipo == 'passageiro') {
        context.go('/passageiro');
      } else if (info?.perfilTipo == 'ecotaxista') {
        context.go('/motorista');
      } else {
        context.go('/home');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Falha ao registrar dispositivo. Verifique a API.';
        _detalhe = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_erro == null) const CircularProgressIndicator(),
            if (_erro != null) const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Text(_erro ?? 'Carregando Vai Paqueta...'),
            const SizedBox(height: 8),
            Text(
              'API: ${ApiConfig.baseUrl}',
              style: const TextStyle(fontSize: 12),
            ),
            if (_erro != null && _detalhe != null) ...[
              const SizedBox(height: 8),
              Text(
                _detalhe!,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
