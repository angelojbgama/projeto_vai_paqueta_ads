import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_messages.dart';
import '../../core/phone_countries.dart';
import '../../widgets/message_banner.dart';
import '../auth/auth_provider.dart';
import '../auth/auth_service.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final _nomeCtrl = TextEditingController();
  final _dddNumeroCtrl = TextEditingController();
  String _selectedDdi = '55';
  late final Future<List<PhoneCountry>> _countriesFuture;
  bool _saving = false;
  AppMessage? _mensagem;
  int? _lastUserId;

  @override
  void initState() {
    super.initState();
    _countriesFuture = PhoneCountryService.load();
  }

  @override
  void dispose() {
    _nomeCtrl.dispose();
    _dddNumeroCtrl.dispose();
    super.dispose();
  }

  String _digitsOnly(String value) {
    return value.replaceAll(RegExp(r'\D+'), '');
  }

  String _formatPhoneDisplay(String raw) {
    final parts = _parsePhoneParts(raw);
    if (parts.ddd.isEmpty && parts.numero.isEmpty) return raw;
    final ddi = parts.ddi.isNotEmpty ? '+${parts.ddi}' : '';
    final ddd = parts.ddd.isNotEmpty ? '(${parts.ddd})' : '';
    final numero = parts.numero;
    return [ddi, ddd, numero].where((p) => p.isNotEmpty).join(' ');
  }

  String _formatDddNumero(_PhoneParts parts) {
    if (parts.ddd.isEmpty && parts.numero.isEmpty) return '';
    if (parts.ddd.isEmpty) return parts.numero;
    if (parts.numero.isEmpty) return parts.ddd;
    return '${parts.ddd} ${parts.numero}';
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

  _PhoneParts _parsePhoneParts(String raw) {
    final text = raw.trim();
    if (!text.startsWith('+')) {
      final localDigits = _digitsOnly(text);
      if (localDigits.length >= 8 && localDigits.length <= 11) {
        return _PhoneParts(
          ddi: '55',
          ddd: localDigits.substring(0, 2),
          numero: localDigits.substring(2),
        );
      }
    }
    final regex = RegExp(r'^\+(\d+)\s*\((\d+)\)\s*(\d+)$');
    final match = regex.firstMatch(text);
    if (match != null) {
      return _PhoneParts(
        ddi: match.group(1) ?? '55',
        ddd: match.group(2) ?? '',
        numero: match.group(3) ?? '',
      );
    }
    final digits = _digitsOnly(text);
    if (digits.isEmpty) {
      return const _PhoneParts(ddi: '55', ddd: '', numero: '');
    }
    if (digits.startsWith('55') && digits.length >= 4) {
      return _PhoneParts(
        ddi: '55',
        ddd: digits.substring(2, 4),
        numero: digits.substring(4),
      );
    }
    if (digits.startsWith('1') && digits.length >= 4) {
      return _PhoneParts(
        ddi: '1',
        ddd: digits.substring(1, 4),
        numero: digits.substring(4),
      );
    }
    final ddi = digits.length >= 2 ? digits.substring(0, 2) : digits;
    final rest = digits.substring(ddi.length);
    final ddd = rest.length >= 2 ? rest.substring(0, 2) : rest;
    final numero = rest.length >= 2 ? rest.substring(2) : '';
    return _PhoneParts(ddi: ddi, ddd: ddd, numero: numero);
  }

  void _preencherCampos(AuthUser? user) {
    if (user == null) {
      if (_lastUserId != null) {
        _lastUserId = null;
        _nomeCtrl.text = '';
        _selectedDdi = '55';
        _dddNumeroCtrl.text = '';
      }
      return;
    }
    if (_lastUserId != user.id) {
      _lastUserId = user.id;
      _nomeCtrl.text = user.nome;
      final parts = _parsePhoneParts(user.telefone);
      _selectedDdi = parts.ddi;
      _dddNumeroCtrl.text = _formatDddNumero(parts);
      return;
    }
    if (_nomeCtrl.text.isEmpty && user.nome.isNotEmpty) {
      _nomeCtrl.text = user.nome;
    }
    if (_dddNumeroCtrl.text.isEmpty && user.telefone.isNotEmpty) {
      final parts = _parsePhoneParts(user.telefone);
      _selectedDdi = parts.ddi;
      _dddNumeroCtrl.text = _formatDddNumero(parts);
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
    final ddi = _digitsOnly(_selectedDdi);
    final split = _splitDddNumero(ddi, _dddNumeroCtrl.text);
    final ddd = _digitsOnly(split.ddd);
    final numero = _digitsOnly(split.numero);
    if (nome.isEmpty) {
      setState(() => _mensagem = const AppMessage('Preencha nome.', MessageTone.error));
      return;
    }
    if (ddi.isEmpty || ddd.isEmpty || numero.isEmpty) {
      setState(() => _mensagem = const AppMessage('Informe DDI, DDD e número.', MessageTone.error));
      return;
    }
    setState(() {
      _saving = true;
      _mensagem = null;
    });
    try {
      await ref.read(authProvider.notifier).atualizarPerfil(nome: nome, ddi: ddi, ddd: ddd, numero: numero);
      if (!mounted) return;
      setState(() => _mensagem = const AppMessage('Dados atualizados com sucesso.', MessageTone.success));
    } catch (e) {
      if (!mounted) return;
      setState(() => _mensagem = AppMessage('Erro ao atualizar: ${friendlyError(e)}', MessageTone.error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _clearErrorMessage() {
    if (_mensagem?.tone == MessageTone.error) {
      setState(() => _mensagem = null);
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
                  Text('Telefone atual: ${_formatPhoneDisplay(user.telefone)}', style: Theme.of(context).textTheme.bodySmall),
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
                onChanged: (_) => _clearErrorMessage(),
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
                          onChanged: _saving
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
                    flex: 5,
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
                      onChanged: (_) => _clearErrorMessage(),
                    ),
                  ),
                    ],
                  );
                },
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
                MessageBanner(
                  message: _mensagem!,
                  onClose: () => setState(() => _mensagem = null),
                ),
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

class _PhoneParts {
  final String ddi;
  final String ddd;
  final String numero;

  const _PhoneParts({required this.ddi, required this.ddd, required this.numero});
}

class _DddNumero {
  final String ddd;
  final String numero;

  const _DddNumero({required this.ddd, required this.numero});
}
