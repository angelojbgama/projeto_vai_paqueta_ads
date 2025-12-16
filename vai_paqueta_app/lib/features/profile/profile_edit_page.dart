import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_provider.dart';
import '../auth/auth_service.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final _nomeCtrl = TextEditingController();
  final _telefoneCtrl = TextEditingController();
  bool _saving = false;
  String? _mensagem;
  int? _lastUserId;

  @override
  void dispose() {
    _nomeCtrl.dispose();
    _telefoneCtrl.dispose();
    super.dispose();
  }

  void _preencherCampos(AuthUser? user) {
    if (user == null) {
      if (_lastUserId != null) {
        _lastUserId = null;
        _nomeCtrl.text = '';
        _telefoneCtrl.text = '';
      }
      return;
    }
    if (_lastUserId != user.id) {
      _lastUserId = user.id;
      _nomeCtrl.text = user.nome;
      _telefoneCtrl.text = user.telefone;
      return;
    }
    if (_nomeCtrl.text.isEmpty && user.nome.isNotEmpty) {
      _nomeCtrl.text = user.nome;
    }
    if (_telefoneCtrl.text.isEmpty && user.telefone.isNotEmpty) {
      _telefoneCtrl.text = user.telefone;
    }
  }

  Future<void> _salvar() async {
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      if (!mounted) return;
      context.go('/auth');
      return;
    }
    final nome = _nomeCtrl.text.trim();
    final telefone = _telefoneCtrl.text.trim();
    if (nome.isEmpty || telefone.isEmpty) {
      setState(() => _mensagem = 'Preencha nome e telefone.');
      return;
    }
    setState(() {
      _saving = true;
      _mensagem = null;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(nome: nome, telefone: telefone);
      if (!mounted) return;
      setState(() => _mensagem = 'Dados atualizados com sucesso.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _mensagem = 'Erro ao atualizar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _voltar() {
    final user = ref.read(authProvider).valueOrNull;
    if (user == null) {
      if (Navigator.of(context).canPop()) {
        context.pop();
      } else {
        context.go('/auth');
      }
      return;
    }
    if (user.perfilTipo == 'ecotaxista') {
      context.go('/motorista');
    } else {
      context.go('/passageiro');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.valueOrNull;
    _preencherCampos(user);
    final loggedIn = user != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar dados'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (loggedIn) ...[
                Text('Conta: ${user.email}', style: Theme.of(context).textTheme.titleMedium),
                if (user.nome.isNotEmpty) Text('Nome atual: ${user.nome}', style: Theme.of(context).textTheme.bodySmall),
                if (user.telefone.isNotEmpty)
                  Text('Telefone atual: ${user.telefone}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
              ] else ...[
                const Text('Faça login para editar seus dados.'),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () => context.go('/auth'),
                  icon: const Icon(Icons.login),
                  label: const Text('Ir para login'),
                ),
              ],
              TextField(
                controller: _nomeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nome',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _telefoneCtrl,
                decoration: const InputDecoration(
                  labelText: 'Telefone',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _voltar,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Voltar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _saving || !loggedIn ? null : _salvar,
                      icon: const Icon(Icons.save),
                      label: Text(_saving ? 'Salvando...' : 'Salvar alterações'),
                    ),
                  ),
                ],
              ),
              if (_mensagem != null) ...[
                const SizedBox(height: 12),
                Text(_mensagem!),
              ],
              if (authState.isLoading || _saving)
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
