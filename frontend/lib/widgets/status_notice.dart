import 'package:flutter/material.dart';

enum StatusNoticeTone { error, warning, neutral }

class StatusNotice extends StatelessWidget {
  const StatusNotice({
    required this.title,
    required this.message,
    required this.tone,
    this.actionLabel,
    this.onAction,
    this.isBusy = false,
    super.key,
  });

  final String title;
  final String message;
  final StatusNoticeTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final _NoticePalette palette = _palette(Theme.of(context).colorScheme, tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.foreground.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _NoticeHeading(
              title: title,
              palette: palette,
              tone: tone,
              isBusy: isBusy,
            ),
            const SizedBox(height: 8),
            Text(message, style: TextStyle(color: palette.foreground, height: 1.35)),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: palette.foreground,
                  foregroundColor: palette.background,
                ),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeHeading extends StatelessWidget {
  const _NoticeHeading({
    required this.title,
    required this.palette,
    required this.tone,
    required this.isBusy,
  });

  final String title;
  final _NoticePalette palette;
  final StatusNoticeTone tone;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _NoticeIcon(palette: palette, tone: tone, isBusy: isBusy),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: palette.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _NoticeIcon extends StatelessWidget {
  const _NoticeIcon({
    required this.palette,
    required this.tone,
    required this.isBusy,
  });

  final _NoticePalette palette;
  final StatusNoticeTone tone;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    if (isBusy) {
      return SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: palette.foreground),
      );
    }
    return Icon(_icon(tone), color: palette.foreground);
  }
}

class _NoticePalette {
  const _NoticePalette(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_NoticePalette _palette(ColorScheme scheme, StatusNoticeTone tone) {
  switch (tone) {
    case StatusNoticeTone.error:
      return _NoticePalette(scheme.errorContainer, scheme.onErrorContainer);
    case StatusNoticeTone.warning:
      return _NoticePalette(scheme.tertiaryContainer, scheme.onTertiaryContainer);
    case StatusNoticeTone.neutral:
      return _NoticePalette(scheme.secondaryContainer, scheme.onSecondaryContainer);
  }
}

IconData _icon(StatusNoticeTone tone) {
  switch (tone) {
    case StatusNoticeTone.error:
      return Icons.error_outline;
    case StatusNoticeTone.warning:
      return Icons.hourglass_bottom;
    case StatusNoticeTone.neutral:
      return Icons.info_outline;
  }
}
