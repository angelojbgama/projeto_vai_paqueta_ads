import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'fcm_service.dart';
import 'notification_service.dart';

class NotificationPermissionPromptService {
  NotificationPermissionPromptService._();

  static const Duration _promptCooldown = Duration(seconds: 15);
  static bool _running = false;
  static DateTime? _lastPromptAt;

  static Future<void> maybePrompt(BuildContext context) async {
    if (!context.mounted || kIsWeb || _running) return;
    final now = DateTime.now();
    if (_lastPromptAt != null && now.difference(_lastPromptAt!) < _promptCooldown) {
      return;
    }
    _running = true;
    try {
      final enabledNative = await NotificationService.areNotificationsEnabled();
      final enabledFcm = await FcmService.areNotificationsAuthorized();
      final enabled = enabledNative && enabledFcm;
      if (!context.mounted || enabled) return;

      final aceitou = await _showRationaleDialog(context);
      _lastPromptAt = DateTime.now();
      if (!context.mounted || !aceitou) return;

      await NotificationService.requestPermissions();
      await FcmService.requestPermissions();

      if (!context.mounted) return;
      final enabledAfterRequest = await NotificationService.areNotificationsEnabled();
      if (!context.mounted || enabledAfterRequest) return;
      await _showOpenSettingsDialog(context);
    } finally {
      _running = false;
    }
  }

  static Future<bool> _showRationaleDialog(BuildContext context) async {
    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Permitir notificações'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Precisamos das notificações para avisar sobre novas corridas e atualizações importantes.',
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.notifications_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Você recebe alertas mesmo com o app fechado.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.volume_up_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Som e vibração ajudam a não perder corridas.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.settings_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Você pode alterar isso depois nas configurações do Android.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Continuar'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  static Future<void> _showOpenSettingsDialog(BuildContext context) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ativar notificações'),
          content: const Text(
            'O Android não liberou as notificações por aqui. Vamos abrir as configurações do app para você ativar manualmente.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await Geolocator.openAppSettings();
              },
              child: const Text('Abrir configurações'),
            ),
          ],
        );
      },
    );
  }
}
