import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../social/social_repository.dart';
import '../social/social_widgets.dart';
import '../social/social_media.dart';
import '../explore/flow_playback.dart';
import '../participation/participation_store.dart';
import '../participation/participation_panel.dart';
import '../experiences/data/experiences_repository.dart';

class EventSpacePage extends ConsumerStatefulWidget {
  const EventSpacePage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<EventSpacePage> createState() => _EventSpacePageState();
}

class _EventSpacePageState extends ConsumerState<EventSpacePage>
    with WidgetsBindingObserver {
  late ParticipationStore _summary, _rows;
  ProviderSubscription<ParticipationStore>? _rowSubscription;
  late FlowPlayback _playback;
  late ExperienceAccess _access;
  String _section = 'feed';
  bool _foreground = true;
  String get _base => 'v1/experiences/${widget.id}/space';
  String get _path => '$_base/$_section';
  Map<String, dynamic> get _caps =>
      (_summary.document?['capabilities'] as Map<String, dynamic>?) ?? {};
  @override
  void initState() {
    super.initState();
    _summary = ref.read(socialStoreProvider(_base));
    _rowSubscription?.close();
    _rowSubscription = ref.listenManual(socialStoreProvider(_path), (_, _) {});
    _rows = _rowSubscription!.read();
    _playback = FlowPlayback(ref.read(flowPlayerFactoryProvider));
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  void _account() {
    _pause();
  }

  void _pause() {
    _rows.pause();
    _summary.pause();
    unawaited(_playback.close());
  }

  Future<void> _load() async {
    if (!mounted || !_foreground) return;
    await _playback.close();
    _rows.pause();
    await _summary.resume();
    if (!mounted || !_foreground) return;
    if (_caps['can_read'] == true) {
      if ((_section == 'reports' || _section == 'hidden') &&
          _caps['can_moderate'] != true) {
        _rows.pause();
        setState(() => _section = 'feed');
        _rowSubscription?.close();
        _rowSubscription = ref.listenManual(
          socialStoreProvider(_path),
          (_, _) {},
        );
        _rows = _rowSubscription!.read();
      }
      await _rows.resume();
    }
  }

  Future<void> _select(String section) async {
    _rows.pause();
    await _playback.close();
    if (!mounted) return;
    setState(() => _section = section);
    _rowSubscription?.close();
    _rowSubscription = ref.listenManual(socialStoreProvider(_path), (_, _) {});
    _rows = _rowSubscription!.read();
    await _load();
  }

  Future<void> _open(String path) async {
    _pause();
    await _playback.close();
    if (!mounted) return;
    await context.push(path);
    if (mounted) await _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (ModalRoute.of(context)?.isCurrent ?? false) unawaited(_load());
    } else {
      _pause();
    }
  }

  Future<bool> _delete(String pid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir publicação?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    return _command('DELETE', 'v1/social/posts/$pid');
  }

  Future<bool> _command(
    String method,
    String endpoint, {
    Map<String, dynamic> body = const {},
  }) async {
    await _playback.close();
    final ok = await _rows.command(method, endpoint, body: body, reload: false);
    if (!mounted) return false;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(socialMessage(_rows.issue))));
    }
    await _load();
    return ok;
  }

  Future<void> _report(String pid) async {
    final reason = await socialReportReason(context);
    if (reason != null && mounted) {
      final ok = await _command(
        'POST',
        'v1/social/reports',
        body: {'target_type': 'POST', 'target_id': pid, 'reason': reason},
      );
      if (mounted && ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Denúncia registrada para análise.')),
        );
      }
    }
  }

  Future<void> _moderate(String type, String target, String action) async {
    String selected = 'SAFETY';
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Confirmar ação no espaço?'),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: 'Motivo'),
            items: const [
              DropdownMenuItem(
                value: 'SAFETY',
                child: Text('Segurança do espaço'),
              ),
              DropdownMenuItem(value: 'ABUSE', child: Text('Abuso')),
              DropdownMenuItem(value: 'SPAM', child: Text('Spam')),
              DropdownMenuItem(value: 'PRIVACY', child: Text('Privacidade')),
              DropdownMenuItem(value: 'OTHER', child: Text('Outro motivo')),
            ],
            onChanged: (v) => set(() => selected = v!),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted || !_foreground) return;
    if (action == 'REMOVE') {
      await _command(
        'POST',
        'v1/experiences/${widget.id}/participants/$target/remove',
        body: {'reason': reason},
      );
      return;
    }
    await _command(
      'POST',
      '$_base/moderation',
      body: {
        'target_type': type,
        'target_id': target,
        'action': action,
        'reason': reason,
      },
    );
  }

  Widget _status(ParticipationStore s) => Column(
    children: [
      if (s.loading || s.moreLoading) const LinearProgressIndicator(),
      if (s.issue != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(socialMessage(s.issue)),
        ),
      if (s.expired && !s.loading)
        TextButton(onPressed: _load, child: const Text('Atualizar espaço')),
    ],
  );
  Widget _post(Map<String, dynamic> p) => SocialPostCard(
    p,
    playback: _playback,
    busy: _rows.busy,
    onOpen: _open,
    onLike: () => _command(
      p['liked'] == true ? 'DELETE' : 'PUT',
      'v1/social/posts/${p['id']}/like',
    ),
    onReport: () => _report(p['id'] as String),
    onEdit: () => _open('/social/posts/${p['id']}/edit'),
    onDelete: () => _delete(p['id'] as String),
    onModerate: () => _moderate('POST', p['id'] as String, 'HIDE'),
  );
  Widget _person(Map<String, dynamic> p) => SocialAuthorTile(
    p,
    onOpen: _open,
    subtitle:
        '${p['handle'] != null ? '@${p['handle']} · ' : ''}${switch (p['role']) {
          'CREATOR' => 'Organizador',
          'MODERATOR' => 'Moderador',
          _ => 'Participante',
        }}',
    trailing:
        _caps['can_moderate'] == true &&
            p['role'] != 'CREATOR' &&
            p['user_id'] != _access.ownerId
        ? PopupMenuButton<String>(
            tooltip: 'Moderar participante',
            onSelected: (v) => _moderate(
              v == 'GRANT' || v == 'REVOKE' ? 'MODERATOR' : 'PARTICIPANT',
              p['user_id'] as String,
              v,
            ),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'RESTRICT',
                child: Text('Restringir interações'),
              ),
              const PopupMenuItem(
                value: 'ALLOW',
                child: Text('Permitir interações'),
              ),
              if (_caps['can_manage_participation'] == true)
                const PopupMenuItem(
                  value: 'REMOVE',
                  child: Text('Remover participação'),
                ),
              if (_caps['can_manage_roles'] == true)
                PopupMenuItem(
                  value: p['role'] == 'MODERATOR' ? 'REVOKE' : 'GRANT',
                  child: Text(
                    p['role'] == 'MODERATOR'
                        ? 'Remover moderação'
                        : 'Tornar moderador',
                  ),
                ),
            ],
          )
        : null,
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _pause();
    _playback.dispose();
    _rowSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(socialStoreProvider(_base));
    ref.watch(socialStoreProvider(_path));
    return ListenableBuilder(
      listenable: Listenable.merge([_summary, _rows]),
      builder: (context, _) {
        final space = _summary.document;
        final allowed = _caps['can_read'] == true;
        return PopScope(
          onPopInvokedWithResult: (p, r) {
            if (p) _pause();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Event Space'),
              actions: [
                IconButton(
                  tooltip: 'Atualizar espaço',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                ),
                if (_caps['can_manage_roles'] == true)
                  PopupMenuButton<String>(
                    tooltip: 'Ações do espaço',
                    onSelected: (v) {
                      if (v == 'participants') {
                        _open('/experiences/${widget.id}/participants');
                      } else {
                        _moderate('SPACE', widget.id, v);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'participants',
                        child: Text('Gerenciar participação'),
                      ),
                      PopupMenuItem(
                        value: space?['paused'] == true ? 'RESUME' : 'PAUSE',
                        child: Text(
                          space?['paused'] == true
                              ? 'Retomar interações'
                              : 'Pausar interações',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            floatingActionButton: allowed && _caps['can_write'] == true
                ? FloatingActionButton.extended(
                    heroTag: null,
                    onPressed: () =>
                        _open('/experiences/${widget.id}/space/new'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Publicar no espaço'),
                  )
                : null,
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 100),
                      children: [
                        _status(_summary),
                        if (space != null) ...[
                          Text(
                            space['title'] as String,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(switch (space['phase']) {
                            'ENDED' => 'Memórias · experiência encerrada',
                            'CANCELLED' =>
                              'Experiência cancelada · somente leitura',
                            'ARCHIVED' => 'Memórias arquivadas',
                            'LIVE' => 'Acontecendo agora',
                            'DRAFT' => 'Rascunho · espaço ainda indisponível',
                            _ => 'O encontro começa em breve',
                          }, style: Theme.of(context).textTheme.labelLarge),
                          if (space['starts_at'] != null)
                            Text(
                              DateTime.parse(space['starts_at'] as String)
                                  .toLocal()
                                  .toString()
                                  .substring(0, 16),
                            ),
                          if ((space['description'] as String).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(space['description'] as String),
                            ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: () =>
                                    _open('/experiences/${widget.id}'),
                                icon: const Icon(Icons.event_outlined),
                                label: const Text('Detalhes da experiência'),
                              ),
                              if (allowed)
                                Text(
                                  '${space['participant_count']} participantes confirmados',
                                ),
                            ],
                          ),
                          if (!allowed) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: FlowStateView(
                                kind: FlowViewState.empty,
                                message: 'O mural, a mídia e a lista de participantes são exclusivos das pessoas autorizadas.',
                              ),
                            ),
                            ParticipationPanel(widget.id, onChanged: _load),
                          ] else ...[
                            Text(
                              'Sua participação: ${space['my_state'] == 'CONFIRMED'
                                  ? 'confirmada'
                                  : space['role'] == 'CREATOR'
                                  ? 'organizador'
                                  : space['my_state']}',
                            ),
                            if (_caps['can_write'] != true)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                  'Espaço em modo de leitura. Você pode consultar as memórias e denunciar conteúdo.',
                                ),
                              ),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final tab in {
                                    'feed': 'Mural',
                                    'gallery': 'Mídia',
                                    'participants': 'Participantes',
                                    if (_caps['can_moderate'] == true)
                                      'reports': 'Denúncias',
                                    if (_caps['can_moderate'] == true)
                                      'hidden': 'Conteúdo oculto',
                                  }.entries)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: ChoiceChip(
                                        label: Text(tab.value),
                                        selected: _section == tab.key,
                                        onSelected: (_) => _select(tab.key),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            _status(_rows),
                            if (_rows.document != null && _rows.rows.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 32,
                                ),
                                child: FlowStateView(
                                  kind: FlowViewState.empty,
                                  message: switch (_section) {
                                    'feed' =>
                                      'Este espaço ainda não tem publicações.',
                                    'gallery' =>
                                      'Ainda não há mídias publicadas.',
                                    'participants' => 'Não há participantes disponíveis para exibir.',
                                    'reports' =>
                                      'Nenhuma denúncia neste espaço.',
                                    _ => 'Nenhum conteúdo ocultado localmente.',
                                  },
                                ),
                              ),
                            if (_section == 'gallery')
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _rows.rows.length,
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                      maxCrossAxisExtent: 330,
                                      childAspectRatio: .85,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                    ),
                                itemBuilder: (context, i) {
                                  final item = _rows.rows[i];
                                  final p =
                                      item['post'] as Map<String, dynamic>;
                                  final m =
                                      (p['media'] as List).single
                                          as Map<String, dynamic>;
                                  return Column(
                                    children: [
                                      Expanded(
                                        child: SocialMedia(
                                          p['id'] as String,
                                          m,
                                          playback: _playback,
                                          key: ValueKey(item['id']),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            _open('/social/posts/${p['id']}'),
                                        child: const Text(
                                          'Ver publicação original',
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              )
                            else
                              for (final p in _rows.rows)
                                if (_section == 'feed')
                                  _post(p)
                                else if (_section == 'participants')
                                  _person(p)
                                else if (_section == 'reports')
                                  ListTile(
                                    title: Text(
                                      p['target_type'] == 'COMMENT'
                                          ? 'Comentário denunciado'
                                          : 'Publicação denunciada',
                                    ),
                                    subtitle: Text(
                                      '${p['reason']} · ${p['reviewed'] == true ? 'Revisada localmente' : 'Aguardando revisão'}',
                                    ),
                                    trailing: PopupMenuButton<String>(
                                      tooltip: 'Revisar denúncia',
                                      onSelected: (v) {
                                        if (v == 'REVIEW') {
                                          _moderate(
                                            'REPORT',
                                            p['id'] as String,
                                            v,
                                          );
                                        } else {
                                          _moderate(
                                            p['target_type'] as String,
                                            p['target_id'] as String,
                                            v,
                                          );
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'REVIEW',
                                          child: Text('Marcar revisão local'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'HIDE',
                                          child: Text(
                                            'Ocultar conteúdo no espaço',
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  ListTile(
                                    title: Text(
                                      p['target_type'] == 'COMMENT'
                                          ? 'Comentário ocultado'
                                          : 'Publicação ocultada',
                                    ),
                                    trailing: TextButton(
                                      onPressed: () => _moderate(
                                        p['target_type'] as String,
                                        p['target_id'] as String,
                                        'RESTORE',
                                      ),
                                      child: const Text('Restaurar'),
                                    ),
                                  ),
                            if (_rows.cursor != null)
                              TextButton(
                                onPressed: _rows.moreLoading
                                    ? null
                                    : () => _rows.load(more: true),
                                child: const Text('Carregar mais'),
                              ),
                          ],
                        ] else if (!_summary.loading)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: FlowStateView(
                              kind: FlowViewState.error,
                              message: 'Espaço indisponível ou sem acesso. Confirme sua participação nos detalhes.',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
