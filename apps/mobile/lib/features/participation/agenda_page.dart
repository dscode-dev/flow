import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../experiences/domain/experience_time.dart';
import 'participation_repository.dart';
import 'participation_store.dart';

class AgendaPage extends ConsumerStatefulWidget {
  const AgendaPage({super.key});
  @override
  ConsumerState<AgendaPage> createState() => _AgendaPageState();
}

class _AgendaPageState extends ConsumerState<AgendaPage>
    with WidgetsBindingObserver {
  late ParticipationStore store;
  String section = 'upcoming';
  static const sections = {
    'upcoming': 'Próximas',
    'interests': 'Interesses',
    'pending': 'Solicitações',
    'invitations': 'Convites',
    'history': 'Histórico',
  };
  @override
  void initState() {
    super.initState();
    store = ref.read(participationStoreProvider('v1/me/agenda'));
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) store.select({'section': section, 'limit': 20});
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

  @override
  Widget build(BuildContext context) {
    ref.watch(participationStoreProvider('v1/me/agenda'));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minha Agenda'),
        actions: [
          IconButton(
            tooltip: 'Atualizar agenda',
            onPressed: () => store.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                return RefreshIndicator(
                  onRefresh: () => store.load(),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Text(
                        'Seus próximos encontros',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Interesse, participação e presença são situações diferentes.',
                      ),
                      const SizedBox(height: 16),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final entry in sections.entries)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(entry.value),
                                  selected: section == entry.key,
                                  onSelected: store.busy
                                      ? null
                                      : (_) {
                                          setState(() => section = entry.key);
                                          store.select({
                                            'section': section,
                                            'limit': 20,
                                          });
                                        },
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (store.loading || store.busy)
                        const LinearProgressIndicator(
                          semanticsLabel: 'Atualizando agenda',
                        ),
                      if (store.issue != null && store.rows.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(participationMessage(store.issue)),
                          ),
                        ),
                      if (store.rows.isEmpty && !store.loading)
                        FlowStateView(
                          kind: store.issue != null
                              ? FlowViewState.error
                              : FlowViewState.empty,
                          message: store.issue != null
                              ? participationMessage(store.issue)
                              : store.expired
                              ? 'Atualize sua agenda para conferir a situação atual.'
                              : 'Nenhuma experiência nesta seção.',
                          onRetry: () => store.load(),
                        ),
                      for (final row in store.rows)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  row['title'] as String? ?? 'Experiência',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                const SizedBox(height: 6),
                                if (row['accessible'] == true)
                                  Text(
                                    ExperienceTime.display(
                                      DateTime.tryParse(
                                        row['starts_at'] as String? ?? '',
                                      ),
                                      row['timezone'] as String?,
                                    ),
                                  ),
                                if ((row['venue_name'] as String? ?? '')
                                    .isNotEmpty)
                                  Text(row['venue_name'] as String),
                                Text(
                                  section == 'invitations'
                                      ? 'Convite recebido'
                                      : participationLabel(
                                          row['effective_state'] as String?,
                                        ),
                                ),
                                if (row['checked_in'] == true)
                                  const Text('Check-in confirmado'),
                                if (row['external_ticket'] == true)
                                  const Text(
                                    'Ingresso externo: confirmação no Flow não comprova pagamento.',
                                  ),
                                if (row['accessible'] == true)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      TextButton(
                                        onPressed: () async {
                                          store.pause();
                                          await context.push(
                                            '/experiences/${row['experience_id']}',
                                          );
                                          if (mounted) store.resume();
                                        },
                                        child: const Text('Ver experiência'),
                                      ),
                                      if (section == 'invitations')
                                        for (final action in [
                                          'accept',
                                          'decline',
                                        ])
                                          TextButton(
                                            onPressed: store.busy
                                                ? null
                                                : () async {
                                                    await store.command(
                                                      'POST',
                                                      'v1/invitations/${row['invitation_id']}/$action',
                                                    );
                                                  },
                                            child: Text(
                                              action == 'accept'
                                                  ? 'Aceitar convite'
                                                  : 'Recusar convite',
                                            ),
                                          ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (store.cursor != null)
                        OutlinedButton(
                          onPressed: store.moreLoading
                              ? null
                              : () => store.load(more: true),
                          child: Text(
                            store.moreLoading ? 'Carregando…' : 'Carregar mais',
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
