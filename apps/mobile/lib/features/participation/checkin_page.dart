import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'participation_panel.dart';
import 'participation_repository.dart';
import 'participation_store.dart';

class CheckinPage extends ConsumerStatefulWidget {
  const CheckinPage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<CheckinPage> createState() => _CheckinState();
}

class _CheckinState extends ConsumerState<CheckinPage>
    with WidgetsBindingObserver {
  late ParticipationStore store;
  final input = TextEditingController();
  int? generation;
  String get base => 'v1/experiences/${widget.id}';
  @override
  void initState() {
    super.initState();
    store = ref.read(participationStoreProvider('$base/participation'));
    generation = store.access.generation;
    store.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) store.resume();
    });
  }

  void _changed() {
    if (generation != store.access.generation) {
      generation = store.access.generation;
      input.clear();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      store.resume();
    } else {
      input.clear();
      store.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_changed);
    store.pause();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(participationStoreProvider('$base/participation'));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in'),
        actions: [
          IconButton(
            tooltip: 'Atualizar check-in',
            onPressed: () => store.load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final d = store.document;
                final owner = d?['is_owner'] == true;
                final actions = ((d?['actions'] as List?) ?? []).cast<String>();
                final result = store.transient;
                return ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(
                      owner
                          ? 'Confira a presença no local'
                          : 'Mostre seu código ao organizador',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'O organizador autenticado confere a pessoa presencialmente e valida seu código temporário. O código sozinho não concede participação.',
                    ),
                    const SizedBox(height: 16),
                    if (store.loading || store.busy)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Conferindo check-in',
                      ),
                    if (store.issue != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(participationMessage(store.issue)),
                        ),
                      ),
                    if (d == null && !store.loading)
                      OutlinedButton(
                        onPressed: () => store.load(),
                        child: const Text('Consultar situação atual'),
                      ),
                    if (d != null) ...[
                      if (d['external_ticket'] == true)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Text(externalAttendanceNotice),
                        ),
                      if (d['checked_in'] == true)
                        Semantics(
                          liveRegion: true,
                          child: Text('Check-in confirmado'),
                        ),
                      if (owner && d['checkin_open'] == true) ...[
                        TextField(
                          controller: input,
                          maxLength: 19,
                          autocorrect: false,
                          enableSuggestions: false,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            labelText: 'Código do participante',
                            helperText: '16 caracteres, com ou sem hífens',
                          ),
                          enabled: !store.busy,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: store.busy
                              ? null
                              : () async {
                                  final code = input.text.trim();
                                  if (code.isEmpty) return;
                                  final ok = await store.command(
                                    'POST',
                                    '$base/check-ins/validate',
                                    body: {'code': code},
                                    keepResult: true,
                                    reload: false,
                                  );
                                  if (ok) input.clear();
                                },
                          icon: const Icon(Icons.verified_outlined),
                          label: const Text('Validar presença'),
                        ),
                      ] else if (owner)
                        const Text(
                          'A conferência está fora da janela permitida ou a experiência está indisponível.',
                        ),
                      if (!owner && actions.contains('checkin_credential'))
                        FilledButton.tonalIcon(
                          onPressed: store.busy
                              ? null
                              : () => store.command(
                                  'POST',
                                  '$base/check-in-credential',
                                  credential: true,
                                  keepResult: true,
                                  reload: false,
                                ),
                          icon: const Icon(Icons.confirmation_number_outlined),
                          label: Text(
                            result?['code'] != null
                                ? 'Gerar novo código'
                                : 'Gerar meu código',
                          ),
                        ),
                      if (!owner &&
                          !actions.contains('checkin_credential') &&
                          d['checked_in'] != true)
                        const Text(
                          'Check-in indisponível. É preciso ter participação confirmada e estar na janela permitida.',
                        ),
                    ],
                    if (result?['code'] case final String code) ...[
                      const SizedBox(height: 24),
                      Semantics(
                        label: 'Código temporário: $code',
                        child: Text(
                          [
                            for (var i = 0; i < code.length; i += 4)
                              code.substring(i, (i + 4).clamp(0, code.length)),
                          ].join('-'),
                          style: Theme.of(context).textTheme.headlineMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Este código expira em poucos minutos. Gerar outro invalida o anterior. Se ele desaparecer, atualize a situação e gere um novo.',
                      ),
                    ],
                    if (result?['checked_at'] != null) ...[
                      const SizedBox(height: 24),
                      Semantics(
                        liveRegion: true,
                        child: Text('Presença confirmada'),
                      ),
                      Text(
                        'Participante: ${result!['display_name'] ?? result['user_id']}',
                      ),
                      TextButton(
                        onPressed: () => store.load(),
                        child: const Text('Atualizar situação'),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
