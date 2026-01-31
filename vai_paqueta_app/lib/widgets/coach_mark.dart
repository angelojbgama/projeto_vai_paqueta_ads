import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/driver_settings.dart';

class CoachMarkStep {
  final GlobalKey targetKey;
  final String title;
  final String description;
  final EdgeInsets highlightPadding;
  final double borderRadius;
  final CoachMarkBubblePlacement bubblePlacement;

  const CoachMarkStep({
    required this.targetKey,
    required this.title,
    required this.description,
    this.highlightPadding = const EdgeInsets.all(8),
    this.borderRadius = 12,
    this.bubblePlacement = CoachMarkBubblePlacement.auto,
  });
}

enum CoachMarkBubblePlacement { auto, center }

Future<bool> showCoachMarks(BuildContext context, List<CoachMarkStep> steps) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  var skipped = false;
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    if (step.targetKey.currentContext == null) continue;
    await _ensureVisible(step.targetKey);
    if (step.targetKey.currentContext == null) continue;
    final completer = Completer<_CoachMarkAction>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => _CoachMarkOverlay(
        step: step,
        isLast: i == steps.length - 1,
        onNext: () {
          entry.remove();
          if (!completer.isCompleted) completer.complete(_CoachMarkAction.next);
        },
        onSkip: () {
          entry.remove();
          if (!completer.isCompleted) completer.complete(_CoachMarkAction.skip);
        },
      ),
    );
    overlay.insert(entry);
    final action = await completer.future;
    if (action == _CoachMarkAction.skip) {
      skipped = true;
      break;
    }
    await Future<void>.delayed(UiTimings.coachMarkStepDelay);
  }
  return !skipped;
}

Future<void> _ensureVisible(GlobalKey key) async {
  final targetContext = key.currentContext;
  if (targetContext == null) return;
  try {
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.5,
      duration: UiTimings.coachMarkScrollDuration,
      curve: Curves.easeOut,
    );
  } catch (_) {
    // Ignore if no scrollable ancestor.
  }
  await Future<void>.delayed(UiTimings.coachMarkStepDelay);
}

enum _CoachMarkAction { next, skip }

class _CoachMarkOverlay extends StatefulWidget {
  final CoachMarkStep step;
  final VoidCallback onNext;
  final VoidCallback onSkip;
  final bool isLast;

  const _CoachMarkOverlay({
    required this.step,
    required this.onNext,
    required this.onSkip,
    required this.isLast,
  });

  @override
  State<_CoachMarkOverlay> createState() => _CoachMarkOverlayState();
}

class _CoachMarkOverlayState extends State<_CoachMarkOverlay> {
  Rect? _targetRect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveTarget());
  }

  @override
  void didUpdateWidget(covariant _CoachMarkOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.targetKey != widget.step.targetKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveTarget());
    }
  }

  void _resolveTarget() {
    if (!mounted) return;
    final targetContext = widget.step.targetKey.currentContext;
    if (targetContext == null) return;
    final targetBox = targetContext.findRenderObject() as RenderBox?;
    final overlayBox = context.findRenderObject() as RenderBox?;
    if (targetBox == null || overlayBox == null) return;
    final topLeft = targetBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    setState(() => _targetRect = topLeft & targetBox.size);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (_targetRect == null) {
      return const SizedBox.shrink();
    }
    final padded = _applyPadding(_targetRect!, widget.step.highlightPadding);
    final highlightRect = Rect.fromLTRB(
      max(0, padded.left),
      max(0, padded.top),
      min(size.width, padded.right),
      min(size.height, padded.bottom),
    );
    final bubbleWidth = min(320.0, size.width - 32.0);
    final hasSpaceBelow = highlightRect.bottom + 180 < size.height;
    final showBelow = hasSpaceBelow || highlightRect.center.dy < size.height * 0.45;
    final left = (highlightRect.center.dx - bubbleWidth / 2).clamp(16.0, size.width - bubbleWidth - 16.0);
    final arrowLeft = (highlightRect.center.dx - left).clamp(16.0, bubbleWidth - 16.0);
    final autoBubble = _SpeechBubble(
      title: widget.step.title,
      description: widget.step.description,
      arrowUp: showBelow,
      arrowLeft: arrowLeft,
      isLast: widget.isLast,
      onNext: widget.onNext,
      onSkip: widget.onSkip,
    );
    final centerBubble = _SpeechBubble(
      title: widget.step.title,
      description: widget.step.description,
      arrowUp: true,
      arrowLeft: bubbleWidth / 2,
      isLast: widget.isLast,
      onNext: widget.onNext,
      onSkip: widget.onSkip,
    );

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _HolePainter(
                holeRect: highlightRect,
                radius: widget.step.borderRadius,
                color: Colors.black.withAlpha(166),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: highlightRect,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.step.borderRadius),
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ),
          if (widget.step.bubblePlacement == CoachMarkBubblePlacement.center)
            Center(
              child: SizedBox(
                width: bubbleWidth,
                child: centerBubble,
              ),
            )
          else if (showBelow)
            Positioned(
              left: left,
              top: min(size.height - 16.0, highlightRect.bottom + 12.0),
              width: bubbleWidth,
              child: autoBubble,
            )
          else
            Positioned(
              left: left,
              bottom: min(size.height - 16.0, size.height - highlightRect.top + 12.0),
              width: bubbleWidth,
              child: autoBubble,
            ),
        ],
      ),
    );
  }
}

Rect _applyPadding(Rect rect, EdgeInsets padding) {
  return Rect.fromLTRB(
    rect.left - padding.left,
    rect.top - padding.top,
    rect.right + padding.right,
    rect.bottom + padding.bottom,
  );
}

class _HolePainter extends CustomPainter {
  final Rect holeRect;
  final double radius;
  final Color color;

  _HolePainter({
    required this.holeRect,
    required this.radius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addRRect(RRect.fromRectAndRadius(holeRect, Radius.circular(radius)));
    final combined = Path.combine(PathOperation.difference, overlay, hole);
    canvas.drawPath(combined, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _HolePainter oldDelegate) {
    return oldDelegate.holeRect != holeRect ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color;
  }
}

class _SpeechBubble extends StatelessWidget {
  final String title;
  final String description;
  final bool arrowUp;
  final double arrowLeft;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _SpeechBubble({
    required this.title,
    required this.description,
    required this.arrowUp,
    required this.arrowLeft,
    required this.isLast,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(51),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(description, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onSkip,
                child: const Text('Pular'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onNext,
                child: Text(isLast ? 'Concluir' : 'Proximo'),
              ),
            ],
          ),
        ],
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (arrowUp)
          Positioned(
            top: -8,
            left: arrowLeft - 10,
            child: const _Arrow(direction: _ArrowDirection.up),
          ),
        Padding(
          padding: EdgeInsets.only(top: arrowUp ? 8 : 0, bottom: arrowUp ? 0 : 8),
          child: bubble,
        ),
        if (!arrowUp)
          Positioned(
            bottom: -8,
            left: arrowLeft - 10,
            child: const _Arrow(direction: _ArrowDirection.down),
          ),
      ],
    );
  }
}

enum _ArrowDirection { up, down }

class _Arrow extends StatelessWidget {
  final _ArrowDirection direction;

  const _Arrow({required this.direction});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(20, 8),
      painter: _ArrowPainter(direction: direction, color: Colors.white),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  final _ArrowDirection direction;
  final Color color;

  _ArrowPainter({required this.direction, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (direction == _ArrowDirection.up) {
      path.moveTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) {
    return oldDelegate.direction != direction || oldDelegate.color != color;
  }
}
