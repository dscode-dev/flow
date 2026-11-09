import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../experiences/data/experiences_repository.dart';
import '../explore/flow_playback.dart';
import '../participation/participation_store.dart';
import 'social_repository.dart';
import 'social_media.dart';

class SocialPage extends ConsumerStatefulWidget {
  const SocialPage({this.userId, this.postId, this.section, super.key});
  final String? userId, postId, section;
  @override
  ConsumerState<SocialPage> createState() => _SocialPageState();
}

class _SocialPageState extends ConsumerState<SocialPage>
    with WidgetsBindingObserver {
  late ParticipationStore _store;
  ParticipationStore? _profile, _comments;
  late FlowPlayback _playback;
  late ExperienceAccess _access;
  final _comment = TextEditingController();
  String _mode = 'DISCOVER';

  String get _path => widget.postId != null
      ? 'v1/social/posts/${widget.postId}'
      : widget.section == 'blocks'
      ? 'v1/social/blocks'
      : widget.userId != null
      ? 'v1/social/profiles/${widget.userId}/${widget.section ?? 'posts'}'
      : 'v1/social/feed';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = ref.read(socialStoreProvider(_path));
    if (widget.userId != null && widget.section == null) {
      _profile = ref.read(
        socialStoreProvider('v1/social/profiles/${widget.userId}'),
      );
    }
    if (widget.postId != null) {
      _comments = ref.read(
        socialStoreProvider('v1/social/posts/${widget.postId}/comments'),
      );
    }
    _playback = FlowPlayback(ref.read(flowPlayerFactoryProvider));
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    if (widget.userId == null &&
        widget.postId == null &&
        widget.section == null) {
      _store.query = {'mode': _mode};
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  void _account() {
    _comment.clear();
    unawaited(_playback.close());
  }

  Future<void> _load() async {
    await Future.wait([
      _store.resume(),
      if (_profile != null) _profile!.resume(),
      if (_comments != null) _comments!.resume(),
    ]);
  }

  void _pause() {
    _store.pause();
    _profile?.pause();
    _comments?.pause();
    unawaited(_playback.close());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      if (ModalRoute.of(context)?.isCurrent ?? false) unawaited(_load());
    } else {
      _pause();
      _comment.clear();
    }
  }

  Future<void> _open(String path) async {
    _pause();
    await _playback.close();
    if (!mounted) return;
    await context.push(path);
    if (mounted) await _load();
  }

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _action(
    String method,
    String path, {
    Map<String, dynamic> body = const {},
    String? etag,
  }) async {
    await _playback.close();
    final ok = await _store.command(
      method,
      path,
      body: body,
      etag: etag,
      reload: false,
    );
    if (!mounted) return;
    if (ok) {
      await _load();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(socialMessage(_store.issue))));
    }
  }

  Future<void> _report(String type, String id) async {
    final reason = await showFlowSheet<String>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Denunciar', style: Theme.of(context).textTheme.titleLarge),
          for (final r in {
            'ABUSE': 'Abuso ou assédio',
            'SPAM': 'Spam',
            'PRIVACY': 'Privacidade',
            'ILLEGAL': 'Conteúdo ilegal',
            'OTHER': 'Outro motivo',
          }.entries)
            TextButton(
              onPressed: () => Navigator.pop(context, r.key),
              child: Text(r.value),
            ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    final ok = await _store.command(
      'POST',
      'v1/social/reports',
      body: {'target_type': type, 'target_id': id, 'reason': reason},
      reload: false,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Denúncia registrada para análise.'
                : socialMessage(_store.issue),
          ),
        ),
      );
    }
    if (ok) await _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _pause();
    _playback.dispose();
    _comment.dispose();
    super.dispose();
  }

  Widget _person(Map<String, dynamic> p, {Widget? trailing}) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      child: Text(
        (p['display_name'] as String? ?? '?').characters.firstOrNull ?? '?',
      ),
    ),
    title: Text(p['display_name'] as String? ?? 'Pessoa bloqueada'),
    subtitle: p['handle'] != null ? Text('@${p['handle']}') : null,
    trailing: trailing,
    onTap: () => _open('/social/profiles/${p['user_id']}'),
  );
  Widget _post(Map<String, dynamic> p) {
    final person = p['author'] as Map<String, dynamic>;
    final media = (p['media'] as List).cast<Map<String, dynamic>>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _person(
            person,
            trailing: PopupMenuButton<String>(
              tooltip: 'Ações da publicação',
              onSelected: (v) async {
                if (v == 'report') {
                  await _report('POST', p['id'] as String);
                } else if (v == 'edit') {
                  await _open('/social/posts/${p['id']}/edit');
                } else if (await _confirm('Excluir publicação?')) {
                  final ok = await _store.command(
                    'DELETE',
                    'v1/social/posts/${p['id']}',
                    reload: false,
                  );
                  if (mounted && ok) {
                    if (widget.postId != null) {
                      context.pop();
                    } else {
                      await _load();
                    }
                  }
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'report',
                  child: Text('Denunciar publicação'),
                ),
                if (p['can_manage'] == true) ...[
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Editar texto'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Excluir publicação'),
                  ),
                ],
              ],
            ),
          ),
          Text(
            '${DateTime.tryParse(p['created_at'] as String)?.toLocal().toString().substring(0, 16) ?? ''} · ${p['visibility'] == 'PUBLIC' ? 'Público' : 'Seguidores'}${p['edited_at'] != null ? ' · editado' : ''}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if ((p['body'] as String).isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                p['body'] as String,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          for (final m in media)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SocialMedia(
                p['id'] as String,
                m,
                playback: _playback,
                key: ValueKey('${p['id']}:${m['id']}'),
              ),
            ),
          if (p['experience_id'] != null)
            TextButton.icon(
              onPressed: () => _open('/experiences/${p['experience_id']}'),
              icon: const Icon(Icons.event_outlined),
              label: Text(p['experience_title'] as String),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _store.busy
                    ? null
                    : () => _action(
                        p['liked'] == true ? 'DELETE' : 'PUT',
                        'v1/social/posts/${p['id']}/like',
                      ),
                icon: Icon(
                  p['liked'] == true ? Icons.favorite : Icons.favorite_border,
                ),
                label: Text('${p['like_count']} curtidas'),
              ),
              TextButton.icon(
                onPressed: widget.postId != null
                    ? null
                    : () => _open('/social/posts/${p['id']}'),
                icon: const Icon(Icons.chat_bubble_outline),
                label: Text('${p['comment_count']} comentários'),
              ),
            ],
          ),
          const Divider(),
        ],
      ),
    );
  }

  Widget _profileHeader() {
    final p = _profile?.document;
    if (p == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _person(p),
        Wrap(
          spacing: 8,
          children: [
            Text('${p['post_count']} publicações'),
            TextButton(
              onPressed: () =>
                  _open('/social/profiles/${widget.userId}/followers'),
              child: Text('${p['follower_count']} seguidores'),
            ),
            TextButton(
              onPressed: () =>
                  _open('/social/profiles/${widget.userId}/following'),
              child: Text('${p['following_count']} seguindo'),
            ),
          ],
        ),
        if (p['follows_you'] == true) const Text('Segue você'),
        if (p['is_self'] != true)
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _store.busy
                    ? null
                    : () => _action(
                        p['following'] == true ? 'DELETE' : 'PUT',
                        'v1/social/profiles/${widget.userId}/follow',
                      ),
                child: Text(
                  p['following'] == true ? 'Deixar de seguir' : 'Seguir',
                ),
              ),
              TextButton(
                onPressed: () async {
                  if (!await _confirm('Bloquear esta pessoa?')) return;
                  final ok = await _store.command(
                    'PUT',
                    'v1/social/profiles/${widget.userId}/block',
                    reload: false,
                  );
                  if (mounted && ok) {
                    _pause();
                    context.go('/social');
                  }
                },
                child: const Text('Bloquear'),
              ),
              TextButton(
                onPressed: () => _report('USER', widget.userId!),
                child: const Text('Denunciar pessoa'),
              ),
            ],
          ),
        const Divider(),
      ],
    );
  }

  Widget _status(ParticipationStore s) => Column(
    children: [
      if (s.loading || s.moreLoading) const LinearProgressIndicator(),
      if (s.issue != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            socialMessage(s.issue),
            semanticsLabel: socialMessage(s.issue),
          ),
        ),
      if (s.expired && !s.loading)
        TextButton(onPressed: _load, child: const Text('Atualizar conteúdo')),
      if (s.document != null &&
          s.rows.isEmpty &&
          s != _profile &&
          widget.postId == null)
        const Padding(
          padding: EdgeInsets.all(24),
          child: FlowStateView(
            kind: FlowViewState.empty,
            message: 'Ainda não há conteúdo por aqui.',
          ),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    ref.watch(socialStoreProvider(_path));
    if (_profile != null) {
      ref.watch(socialStoreProvider('v1/social/profiles/${widget.userId}'));
    }
    if (_comments != null) {
      ref.watch(
        socialStoreProvider('v1/social/posts/${widget.postId}/comments'),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([_store, ?_profile, ?_comments]),
      builder: (context, _) => PopScope(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) _pause();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              widget.postId != null
                  ? 'Publicação'
                  : widget.section == 'blocks'
                  ? 'Pessoas bloqueadas'
                  : widget.section == 'followers'
                  ? 'Seguidores'
                  : widget.section == 'following'
                  ? 'Seguindo'
                  : widget.userId != null
                  ? 'Perfil'
                  : 'Social',
            ),
            actions: [
              IconButton(
                tooltip: 'Atualizar Social',
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
              if (widget.userId == null &&
                  widget.postId == null &&
                  widget.section == null)
                PopupMenuButton<String>(
                  tooltip: 'Meu Social',
                  onSelected: _open,
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value:
                          '/social/profiles/${ref.read(experienceAccessProvider).ownerId}',
                      child: const Text('Meu perfil'),
                    ),
                    const PopupMenuItem(
                      value: '/social/blocks',
                      child: Text('Pessoas bloqueadas'),
                    ),
                  ],
                ),
            ],
          ),
          floatingActionButton: widget.postId == null && widget.section == null
              ? FloatingActionButton.extended(
                  onPressed: () => _open('/social/new'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Publicar'),
                )
              : null,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                    children: [
                      if (widget.userId == null &&
                          widget.postId == null &&
                          widget.section == null)
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'FOLLOWING',
                              label: Text('Seguindo'),
                            ),
                            ButtonSegment(
                              value: 'DISCOVER',
                              label: Text('Descobrir'),
                            ),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (v) {
                            _mode = v.first;
                            unawaited(_playback.close());
                            _store.select({'mode': _mode});
                          },
                        ),
                      if (_profile != null) ...[
                        _status(_profile!),
                        _profileHeader(),
                      ],
                      _status(_store),
                      if (widget.postId != null && _store.document != null)
                        _post(_store.document!),
                      if (widget.postId == null)
                        for (final p in _store.rows)
                          if (widget.section == 'blocks')
                            ListTile(
                              title: const Text('Pessoa bloqueada'),
                              subtitle: Text(p['user_id'] as String),
                              trailing: TextButton(
                                onPressed: () => _action(
                                  'DELETE',
                                  'v1/social/profiles/${p['user_id']}/block',
                                ),
                                child: const Text('Desbloquear'),
                              ),
                            )
                          else if (widget.section != null)
                            _person(p)
                          else
                            _post(p),
                      if (_store.cursor != null)
                        TextButton(
                          onPressed: _store.moreLoading
                              ? null
                              : () => _store.load(more: true),
                          child: const Text('Carregar mais'),
                        ),
                      if (_comments != null && _store.document != null) ...[
                        Text(
                          'Comentários',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        TextField(
                          controller: _comment,
                          maxLength: 1000,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Escreva um comentário',
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: _comments!.busy
                                ? null
                                : () async {
                                    final ok = await _comments!.command(
                                      'POST',
                                      'v1/social/posts/${widget.postId}/comments',
                                      body: {'body': _comment.text},
                                    );
                                    if (ok) {
                                      _comment.clear();
                                      await _store.load();
                                    }
                                  },
                            child: const Text('Comentar'),
                          ),
                        ),
                        _status(_comments!),
                        for (final c in _comments!.rows)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _person(
                                c['author'] as Map<String, dynamic>,
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'Ações do comentário',
                                  onSelected: (v) async {
                                    if (v == 'report') {
                                      await _report(
                                        'COMMENT',
                                        c['id'] as String,
                                      );
                                    } else if (await _confirm(
                                      'Excluir comentário?',
                                    )) {
                                      await _comments!.command(
                                        'DELETE',
                                        'v1/social/posts/${widget.postId}/comments/${c['id']}',
                                      );
                                      await _store.load();
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'report',
                                      child: Text('Denunciar comentário'),
                                    ),
                                    if (c['can_delete'] == true)
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Excluir comentário'),
                                      ),
                                  ],
                                ),
                              ),
                              Text(c['body'] as String),
                              const Divider(),
                            ],
                          ),
                        if (_comments!.cursor != null)
                          TextButton(
                            onPressed: () => _comments!.load(more: true),
                            child: const Text('Mais comentários'),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
