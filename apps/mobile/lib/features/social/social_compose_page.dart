import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/data/cover_upload.dart';
import '../experiences/domain/experience_issue.dart';
import '../explore/discovery_model.dart';
import '../explore/flow_upload.dart';
import '../participation/participation_store.dart';
import 'social_repository.dart';
import 'social_media.dart';
import '../explore/flow_playback.dart';

class SocialComposePage extends ConsumerStatefulWidget {
  const SocialComposePage({this.id, super.key});
  final String? id;
  @override
  ConsumerState<SocialComposePage> createState() => _SocialComposePageState();
}

class _PendingMedia {
  _PendingMedia(this.upload);
  final FlowUpload upload;
  FlowAsset? state;
  bool uploading = false;
  String? issue;
}

class _SocialComposePageState extends ConsumerState<SocialComposePage>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  late ExperienceAccess _access;
  late ParticipationStore _options;
  late FlowPlayback _playback;
  final _media = <_PendingMedia>[];
  CancelToken? _cancel;
  int _revision = 0;
  bool _busy = false, _foreground = true, _dirty = false;
  String _visibility = 'PUBLIC',
      _context = 'PERSONAL',
      _key = const Uuid().v4();
  String? _experience, _message, _expected, _pendingHash;
  Map<String, dynamic>? _current;
  int _bodyLimit = 3000, _mediaLimit = 4;
  bool _configured = false;
  @override
  void initState() {
    super.initState();
    _playback = FlowPlayback(ref.read(flowPlayerFactoryProvider));
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    _options = ref.read(socialStoreProvider('v1/social/experience-options'));
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _account() {
    _revision++;
    unawaited(_playback.close());
    _cancel?.cancel();
    _text.clear();
    _clearMedia();
    _options.pause();
    _experience = null;
    _current = null;
    _expected = null;
    _pendingHash = null;
    _key = const Uuid().v4();
    _dirty = false;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _load() async {
    final g = _revision;
    final c = _cancel = CancelToken();
    try {
      final repo = ref.read(socialRepositoryProvider);
      final limits = await repo.request('GET', 'v1/social/limits', cancel: c);
      if (!mounted || g != _revision) return;
      setState(() {
        _bodyLimit = limits['body_limit'] as int;
        _mediaLimit = limits['media_limit'] as int;
        _configured = true;
      });
      if (widget.id != null) {
        final p = await repo.request(
          'GET',
          'v1/social/posts/${widget.id}',
          cancel: c,
        );
        if (!mounted || g != _revision) return;
        if (p['can_manage'] != true) throw const ExperienceIssue('not_found');
        setState(() {
          if (_current == null && !_dirty) _text.text = p['body'] as String;
          _current = p;
          _expected = '"${p['version']}"';
        });
      }
    } catch (e) {
      if (mounted && g == _revision) {
        setState(() => _message = socialMessage(e));
      }
    }
  }

  Future<void> _chooseExperience() async {
    await _options.resume();
    if (mounted) setState(() {});
  }

  Future<void> _pick(bool video) async {
    if (_media.length >= _mediaLimit) return;
    final g = _revision;
    try {
      final picker = ImagePicker();
      final file = video
          ? await picker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(seconds: 15),
            )
          : await picker.pickImage(
              source: ImageSource.gallery,
              requestFullMetadata: false,
            );
      if (file == null || !mounted || g != _revision) return;
      if (await file.length() > (video ? 32 : 5) * 1024 * 1024) {
        throw const ExperienceIssue('media_invalid');
      }
      final selection = video ? null : await CoverSelection.read(file);
      final bytes = selection?.bytes ?? await file.readAsBytes();
      final ct =
          selection?.contentType ??
          (file.name.toLowerCase().endsWith('.mov')
              ? 'video/quicktime'
              : 'video/mp4');
      if (!mounted || g != _revision) return;
      final pending = _PendingMedia(
        FlowUpload(ref.read(socialRepositoryProvider), '', bytes, ct),
      );
      setState(() {
        _media.add(pending);
        _dirty = true;
      });
      await _upload(pending);
    } catch (e) {
      if (mounted && g == _revision) {
        setState(() => _message = socialMessage(e));
      }
    }
  }

  Future<void> _upload(_PendingMedia media) async {
    if (media.uploading || !_foreground) return;
    final g = _revision;
    final c = _cancel ??= CancelToken();
    setState(() {
      media.uploading = true;
      media.issue = null;
    });
    try {
      var asset = await media.upload.run(c);
      for (var i = 0; asset.processing && i < 30; i++) {
        if (!mounted || g != _revision || !_foreground) return;
        setState(() => media.state = asset);
        await Future<void>.delayed(const Duration(seconds: 2));
        if (c.isCancelled || !mounted || g != _revision) return;
        asset = await ref.read(socialRepositoryProvider).asset(asset.id, c);
      }
      if (mounted && g == _revision) setState(() => media.state = asset);
    } catch (e) {
      if (mounted && g == _revision) {
        setState(() => media.issue = socialMessage(e));
      }
    } finally {
      if (mounted && g == _revision) setState(() => media.uploading = false);
    }
  }

  Future<void> _publish() async {
    if (_busy || !_configured || widget.id != null && _current == null) return;
    final g = _revision;
    final c = _cancel ??= CancelToken();
    final body = widget.id != null
        ? {'body': _text.text}
        : {
            'context': _context,
            'visibility': _visibility,
            'experience_id': _context == 'EXPERIENCE_PUBLIC'
                ? _experience
                : null,
            'body': _text.text,
            'media_ids': _media.map((m) => m.state!.id).toList(),
          };
    final fingerprint = jsonEncode(body);
    if (_pendingHash != null && _pendingHash != fingerprint) {
      setState(
        () => _message = 'A tentativa anterior ficou sem confirmação. Restaure os campos anteriores e tente novamente para reconciliar.',
      );
      return;
    }
    _pendingHash = fingerprint;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(socialRepositoryProvider)
          .request(
            widget.id != null ? 'PATCH' : 'POST',
            widget.id != null
                ? 'v1/social/posts/${widget.id}'
                : 'v1/social/posts',
            body: body,
            headers: {'Idempotency-Key': _key, 'If-Match': ?_expected},
            cancel: c,
          );
      if (!mounted || g != _revision) return;
      setState(() => _dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop(result['id']);
      });
    } catch (e) {
      if (mounted && g == _revision) {
        if (e is AuthIssue &&
            !{
              'network',
              'canceled',
              'temporarily_unavailable',
            }.contains(e.code)) {
          _pendingHash = null;
          _key = const Uuid().v4();
        }
        setState(() => _message = socialMessage(e));
      }
    } finally {
      if (mounted && g == _revision) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _foreground = true;
      _cancel = CancelToken();
    } else {
      _foreground = false;
      unawaited(_playback.close());
      _revision++;
      _cancel?.cancel();
      _cancel = null;
      _options.pause();
      for (final m in _media) {
        m.uploading = false;
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (!_dirty) {
      context.pop();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar rascunho?'),
        content: const Text(
          'O texto e as mídias selecionadas serão descartados deste aparelho.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Continuar escrevendo'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      setState(() => _dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pop();
      });
    }
  }

  void _clearMedia() {
    for (final m in _media) {
      if (m.upload.contentType.startsWith('image/')) {
        unawaited(MemoryImage(m.upload.bytes).evict());
      }
    }
    _media.clear();
  }

  void _removeMedia(_PendingMedia m) {
    if (m.upload.contentType.startsWith('image/')) {
      unawaited(MemoryImage(m.upload.bytes).evict());
    }
    setState(() => _media.remove(m));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _revision++;
    _cancel?.cancel();
    _options.pause();
    _clearMedia();
    _playback.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(socialStoreProvider('v1/social/experience-options'));
    final ready = _media.every(
      (m) => m.state?.status == 'READY' && !m.uploading,
    );
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_leave());
        } else {
          unawaited(_playback.close());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _leave),
          title: Text(
            widget.id == null ? 'Nova publicação' : 'Editar publicação',
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (!_configured)
                    TextButton(
                      onPressed: _load,
                      child: const Text('Carregar configuração'),
                    ),
                  TextField(
                    controller: _text,
                    minLines: 5,
                    maxLines: 12,
                    maxLength: _bodyLimit,
                    onChanged: (_) => setState(() => _dirty = true),
                    decoration: const InputDecoration(
                      labelText: 'O que você viveu?',
                      hintText: 'Compartilhe um momento ou uma ideia…',
                    ),
                  ),
                  if (widget.id == null) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _visibility,
                      decoration: const InputDecoration(
                        labelText: 'Quem pode ver',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'PUBLIC',
                          child: Text('Público'),
                        ),
                        DropdownMenuItem(
                          value: 'FOLLOWERS',
                          child: Text('Seguidores'),
                        ),
                      ],
                      onChanged: (v) => setState(() {
                        _visibility = v!;
                        _dirty = true;
                      }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: _context,
                      decoration: const InputDecoration(labelText: 'Contexto'),
                      items: const [
                        DropdownMenuItem(
                          value: 'PERSONAL',
                          child: Text('Pessoal'),
                        ),
                        DropdownMenuItem(
                          value: 'EXPERIENCE_PUBLIC',
                          child: Text('Experiência pública'),
                        ),
                      ],
                      onChanged: (v) {
                        setState(() {
                          _context = v!;
                          _dirty = true;
                        });
                        if (v == 'EXPERIENCE_PUBLIC') _chooseExperience();
                      },
                    ),
                    if (_context == 'EXPERIENCE_PUBLIC')
                      ListenableBuilder(
                        listenable: _options,
                        builder: (context, _) => Column(
                          children: [
                            if (_options.loading)
                              const LinearProgressIndicator(),
                            for (final e in _options.rows)
                              CheckboxListTile(
                                title: Text(e['title'] as String),
                                value: _experience == e['id'],
                                onChanged: (v) => setState(
                                  () => _experience = v == true
                                      ? e['id'] as String
                                      : null,
                                ),
                              ),
                            if (_options.rows.isEmpty && !_options.loading)
                              const Text(
                                'Nenhuma experiência pública elegível. Você precisa organizar ou ter participação confirmada.',
                              ),
                            if (_options.issue != null)
                              Text(socialMessage(_options.issue)),
                            TextButton(
                              onPressed: () =>
                                  _options.load(more: _options.cursor != null),
                              child: Text(
                                _options.cursor != null
                                    ? 'Mais experiências'
                                    : 'Atualizar experiências',
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _media.length >= _mediaLimit
                              ? null
                              : () => _pick(false),
                          icon: const Icon(Icons.image_outlined),
                          label: const Text('Imagem'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _media.length >= _mediaLimit
                              ? null
                              : () => _pick(true),
                          icon: const Icon(Icons.videocam_outlined),
                          label: const Text('Vídeo · até 15s'),
                        ),
                      ],
                    ),
                    for (final m in _media)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (m.upload.contentType.startsWith('image/'))
                              SizedBox(
                                height: 160,
                                child: Image.memory(
                                  m.upload.bytes,
                                  semanticLabel: 'Prévia da imagem selecionada',
                                ),
                              ),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                m.upload.contentType.startsWith('image/')
                                    ? Icons.image
                                    : Icons.movie_outlined,
                              ),
                              title: Text(switch (m.state?.status) {
                                'READY' => 'Mídia pronta',
                                'PROCESSING' => 'Processando no servidor',
                                'FAILED' => 'Mídia recusada',
                                _ =>
                                  m.uploading
                                      ? 'Enviando mídia…'
                                      : 'Envio pendente',
                              }),
                              subtitle: Text(
                                m.issue ??
                                    '${(m.upload.bytes.length / 1024 / 1024).toStringAsFixed(1)} MB',
                              ),
                              trailing: IconButton(
                                tooltip: 'Remover mídia',
                                onPressed: m.uploading
                                    ? null
                                    : () => _removeMedia(m),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                            if (m.state?.status == 'READY' &&
                                m.upload.contentType.startsWith('video/'))
                              SocialMedia(
                                null,
                                {
                                  'id': m.state!.id,
                                  'content_type': m.state!.contentType,
                                },
                                playback: _playback,
                                key: ValueKey(m.state!.id),
                              ),
                            if (m.uploading) const LinearProgressIndicator(),
                            if (!m.uploading && m.state?.status != 'READY')
                              TextButton(
                                onPressed: () => _upload(m),
                                child: const Text(
                                  'Retomar envio ou verificar processamento',
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                  if (widget.id != null && _message != null)
                    TextButton(
                      onPressed: _load,
                      child: const Text(
                        'Revalidar versão sem apagar meu texto',
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(_message!, semanticsLabel: _message),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed:
                        _busy ||
                            !ready ||
                            !_configured ||
                            widget.id != null && _current == null ||
                            _context == 'EXPERIENCE_PUBLIC' &&
                                _experience == null
                        ? null
                        : _publish,
                    child: Text(
                      _busy
                          ? 'Confirmando…'
                          : widget.id == null
                          ? 'Publicar'
                          : 'Salvar texto',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Publicações públicas podem circular entre pessoas da plataforma. Só publique conteúdo que você tem autorização para compartilhar. O rascunho permanece nesta tela até sair ou trocar de conta.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
