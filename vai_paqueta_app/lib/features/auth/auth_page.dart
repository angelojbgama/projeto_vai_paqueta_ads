import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth_provider.dart';

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nomeCtrl = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  String? _mensagem;
  final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _nomeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _mensagem = null;
    });
    try {
      final email = _emailCtrl.text.trim();
      final senha = _passwordCtrl.text;
      final nome = _nomeCtrl.text.trim();
      if (email.isEmpty || senha.isEmpty) {
        setState(() => _mensagem = 'Preencha e-mail e senha.');
        return;
      }
      if (!_emailRegex.hasMatch(email)) {
        setState(() => _mensagem = 'Informe um e-mail válido.');
        return;
      }
      if (senha.length < 6) {
        setState(() => _mensagem = 'Senha deve ter pelo menos 6 caracteres.');
        return;
      }
      final notifier = ref.read(authProvider.notifier);
      if (_isRegister) {
        await notifier.register(email, senha, nome: nome);
        setState(() => _mensagem = 'Cadastro realizado com sucesso.');
      } else {
        await notifier.login(email, senha);
        setState(() => _mensagem = 'Login realizado.');
      }
      if (!mounted) return;
      context.go('/splash');
    } catch (e) {
      setState(() => _mensagem = 'Erro: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    setState(() => _mensagem = 'Sessão encerrada.');
    context.go('/auth');
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conta'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (user != null) ...[
                Text('Logado como ${user.email}', style: Theme.of(context).textTheme.titleMedium),
                if (user.nome.isNotEmpty) Text(user.nome),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('Sair'),
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('Login'),
                      selected: !_isRegister,
                      onSelected: (_) => setState(() => _isRegister = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Cadastro'),
                      selected: _isRegister,
                      onSelected: (_) => setState(() => _isRegister = true),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                if (_isRegister)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _nomeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nome (opcional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Senha',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _submit,
                  icon: Icon(_isRegister ? Icons.person_add : Icons.login),
                  label: Text(_loading ? 'Enviando...' : (_isRegister ? 'Criar conta' : 'Entrar')),
                ),
              ],
              if (_mensagem != null) ...[
                const SizedBox(height: 12),
                Text(_mensagem!),
              ],
              if (authState.isLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
