import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../experiences/presentation/widgets/experience_widgets.dart';
import 'participation_repository.dart';
import 'participation_store.dart';
import '../experiences/domain/experience_issue.dart';

const externalAttendanceNotice =
    'A confirmação e o check-in no Flow não comprovam pagamento nem validam ingresso externo. O organizador pode fazer uma conferência própria no local.';

class ParticipationPanel extends ConsumerStatefulWidget {
  const ParticipationPanel(this.experienceId, {super.key, this.onChanged});
  final String experienceId;
  final VoidCallback? onChanged;
  @override
  ConsumerState<ParticipationPanel> createState() => _ParticipationPanelState();
}

class _ParticipationPanelState extends ConsumerState<ParticipationPanel>
    with WidgetsBindingObserver {
  late ParticipationStore store;
  String get base => 'v1/experiences/${widget.experienceId}';
  @override
  void initState() {
    super.initState();
    store = ref.read(participationStoreProvider('$base/participation'));
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) store.load();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      store.resume();
    } else {
      store.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.pause();
    super.dispose();
  }

  Future<void> _act(String action) async {
    final d = store.document;
    if (d == null) return;
    final generation = store.access.generation;
    if (action == 'cancel') {
      final yes = await confirmExperienceAction(
        context,
        title: 'Cancelar participação?',
        message: 'A vaga será liberada e um check-in existente será revogado. Seu interesse é mantido separadamente.',
        action: 'Cancelar participação',
      );
      if (!yes || !mounted || generation != store.access.generation) return;
    }
    String method = 'POST', path = '$base/participation/$action';
    if (action == 'interest' || action == 'uninterest') {
      method = action == 'interest' ? 'PUT' : 'DELETE';
      path = '$base/interest';
    }
    if (action.endsWith('_invitation')) {
      final invite = d['invitation'] as Map?;
      if (invite == null) return;
      path =
          'v1/invitations/${invite['id']}/${action.startsWith('accept') ? 'accept' : 'decline'}';
    }
    final ok = await store.command(method, path);
    final denied =
        store.issue is AuthIssue &&
        {401, 403, 404}.contains((store.issue as AuthIssue).status);
    if (mounted && (ok || denied)) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(participationStoreProvider('$base/participation'));
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final d = store.document;
        final actions = ((d?['actions'] as List?) ?? []).cast<String>();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sua participação',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              if (store.loading || store.busy)
                const LinearProgressIndicator(
                  semanticsLabel: 'Atualizando participação',
                ),
              if (store.issue != null)
                Semantics(
                  liveRegion: true,
                  child: Text(participationMessage(store.issue)),
                ),
              if (d == null && !store.loading && !store.busy)
                TextButton.icon(
                  onPressed: () => store.load(),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    store.expired
                        ? 'Atualizar situação'
                        : 'Consultar participação',
                  ),
                ),
              if (d != null) ...[
                Text(
                  d['is_owner'] == true
                      ? 'Você organiza esta experiência e não ocupa uma vaga.'
                      : participationLabel(d['state'] as String?),
                ),
                if (d['interested'] == true)
                  const Text('Você tem interesse · não reserva vaga'),
                Text(modeLabel(d['mode'] as String? ?? 'FREE')),
                if (d['capacity'] != null)
                  Text(
                    '${d['remaining']} de ${d['capacity']} vagas disponíveis',
                  ),
                if (d['checked_in'] == true) const Text('Check-in confirmado'),
                if (d['external_ticket'] == true)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(externalAttendanceNotice),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final action in actions)
                      if (action == 'manage')
                        OutlinedButton.icon(
                          onPressed: store.busy
                              ? null
                              : () async {
                                  store.pause();
                                  await context.push(
                                    '/experiences/${widget.experienceId}/participants',
                                  );
                                  if (mounted) store.resume();
                                },
                          icon: const Icon(Icons.group_outlined),
                          label: const Text('Gerenciar participantes'),
                        )
                      else if (action == 'checkin_credential')
                        FilledButton.tonalIcon(
                          onPressed: store.busy
                              ? null
                              : () async {
                                  store.pause();
                                  await context.push(
                                    '/experiences/${widget.experienceId}/check-in',
                                  );
                                  if (mounted) store.resume();
                                },
                          icon: const Icon(Icons.confirmation_number_outlined),
                          label: const Text('Meu check-in'),
                        )
                      else if ({
                        'confirm',
                        'request',
                        'accept_invitation',
                      }.contains(action))
                        FilledButton(
                          onPressed: store.busy ? null : () => _act(action),
                          child: Text(_label(action)),
                        )
                      else
                        TextButton(
                          onPressed: store.busy ? null : () => _act(action),
                          child: Text(_label(action)),
                        ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _label(String action) => switch (action) {
    'interest' => 'Tenho interesse',
    'uninterest' => 'Remover interesse',
    'confirm' => 'Vou participar',
    'request' => 'Solicitar participação',
    'cancel' => 'Cancelar solicitação/participação',
    'accept_invitation' => 'Aceitar convite',
    'decline_invitation' => 'Recusar convite',
    _ => 'Atualizar',
  };
}
