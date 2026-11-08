import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../design/tokens.dart';
import '../../data/experiences_repository.dart';
import '../../domain/experience.dart';
import '../../domain/experience_issue.dart';
import '../../domain/experience_time.dart';

class ExperienceIssueView extends StatelessWidget {
  const ExperienceIssueView(
    this.issue, {
    super.key,
    this.retry,
    this.actionLabel = 'Tentar novamente',
  });
  final AuthIssue issue;
  final VoidCallback? retry;
  final String actionLabel;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            issue.message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          if (issue.retryAfter case final retry?)
            Text(
              'Aguarde pelo menos ${retry.inSeconds} segundos. O limite diário pode durar mais.',
            ),
          if (issue.requestId case final id?)
            Text(
              'Referência: $id',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (retry != null)
            TextButton(onPressed: retry, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}

class ExperienceStatusBadge extends StatelessWidget {
  const ExperienceStatusBadge(this.experience, {super.key});
  final Experience experience;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      Chip(
        label: Text(experience.status.label),
        visualDensity: VisualDensity.compact,
        side: BorderSide.none,
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
      ),
      if (experience.phase case final phase?)
        Chip(
          visualDensity: VisualDensity.compact,
          label: Text(switch (phase) {
            'UPCOMING' => 'Em breve',
            'LIVE' => 'Acontecendo',
            'ENDED' => 'Encerrada',
            _ => 'Fase indisponível',
          }),
        ),
    ],
  );
}

/// Decoded only in widget memory: no ImageProvider, global image cache, disk or
/// signed URL. Access changes, backgrounding and failed revalidation clear pixels.
class ExperienceCover extends ConsumerStatefulWidget {
  const ExperienceCover(
    this.experience, {
    super.key,
    this.compact = false,
    this.onAccessDenied,
  });
  final Experience experience;
  final bool compact;
  final VoidCallback? onAccessDenied;
  @override
  ConsumerState<ExperienceCover> createState() => _ExperienceCoverState();
}

class _ExperienceCoverState extends ConsumerState<ExperienceCover>
    with WidgetsBindingObserver {
  ui.Image? _image;
  CancelToken? _cancel;
  late ExperienceAccess _access;
  int _generation = 0;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_clear);
    _load();
  }

  void _clear() {
    _generation++;
    _cancel?.cancel();
    _image?.dispose();
    _image = null;
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _clear();
    _failed = false;
    if (widget.experience.detailsRedacted ||
        widget.experience.input.coverMediaId == null ||
        _access.ownerId == null) {
      return;
    }
    final g = _generation;
    final c = _cancel = CancelToken();
    ui.Codec? codec;
    try {
      final bytes = await ref
          .read(experiencesRepositoryProvider)
          .cover(widget.experience.id, cancel: c);
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: widget.compact ? 160 : 1024,
      );
      final frame = await codec.getNextFrame();
      if (!mounted || g != _generation) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (error) {
      if (mounted && g == _generation) {
        setState(() => _failed = true);
        if (error is AuthIssue && {403, 404}.contains(error.status)) {
          widget.onAccessDenied?.call();
        }
      }
    } finally {
      codec?.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant ExperienceCover old) {
    super.didUpdateWidget(old);
    if (old.experience.id != widget.experience.id ||
        old.experience.input.coverMediaId !=
            widget.experience.input.coverMediaId ||
        old.experience.version != widget.experience.version ||
        old.experience.detailsRedacted != widget.experience.detailsRedacted) {
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    } else {
      _clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_clear);
    _cancel?.cancel();
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(FlowRadius.card),
    child: AspectRatio(
      aspectRatio: widget.compact ? 1 : 16 / 9,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: FlowColors.accent),
        child: _image != null
            ? Semantics(
                label: 'Capa da experiência',
                image: true,
                child: RawImage(image: _image, fit: BoxFit.cover),
              )
            : Center(
                child: _failed && !widget.compact
                    ? IconButton(
                        tooltip: 'Tentar carregar capa novamente',
                        onPressed: _load,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                      )
                    : const Icon(
                        Icons.landscape_outlined,
                        color: Colors.white,
                        size: 32,
                      ),
              ),
      ),
    ),
  );
}

class ExperienceSummary extends StatelessWidget {
  const ExperienceSummary(
    this.input, {
    super.key,
    this.categoryName,
    this.redacted = false,
  });
  final ExperienceInput input;
  final String? categoryName;
  final bool redacted;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        input.title.isEmpty ? 'Sua nova experiência' : input.title,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      if (input.categoryId != null)
        Text(
          categoryName ?? input.categoryId!,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      const SizedBox(height: 20),
      _line(
        context,
        Icons.schedule,
        ExperienceTime.display(input.startsAt, input.timezone),
      ),
      if (input.endsAt != null)
        _line(
          context,
          Icons.timelapse,
          'Até ${ExperienceTime.display(input.endsAt, input.timezone)}',
        ),
      if (redacted)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(
            'Os detalhes desta experiência não estão disponíveis neste histórico.',
          ),
        ),
      if (!redacted) ...[
        if (input.venueName.isNotEmpty)
          _line(context, Icons.place_outlined, input.venueName),
        if (input.address.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 36, bottom: 8),
            child: Text(input.address),
          ),
        if (input.location case final point?)
          Padding(
            padding: const EdgeInsets.only(left: 36, bottom: 8),
            child: Text(
              '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (input.capacity != null)
          _line(
            context,
            Icons.people_outline,
            'Capacidade informada: ${input.capacity}. Sem reserva de vaga.',
          ),
        _line(context, Icons.visibility_outlined, input.visibility.label),
        Text(
          input.visibility.explanation,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        if (input.description.isNotEmpty)
          Text(input.description, style: Theme.of(context).textTheme.bodyLarge),
      ],
    ],
  );
  Widget _line(BuildContext context, IconData icon, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 16),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

Uri? safeTicketUri(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.host.isEmpty ||
      uri.port != 443 ||
      !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host) ||
      !uri.host.contains('.') ||
      uri.host.toLowerCase() == 'localhost' ||
      RegExp(r'^[0-9.]+$').hasMatch(uri.host) ||
      raw.length > 2048) {
    return null;
  }
  return uri;
}

Future<bool> confirmExperienceAction(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<void> openTicket(BuildContext context, String raw) async {
  final uri = safeTicketUri(raw);
  if (uri == null) return;
  final agreed = await confirmExperienceAction(
    context,
    title: 'Abrir site externo?',
    message:
        'Você vai sair do Flow e abrir ${uri.host}. A compra ocorre fora do aplicativo; Flow não verifica pagamento nem garante ingresso.',
    action: 'Abrir site',
  );
  if (!agreed || !context.mounted) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o site.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o site.')),
      );
    }
  }
}
