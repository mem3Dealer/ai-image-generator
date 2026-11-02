import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/generation_options.dart';
import '../../core/subscription_status.dart';
import '../../core/user_messages.dart';
import '../../widgets/status_notice.dart';
import '../subscription/paywall_sheet.dart';
import '../subscription/subscription_bloc.dart';
import '../subscription/subscription_state.dart';
import 'generate_bloc.dart';
import 'generate_state.dart';

class GeneratePage extends StatefulWidget {
  const GeneratePage({super.key});

  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  late final TextEditingController _prompt;
  late GenerationOptions _options;
  bool _restoredForm = false;
  bool _isPaywallOpen = false;
  bool _isResolvingPremium = false;
  bool _showSubscriptionError = false;

  @override
  void initState() {
    super.initState();
    _prompt = TextEditingController();
    _options = freeGenerationOptions;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredForm) {
      return;
    }
    _restoredForm = true;
    final GenerateState state = context.read<GenerateBloc>().state;
    if (state is! GenerateIdle || state.activeGeneration == null) {
      return;
    }
    _prompt.text = state.activeGeneration!.prompt;
    _options = state.activeGeneration!.options;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<GenerateBloc, GenerateState>(
      listenWhen: _isNewPremiumRejection,
      listener: _onPremiumRejection,
      builder: (BuildContext context, GenerateState state) {
        final _Presentation? presentation = _presentation(state);
        final bool noticeOwnsAction = presentation?.actionLabel != null;
        final bool isInvalidRequest = _isInvalidRequest(state);
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: <Widget>[
            Text('Create', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(
              'Describe an image. Free styles are ready to use.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 6,
              enabled: state is! GenerateInProgress,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                alignLabelWithHint: true,
                hintText: 'Describe the image',
              ),
            ),
            if (isInvalidRequest && presentation != null) ...<Widget>[
              const SizedBox(height: 12),
              _presentationNotice(presentation, state),
            ],
            const _SectionTitle('Style'),
            _choiceGrid(
              choices: _styles,
              columns: 2,
              selected: _options.style,
              enabled: state is! GenerateInProgress,
              onSelected: (String value) => _choose(_options.copyWith(style: value)),
            ),
            const _SectionTitle('Aspect ratio'),
            _choiceGrid(
              choices: _aspectRatios,
              columns: 3,
              selected: _options.aspectRatio,
              enabled: state is! GenerateInProgress,
              onSelected: (String value) => _choose(_options.copyWith(aspectRatio: value)),
            ),
            const _SectionTitle('Quality'),
            _choiceGrid(
              choices: _qualities,
              columns: 2,
              selected: _options.quality,
              enabled: state is! GenerateInProgress,
              onSelected: (String value) => _choose(_options.copyWith(quality: value)),
            ),
            if (_isResolvingPremium) ...<Widget>[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_showSubscriptionError) const _SubscriptionCheckError(),
            if (state is GenerateSuccess && state.entry.imagePath != null) ...<Widget>[
              const SizedBox(height: 16),
              _ResultImage(path: state.entry.imagePath!),
            ],
            if (presentation != null && !isInvalidRequest) ...<Widget>[
              const SizedBox(height: 16),
              _presentationNotice(presentation, state),
            ],
            if (!noticeOwnsAction) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _actionFor(state),
                child: Text(_labelFor(state)),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _choiceGrid({
    required List<_Choice> choices,
    required int columns,
    required String selected,
    required bool enabled,
    required ValueChanged<String> onSelected,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double spacing = 8;
        final double tileWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final _Choice choice in choices)
              SizedBox(
                width: tileWidth,
                child: ChoiceChip(
                  showCheckmark: false,
                  label: SizedBox(
                    width: double.infinity,
                    child: Text(
                      _chipLabel(choice),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  selected: selected == choice.value,
                  onSelected: enabled
                      ? (bool isSelected) {
                          if (isSelected) {
                            onSelected(choice.value);
                          }
                        }
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _choose(GenerationOptions next) async {
    if (_isPaywallOpen || _isResolvingPremium) {
      return;
    }
    if (context.read<GenerateBloc>().state is GenerateInProgress) {
      return;
    }
    if (!_addsPremium(next)) {
      setState(() => _options = next);
      return;
    }
    final SubscriptionStatus status = context.read<SubscriptionBloc>().state.status;
    if (status == SubscriptionStatus.premium) {
      setState(() => _options = next);
      return;
    }
    if (status == SubscriptionStatus.free) {
      await _openPaywall(options: next, revertOnDismiss: false);
      return;
    }
    await _resolvePremium(next);
  }

  Future<void> _resolvePremium(GenerationOptions next) async {
    setState(() {
      _isResolvingPremium = true;
      _showSubscriptionError = false;
    });
    final SubscriptionStatus resolved = await context.read<SubscriptionBloc>().refresh();
    if (!mounted) {
      return;
    }
    setState(() => _isResolvingPremium = false);
    if (resolved == SubscriptionStatus.premium) {
      setState(() => _options = next);
      return;
    }
    if (resolved == SubscriptionStatus.free) {
      await _openPaywall(options: next, revertOnDismiss: false);
      return;
    }
    setState(() => _showSubscriptionError = true);
  }

  Future<void> _openPaywall({
    required GenerationOptions options,
    required bool revertOnDismiss,
  }) async {
    if (_isPaywallOpen) {
      return;
    }
    setState(() => _isPaywallOpen = true);
    final bool purchased = await showPaywall(context);
    if (!mounted) {
      return;
    }
    setState(() {
      _isPaywallOpen = false;
      if (purchased) {
        _options = options;
        _showSubscriptionError = false;
        return;
      }
      if (revertOnDismiss) {
        _options = _withoutPremium(_options);
      }
    });
  }

  void _onPremiumRejection(BuildContext context, GenerateState state) {
    final GenerateFailure failure = state as GenerateFailure;
    final GenerationOptions options = failure.rejectedOptions ?? _options;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyPremiumRejection(options);
    });
  }

  Future<void> _applyPremiumRejection(GenerationOptions options) async {
    await context.read<SubscriptionBloc>().applyPremiumDenied();
    if (!mounted) {
      return;
    }
    await _openPaywall(options: options, revertOnDismiss: true);
  }

  VoidCallback? _actionFor(GenerateState state) {
    if (state is GenerateInProgress || _isPaywallOpen || _isResolvingPremium) {
      return null;
    }
    if (state is GenerateIdle && state.activeGeneration != null) {
      return () => context.read<GenerateBloc>().continueActive();
    }
    return () {
      context.read<GenerateBloc>().generate(prompt: _prompt.text, options: _options);
    };
  }

  bool _addsPremium(GenerationOptions next) {
    final bool styleAdded = _isPremiumStyle(next.style) && next.style != _options.style;
    final bool qualityAdded = next.quality == hdQuality && _options.quality != hdQuality;
    return styleAdded || qualityAdded;
  }

  Widget _presentationNotice(_Presentation presentation, GenerateState state) {
    return StatusNotice(
      title: presentation.title,
      message: presentation.message,
      tone: presentation.tone,
      actionLabel: presentation.actionLabel,
      onAction: presentation.actionLabel == null ? null : _actionFor(state),
      isBusy: presentation.isBusy,
    );
  }
}

class _ResultImage extends StatelessWidget {
  const _ResultImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.file(
        File(path),
        height: 280,
        width: double.infinity,
        fit: BoxFit.contain,
      ),
    );
  }
}

class _SubscriptionCheckError extends StatelessWidget {
  const _SubscriptionCheckError();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SubscriptionBloc, SubscriptionState>(
      builder: (BuildContext context, SubscriptionState state) {
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: StatusNotice(
            title: 'Subscription check failed',
            message: state.errorMessage ?? couldNotCheckSubscriptionMessage,
            tone: StatusNoticeTone.error,
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _Choice {
  const _Choice(this.value, this.label, this.isPremium);

  final String value;
  final String label;
  final bool isPremium;
}

const List<_Choice> _styles = <_Choice>[
  _Choice(photorealisticStyle, 'Photorealistic', false),
  _Choice(digitalArtStyle, 'Digital Art', false),
  _Choice(animeStyle, 'Anime', true),
  _Choice(cinematicStyle, 'Cinematic', true),
];

const List<_Choice> _aspectRatios = <_Choice>[
  _Choice(squareAspectRatio, '1:1', false),
  _Choice(portraitAspectRatio, '2:3', false),
  _Choice(wideAspectRatio, '16:9', false),
];

const List<_Choice> _qualities = <_Choice>[
  _Choice(standardQuality, 'Standard', false),
  _Choice(hdQuality, 'HD', true),
];

bool _isNewPremiumRejection(GenerateState previous, GenerateState current) {
  return current is GenerateFailure &&
      current.kind == GenerateFailureKind.premiumRequired &&
      previous != current;
}

String _chipLabel(_Choice choice) {
  if (choice.isPremium) {
    return '${choice.label} · Premium';
  }
  return choice.label;
}

String _labelFor(GenerateState state) {
  if (state is GenerateInProgress) {
    return 'Generating';
  }
  if (state is GenerateIdle && state.activeGeneration != null) {
    return 'Check again';
  }
  if (state is GenerateFailure && _retries(state.kind)) {
    return 'Retry';
  }
  return 'Generate';
}

bool _retries(GenerateFailureKind kind) {
  return kind == GenerateFailureKind.generationFailed ||
      kind == GenerateFailureKind.requestFailed;
}

_Presentation? _presentation(GenerateState state) {
  if (state is GenerateInProgress) {
    return const _Presentation(
      title: 'Generating',
      message: 'The image is being created on the server.',
      tone: StatusNoticeTone.neutral,
      isBusy: true,
    );
  }
  if (state is GenerateFailure && state.kind != GenerateFailureKind.premiumRequired) {
    return _failurePresentation(state);
  }
  if (state is GenerateIdle && state.activeGeneration != null) {
    return _activePresentation(state);
  }
  return null;
}

_Presentation _failurePresentation(GenerateFailure state) {
  return _Presentation(
    title: _failureTitle(state.kind),
    message: state.message,
    tone: StatusNoticeTone.error,
    actionLabel: _retries(state.kind) ? 'Retry' : null,
  );
}

_Presentation _activePresentation(GenerateIdle state) {
  if (state.isInterrupted) {
    return const _Presentation(
      title: 'Check stopped',
      message: checkStoppedMessage,
      tone: StatusNoticeTone.warning,
      actionLabel: 'Check again',
    );
  }
  return const _Presentation(
    title: 'Still in progress',
    message: stillInProgressMessage,
    tone: StatusNoticeTone.neutral,
    actionLabel: 'Check again',
  );
}

String _failureTitle(GenerateFailureKind kind) {
  switch (kind) {
    case GenerateFailureKind.generationFailed:
      return 'Generation failed';
    case GenerateFailureKind.requestFailed:
      return 'Request failed';
    case GenerateFailureKind.invalidRequest:
      return 'Check your input';
    case GenerateFailureKind.unavailable:
      return 'Generation unavailable';
    case GenerateFailureKind.premiumRequired:
      return 'Premium required';
  }
}

bool _isInvalidRequest(GenerateState state) {
  return state is GenerateFailure && state.kind == GenerateFailureKind.invalidRequest;
}

class _Presentation {
  const _Presentation({
    required this.title,
    required this.message,
    required this.tone,
    this.actionLabel,
    this.isBusy = false,
  });

  final String title;
  final String message;
  final StatusNoticeTone tone;
  final String? actionLabel;
  final bool isBusy;
}

bool _isPremiumStyle(String style) {
  return style == animeStyle || style == cinematicStyle;
}

GenerationOptions _withoutPremium(GenerationOptions options) {
  return GenerationOptions(
    style: _isPremiumStyle(options.style) ? photorealisticStyle : options.style,
    aspectRatio: options.aspectRatio,
    quality: options.quality == hdQuality ? standardQuality : options.quality,
  );
}
