import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_state.dart';
import '../../../../design/components.dart';
import '../../application/experience_controllers.dart';
import '../../data/experiences_repository.dart';
import '../../domain/experience.dart';
import '../widgets/experience_widgets.dart';

class ExperienceDetailPage extends ConsumerStatefulWidget {
  const ExperienceDetailPage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<ExperienceDetailPage> createState() =>
      _ExperienceDetailPageState();
}

class _ExperienceDetailPageState extends ConsumerState<ExperienceDetailPage>
    with WidgetsBindingObserver {
  late ExperienceDetailController _controller;
  List<ExperienceCategory> _categories = [];
  String? _checkedCover;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(experienceDetailProvider(widget.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.load();
        _catalog();
      }
    });
  }

  Future<void> _catalog() async {
    try {
      final v = await ref.read(experiencesRepositoryProvider).categories();
      if (mounted) setState(() => _categories = v);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller.load();
  }

  Future<void> _transition(Experience e, String action) async {
    final title = switch (action) {
      'publish' => 'Publicar experiência?',
      'cancel' => 'Cancelar experiência?',
      _ => 'Arquivar experiência?',
    };
    final message = switch (action) {
      'publish' =>
        '${e.input.visibility.explanation}\n\nConfira título, descrição, categoria, agenda, fuso e local. Após publicar, agenda, local, categoria, capacidade e audiência ficam protegidos.',
      'cancel' =>
        'O cancelamento não pode ser desfeito. O histórico será preservado.',
      _ => 'A experiência ficará no histórico arquivado. Não será possível republicá-la.',
    };
    final confirmed = await confirmExperienceAction(
      context,
      title: title,
      message: message,
      action: switch (action) {
        'publish' => 'Publicar',
        'cancel' => 'Cancelar experiência',
        _ => 'Arquivar',
      },
    );
    if (confirmed && mounted) await _controller.transition(action);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(experienceDetailProvider(widget.id));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Experiência'),
        leading: BackButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/experiences'),
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar experiência',
            onPressed: () => _controller.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ValueListenableBuilder(
          valueListenable: _controller,
          builder: (context, state, _) {
            final e = state.experience;
            if (state.loading) {
              return const FlowStateView(
                kind: FlowViewState.loading,
                message: 'Abrindo experiência…',
              );
            }
            if (e == null) {
              return FlowStateView(
                kind: FlowViewState.error,
                message: state.issue?.message ?? 'Experiência indisponível.',
                onRetry: () => _controller.load(),
              );
            }
            final owner =
                ref.read(authControllerProvider).value.user?.id == e.creatorId;
            final category = _categories
                .where((c) => c.id == e.input.categoryId)
                .firstOrNull
                ?.name;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: RefreshIndicator(
                  onRefresh: () => _controller.load(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    children: [
                      if (!e.detailsRedacted)
                        ExperienceCover(
                          e,
                          onAccessDenied: () {
                            final key =
                                '${e.id}:${e.version}:${e.input.coverMediaId}';
                            if (_checkedCover != key) {
                              _checkedCover = key;
                              _controller.load();
                            }
                          },
                        ),
                      const SizedBox(height: 16),
                      ExperienceStatusBadge(e),
                      const SizedBox(height: 16),
                      ExperienceSummary(
                        e.input,
                        categoryName: category,
                        redacted: e.detailsRedacted,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        owner ? 'Organizado por você' : 'Organizador',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (owner)
                        Text(
                          ref
                                  .read(authControllerProvider)
                                  .value
                                  .user
                                  ?.displayName ??
                              '',
                        )
                      else
                        SelectableText(
                          e.creatorId,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (!e.detailsRedacted &&
                          safeTicketUri(e.input.externalTicketUrl ?? '') !=
                              null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                openTicket(context, e.input.externalTicketUrl!),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Ingressos em site externo'),
                          ),
                        ),
                      if (state.issue != null)
                        ExperienceIssueView(
                          state.issue!,
                          retry: () => _controller.load(),
                          actionLabel: 'Buscar versão atual',
                        ),
                      if (state.busy)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: LinearProgressIndicator(
                            semanticsLabel: 'Confirmando operação',
                          ),
                        ),
                      if (owner && !e.detailsRedacted) ...[
                        const Divider(height: 40),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (e.editable)
                              OutlinedButton.icon(
                                onPressed: state.busy
                                    ? null
                                    : () async {
                                        await context.push(
                                          '/experiences/${e.id}/edit',
                                        );
                                        if (mounted) _controller.load();
                                      },
                                icon: const Icon(Icons.edit_outlined),
                                label: Text(
                                  e.status == ExperienceStatus.draft
                                      ? 'Retomar rascunho'
                                      : 'Editar',
                                ),
                              ),
                            if (e.status == ExperienceStatus.draft)
                              FilledButton.icon(
                                onPressed: state.busy
                                    ? null
                                    : () => _transition(e, 'publish'),
                                icon: const Icon(Icons.publish),
                                label: const Text('Publicar'),
                              ),
                            if (e.cancelSuggested)
                              TextButton(
                                onPressed: state.busy
                                    ? null
                                    : () => _transition(e, 'cancel'),
                                child: const Text('Cancelar experiência'),
                              ),
                            if (e.archiveSuggested)
                              TextButton(
                                onPressed: state.busy
                                    ? null
                                    : () => _transition(e, 'archive'),
                                child: const Text('Arquivar'),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
