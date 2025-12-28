import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_messages.dart';
import '../../core/phone_countries.dart';
import '../../widgets/message_banner.dart';
import 'auth_provider.dart';

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _nomeCtrl = TextEditingController();
  final _dddNumeroCtrl = TextEditingController();
  String _selectedDdi = '55';
  late final Future<List<PhoneCountry>> _countriesFuture;
  bool _isRegister = false;
  bool _loading = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;
  AppMessage? _mensagem;
  final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_clearErrorMessage);
    _passwordCtrl.addListener(_clearErrorMessage);
    _confirmPasswordCtrl.addListener(_clearErrorMessage);
    _nomeCtrl.addListener(_clearErrorMessage);
    _dddNumeroCtrl.addListener(_clearErrorMessage);
    _countriesFuture = PhoneCountryService.load();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _nomeCtrl.dispose();
    _dddNumeroCtrl.dispose();
    super.dispose();
  }

  void _clearErrorMessage() {
    if (_mensagem?.tone == MessageTone.error) {
      setState(() => _mensagem = null);
    }
  }

  void _setMessage(String text, MessageTone tone) {
    setState(() => _mensagem = AppMessage(text, tone));
  }

  String _digitsOnly(String value) {
    return value.replaceAll(RegExp(r'\D+'), '');
  }

  _DddNumero _splitDddNumero(String ddi, String raw) {
    final match = RegExp(r'(\d{1,5})\D+(\d{4,})').firstMatch(raw);
    if (match != null) {
      return _DddNumero(
        ddd: match.group(1) ?? '',
        numero: match.group(2) ?? '',
      );
    }
    final digits = _digitsOnly(raw);
    if (digits.isEmpty) {
      return const _DddNumero(ddd: '', numero: '');
    }
    if (ddi == '55' && digits.length >= 3) {
      return _DddNumero(ddd: digits.substring(0, 2), numero: digits.substring(2));
    }
    if (ddi == '1' && digits.length >= 4) {
      return _DddNumero(ddd: digits.substring(0, 3), numero: digits.substring(3));
    }
    if (digits.length >= 3) {
      return _DddNumero(ddd: digits.substring(0, 2), numero: digits.substring(2));
    }
    return const _DddNumero(ddd: '', numero: '');
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
      final ddi = _digitsOnly(_selectedDdi);
      final split = _splitDddNumero(ddi, _dddNumeroCtrl.text);
      final ddd = _digitsOnly(split.ddd);
      final numero = _digitsOnly(split.numero);
      final senhaConfirmar = _confirmPasswordCtrl.text;
      if (_isRegister) {
        if (nome.isEmpty || email.isEmpty || senha.isEmpty || senhaConfirmar.isEmpty) {
          _setMessage('Preencha nome, e-mail e as duas senhas.', MessageTone.error);
          return;
        }
        if (ddi.isEmpty || ddd.isEmpty || numero.isEmpty) {
          _setMessage('Informe DDI, DDD e número do telefone.', MessageTone.error);
          return;
        }
      } else {
        if (email.isEmpty || senha.isEmpty) {
          _setMessage('Preencha e-mail e senha.', MessageTone.error);
          return;
        }
      }
      if (!_emailRegex.hasMatch(email)) {
        _setMessage('Informe um e-mail válido.', MessageTone.error);
        return;
      }
      if (senha.length < 6) {
        _setMessage('Senha deve ter pelo menos 6 caracteres.', MessageTone.error);
        return;
      }
      if (_isRegister && senha != senhaConfirmar) {
        _setMessage('As senhas não coincidem.', MessageTone.error);
        return;
      }
      final notifier = ref.read(authProvider.notifier);
      if (_isRegister) {
        await notifier.register(email, senha, nome: nome, ddi: ddi, ddd: ddd, numero: numero);
        _setMessage('Cadastro realizado com sucesso.', MessageTone.success);
      } else {
        await notifier.login(email, senha);
        _setMessage('Login realizado.', MessageTone.success);
      }
      if (!mounted) return;
      context.go('/splash');
    } catch (e) {
      _setMessage(friendlyError(e), MessageTone.error);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await ref.read(authProvider.notifier).logout();
    if (!mounted) return;
    _setMessage('Sessão encerrada.', MessageTone.info);
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
                if (user.telefone.isNotEmpty) Text('Telefone: ${user.telefone}'),
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
                      onSelected: (_) => setState(() {
                        _isRegister = false;
                        _mensagem = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Cadastro'),
                      selected: _isRegister,
                      onSelected: (_) => setState(() {
                        _isRegister = true;
                        _mensagem = null;
                      }),
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
                if (_isRegister) ...[
                  TextField(
                    controller: _nomeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nome',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<List<PhoneCountry>>(
                    future: _countriesFuture,
                    builder: (context, snapshot) {
                      final countries = snapshot.data ?? PhoneCountryService.fallback;
                      var selected = _selectedDdi;
                      if (!countries.any((c) => c.ddi == selected)) {
                        selected = countries.first.ddi;
                        if (snapshot.hasData) {
                          _selectedDdi = selected;
                        }
                      }
                      return Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: DropdownButtonFormField<String>(
                              value: selected,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'DDI',
                                border: OutlineInputBorder(),
                              ),
                              items: countries
                                  .map(
                                    (c) => DropdownMenuItem<String>(
                                      value: c.ddi,
                                      child: Text(c.label),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _loading
                                  ? null
                                  : (value) {
                                      if (value == null) return;
                                      setState(() => _selectedDdi = value);
                                      _clearErrorMessage();
                                    },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _dddNumeroCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: 'DDD + Número',
                                border: OutlineInputBorder(),
                              ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9\s()-]')),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _passwordCtrl,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: 'Senha',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                ),
                if (_isRegister) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmPasswordCtrl,
                    obscureText: !_showConfirmPassword,
                    decoration: InputDecoration(
                      labelText: 'Repita a senha',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_showConfirmPassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showConfirmPassword = !_showConfirmPassword),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _submit,
                  icon: Icon(_isRegister ? Icons.person_add : Icons.login),
                  label: Text(_loading ? 'Enviando...' : (_isRegister ? 'Criar conta' : 'Entrar')),
                ),
              ],
              if (_mensagem != null) ...[
                const SizedBox(height: 12),
                MessageBanner(
                  message: _mensagem!,
                  onClose: () => setState(() => _mensagem = null),
                ),
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

class _DddNumero {
  final String ddd;
  final String numero;

  const _DddNumero({required this.ddd, required this.numero});
}
