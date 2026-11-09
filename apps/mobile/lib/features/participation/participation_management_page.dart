import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../experiences/presentation/widgets/experience_widgets.dart';
import 'participation_repository.dart';
import 'participation_store.dart';

class ParticipationManagementPage extends ConsumerStatefulWidget {
  const ParticipationManagementPage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<ParticipationManagementPage> createState() =>
      _ManagementState();
}

class _ManagementState extends ConsumerState<ParticipationManagementPage>
    with WidgetsBindingObserver {
  late ParticipationStore settings, people, invites;
  final capacity = TextEditingController(), recipient = TextEditingController();
  String mode = 'FREE', tab = 'participants', filter = 'PENDING';
  bool seeded = false;
  int? generation;
  String get base => 'v1/experiences/${widget.id}';
  ParticipationStore get list => tab == 'participants' ? people : invites;
  @override
  void initState() {
    super.initState();
    settings = ref.read(
      participationStoreProvider('$base/participation-settings'),
    );
    people = ref.read(participationStoreProvider('$base/participants'));
    invites = ref.read(participationStoreProvider('$base/invitations'));
    generation = settings.access.generation;
    settings.addListener(_sync);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        settings.load();
        people.select({'state': filter, 'limit': 20});
      }
    });
  }

  void _sync() {
    if (!mounted) return;
    if (generation != settings.access.generation) {
      generation = settings.access.generation;
      seeded = false;
      capacity.clear();
      recipient.clear();
      mode = 'FREE';
    }
    if (!seeded && settings.document != null) {
      seeded = true;
      mode = settings.document!['mode'] as String? ?? 'FREE';
      capacity.text = settings.document!['capacity']?.toString() ?? '';
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      settings.resume();
      list.resume();
    } else {
      settings.pause();
      people.pause();
      invites.pause();
      recipient.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    settings.removeListener(_sync);
    settings.pause();
    people.pause();
    invites.pause();
    capacity.dispose();
    recipient.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await settings.load();
    await list.load();
  }

  Future<void> _save() async {
    final d = settings.document;
    if (d == null) return;
    final text = capacity.text.trim();
    final n = text.isEmpty ? null : int.tryParse(text);
    if (text.isNotEmpty && (n == null || n < 1 || n > 1000000)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Informe uma capacidade entre 1 e 1.000.000, ou deixe vazia.',
          ),
        ),
      );
      return;
    }
    final ok = await settings.command(
      'PUT',
      '$base/participation-settings',
      body: {'mode': mode, 'capacity': n},
      etag: '"${d['version']}-${d['experience_version']}"',
    );
    if (ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Modalidade e capacidade atualizadas.')),
      );
    }
  }

  Future<void> _person(Map<String, dynamic> row, String action) async {
    final g = people.access.generation;
    if ({'remove', 'block'}.contains(action)) {
      final yes = await confirmExperienceAction(
        context,
        title: action == 'block'
            ? 'Bloquear nesta experiência?'
            : 'Remover participação?',
        message: 'A participação e o check-in serão revogados. Convites existentes deixam de conceder acesso. Esta ação não bloqueia a pessoa em outras experiências.',
        action: action == 'block' ? 'Bloquear' : 'Remover',
      );
      if (!yes || !mounted || g != people.access.generation) return;
    }
    await people.command(
      'POST',
      '$base/participants/${row['user_id']}/$action',
    );
    await settings.load();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(participationStoreProvider('$base/participation-settings'));
    ref.watch(participationStoreProvider('$base/participants'));
    ref.watch(participationStoreProvider('$base/invitations'));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Participantes'),
        actions: [
          IconButton(
            tooltip: 'Atualizar participantes',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListenableBuilder(
              listenable: Listenable.merge([settings, people, invites]),
              builder: (context, _) {
                final d = settings.document;
                final busy = settings.busy || people.busy || invites.busy;
                final canManage = d?['can_manage'] == true;
                final canConfigure = d?['can_configure'] == true;
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Text(
                        'Receba as pessoas da sua experiência',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Somente você pode consultar a lista nominal e gerenciar participações.',
                      ),
                      const SizedBox(height: 16),
                      if (settings.loading || list.loading || busy)
                        const LinearProgressIndicator(
                          semanticsLabel: 'Atualizando participantes',
                        ),
                      if (settings.issue != null)
                        Text(participationMessage(settings.issue)),
                      if (d == null && !settings.loading)
                        OutlinedButton(
                          onPressed: () => settings.load(),
                          child: const Text('Consultar configuração'),
                        ),
                      if (d != null) ...[
                        Text(
                          '${d['confirmed_count']} confirmações · capacidade ${d['capacity'] ?? 'sem limite'}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          'Atual: ${modeLabel(d['mode'] as String)}. Alterar a modalidade não desfaz confirmações.',
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: mode,
                          decoration: const InputDecoration(
                            labelText: 'Modalidade de participação',
                          ),
                          isExpanded: true,
                          items: [
                            for (final m
                                in (d['visibility'] == 'PRIVATE'
                                    ? ['INVITE']
                                    : ['FREE', 'APPROVAL', 'INVITE']))
                              DropdownMenuItem(
                                value: m,
                                child: Text(modeLabel(m)),
                              ),
                          ],
                          onChanged: (busy || !canConfigure)
                              ? null
                              : (v) => setState(() => mode = v!),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: capacity,
                          keyboardType: TextInputType.number,
                          maxLength: 7,
                          decoration: const InputDecoration(
                            labelText: 'Capacidade',
                            helperText: 'Vazio significa sem limite. Você não ocupa vaga.',
                          ),
                          enabled: !busy && canConfigure,
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton(
                            onPressed: busy || !canConfigure ? null : _save,
                            child: const Text('Salvar modalidade e capacidade'),
                          ),
                        ),
                        const Divider(height: 32),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  settings.pause();
                                  people.pause();
                                  invites.pause();
                                  await context.push(
                                    '/experiences/${widget.id}/check-in',
                                  );
                                  if (mounted) {
                                    await settings.resume();
                                    await list.resume();
                                  }
                                },
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('Conferir check-in no local'),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final entry in {
                              'participants': 'Pessoas',
                              'invitations': 'Convites',
                            }.entries)
                              ChoiceChip(
                                label: Text(entry.value),
                                selected: tab == entry.key,
                                onSelected: busy
                                    ? null
                                    : (_) {
                                        setState(() => tab = entry.key);
                                        list.resume();
                                      },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (tab == 'participants')
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final entry in {
                                  'PENDING': 'Solicitações',
                                  'CONFIRMED': 'Confirmados',
                                  'REMOVED': 'Removidos',
                                  '': 'Todos',
                                }.entries)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(entry.value),
                                      selected: filter == entry.key,
                                      onSelected: busy
                                          ? null
                                          : (_) {
                                              setState(
                                                () => filter = entry.key,
                                              );
                                              people.select({
                                                'state': ?entry.key.isEmpty
                                                    ? null
                                                    : entry.key,
                                                'limit': 20,
                                              });
                                            },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (tab == 'invitations') ...[
                          const Text(
                            'Convide uma conta existente pelo @handle exato ou UUID interno. Não importamos contatos.',
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: recipient,
                            maxLength: 36,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: '@handle ou identificador do usuário',
                            ),
                            enabled: !busy && canManage,
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonal(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (!canManage) return;
                                      final value = recipient.text.trim();
                                      if (value.isEmpty) return;
                                      final isID = RegExp(r'^[0-9a-fA-F-]{36}$')
                                          .hasMatch(value);
                                      final ok = await invites.command(
                                        'POST',
                                        '$base/invitations',
                                        body: {
                                          isID ? 'user_id' : 'handle': value,
                                        },
                                      );
                                      if (ok && context.mounted) {
                                        recipient.clear();
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Convite disponível na agenda do destinatário.',
                                                ),
                                              ),
                                            );
                                      }
                                    },
                              child: const Text('Enviar convite'),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (list.issue != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(participationMessage(list.issue)),
                          ),
                        if (list.rows.isEmpty && !list.loading)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Column(
                              children: [
                                const Text('Nenhuma pessoa nesta lista.'),
                                TextButton(
                                  onPressed: () => list.load(),
                                  child: const Text('Atualizar lista'),
                                ),
                              ],
                            ),
                          ),
                        for (final row in list.rows)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (row['display_name'] as String? ?? '')
                                            .isEmpty
                                        ? 'Pessoa participante'
                                        : row['display_name'] as String,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  if (row['handle'] != null)
                                    Text('@${row['handle']}'),
                                  Text(
                                    tab == 'invitations' &&
                                            row['state'] == 'PENDING'
                                        ? 'Convite pendente'
                                        : participationLabel(
                                            row['state'] as String?,
                                          ),
                                  ),
                                  if (row['blocked'] == true)
                                    const Text('Bloqueado nesta experiência'),
                                  if (row['checked_in'] == true)
                                    const Text('Check-in confirmado'),
                                  if (tab == 'invitations') ...[
                                    if (row['expired'] == true)
                                      const Text('Convite expirado'),
                                    if (row['state'] == 'PENDING')
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () => invites.command(
                                                'POST',
                                                'v1/invitations/${row['id']}/revoke',
                                              ),
                                        child: const Text('Revogar convite'),
                                      ),
                                  ] else
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        if (row['state'] == 'PENDING') ...[
                                          FilledButton.tonal(
                                            onPressed: busy || !canManage
                                                ? null
                                                : () => _person(row, 'approve'),
                                            child: const Text('Aprovar'),
                                          ),
                                          TextButton(
                                            onPressed: busy || !canManage
                                                ? null
                                                : () => _person(row, 'decline'),
                                            child: const Text('Recusar'),
                                          ),
                                        ],
                                        if (row['state'] == 'CONFIRMED')
                                          TextButton(
                                            onPressed: busy || !canManage
                                                ? null
                                                : () => _person(row, 'remove'),
                                            child: const Text(
                                              'Remover participação',
                                            ),
                                          ),
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : !canManage
                                              ? null
                                              : () => _person(
                                                  row,
                                                  row['blocked'] == true
                                                      ? 'unblock'
                                                      : 'block',
                                                ),
                                          child: Text(
                                            row['blocked'] == true
                                                ? 'Desbloquear'
                                                : 'Bloquear nesta experiência',
                                          ),
                                        ),
                                        if (row['checked_in'] == true)
                                          TextButton(
                                            onPressed: busy
                                                ? null
                                                : () => people.command(
                                                    'POST',
                                                    '$base/check-ins/${row['user_id']}/revoke',
                                                  ),
                                            child: const Text(
                                              'Revogar check-in',
                                            ),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (list.cursor != null)
                          OutlinedButton(
                            onPressed: list.moreLoading
                                ? null
                                : () => list.load(more: true),
                            child: Text(
                              list.moreLoading
                                  ? 'Carregando…'
                                  : 'Carregar mais',
                            ),
                          ),
                      ],
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
