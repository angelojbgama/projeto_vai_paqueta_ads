import 'package:flutter/material.dart';

enum MessageTone { info, success, warning, error }

class AppMessage {
  final String text;
  final MessageTone tone;

  const AppMessage(this.text, this.tone);
}

class MessageBanner extends StatelessWidget {
  final AppMessage message;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry? margin;

  const MessageBanner({
    super.key,
    required this.message,
    this.onClose,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color bg;
    Color fg;
    Color border;
    IconData icon;

    switch (message.tone) {
      case MessageTone.success:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        border = Colors.green.shade200;
        icon = Icons.check_circle_outline;
        break;
      case MessageTone.warning:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade800;
        border = Colors.amber.shade200;
        icon = Icons.warning_amber_outlined;
        break;
      case MessageTone.error:
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        border = Colors.red.shade200;
        icon = Icons.error_outline;
        break;
      case MessageTone.info:
        bg = Colors.blueGrey.shade50;
        fg = Colors.blueGrey.shade800;
        border = Colors.blueGrey.shade200;
        icon = Icons.info_outline;
        break;
    }

    return Container(
      margin: margin ?? const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(color: fg),
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              color: fg,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
