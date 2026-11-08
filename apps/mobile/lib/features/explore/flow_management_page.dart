import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/components.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/data/cover_upload.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_issue.dart';
import '../experiences/presentation/widgets/experience_widgets.dart';
import 'discovery_model.dart';
import 'discovery_repository.dart';
import 'flow_upload.dart';

class FlowManagementPage extends ConsumerStatefulWidget {
  const FlowManagementPage(this.id, {super.key});
  final String id;
  @override
  ConsumerState<FlowManagementPage> createState() => _FlowManagementPageState();
}

class _FlowManagementPageState extends ConsumerState<FlowManagementPage>
    with WidgetsBindingObserver {
  FlowPresentation? _current;
  Experience? _experience;
  bool _enabled = false, _consent = false, _busy = false, _dirty = false;
  String? _image, _video, _message;
  FlowAsset? _imageState, _videoState;
  CancelToken? _cancel;
  Timer? _timer;
  int _generation = 0, _polls = 0;
  bool _polling = false, _foreground = true;
  FlowUpload? _intent;
  late ExperienceAccess _access;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    _load();
  }

  void _account() {
    _generation++;
    _cancel?.cancel();
    _timer?.cancel();
    _intent = null;
    _current = null;
    _experience = null;
    _image = null;
    _video = null;
    _imageState = null;
    _videoState = null;
    _enabled = false;
    _consent = false;
    _dirty = false;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _load() async {
    final g = ++_generation;
    _cancel?.cancel();
    final c = _cancel = CancelToken();
    setState(() => _busy = true);
    try {
      final repo = ref.read(discoveryRepositoryProvider);
      final e = await ref
          .read(experiencesRepositoryProvider)
          .get(widget.id, cancel: c);
      final p = await repo.presentation(widget.id, cancel: c);
      if (!mounted || g != _generation) return;
      setState(() {
        _experience = e;
        _current = p;
        _enabled = e.input.visibility == ExperienceVisibility.private
            ? false
            : p.enabled;
        _consent = p.consentAt != null;
        _image = p.imageId;
        _video = p.videoId;
        _dirty = false;
        _message = null;
      });
      await _states();
    } catch (_) {
      if (mounted && g == _generation) {
        setState(() => _message = 'Não foi possível carregar a apresentação.');
      }
    } finally {
      if (mounted && g == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _states() async {
    if (_polling || !_foreground || _access.ownerId == null) return;
    _polling = true;
    final g = _generation;
    try {
      final repo = ref.read(discoveryRepositoryProvider);
      final image = _image == null
          ? null
          : await repo.asset(widget.id, _image!, cancel: _cancel);
      final video = _video == null
          ? null
          : await repo.asset(widget.id, _video!, cancel: _cancel);
      if (mounted && g == _generation) {
        setState(() {
          _imageState = image;
          _videoState = video;
        });
        if ((image?.processing == true || video?.processing == true) &&
            _polls++ < 60) {
          _timer?.cancel();
          _timer = Timer(const Duration(seconds: 2), _states);
        }
      }
    } catch (_) {
      if (mounted && g == _generation) {
        setState(
          () => _message =
              'Não foi possível consultar o processamento. Tente atualizar.',
        );
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _choose(bool video) async {
    if (_busy) return;
    final g = _generation;
    final c = _cancel = CancelToken();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final picker = ImagePicker();
      final file = video
          ? await picker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(seconds: 15),
            )
          : await picker.pickImage(
              source: ImageSource.gallery,
              maxWidth: 1920,
              maxHeight: 1920,
              imageQuality: 90,
            );
      if (file == null || !mounted || g != _generation) return;
      if (await file.length() > (video ? 32 : 5) * 1024 * 1024) {
        throw const ExperienceIssue('media_invalid');
      }
      final selection = video ? null : await CoverSelection.read(file);
      final bytes = selection?.bytes ?? await file.readAsBytes();
      if (!mounted || g != _generation) return;
      final ct = video
          ? (file.name.toLowerCase().endsWith('.mov')
                ? 'video/quicktime'
                : 'video/mp4')
          : selection!.contentType;
      _intent = FlowUpload(
        ref.read(discoveryRepositoryProvider),
        widget.id,
        bytes,
        ct,
      );
      await _send(c, g, video);
    } catch (_) {
      if (mounted && g == _generation) {
        setState(
          () => _message = 'Não foi possível enviar. Use JPEG/PNG até 5 MiB ou vídeo MP4/MOV até 15s e 32 MiB. O servidor verifica formato e resolução.',
        );
      }
    } finally {
      if (mounted && g == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _send(CancelToken c, int g, bool video) async {
    final asset = await _intent!.run(c);
    if (!mounted || g != _generation) return;
    setState(() {
      if (video) {
        _video = asset.id;
        _videoState = asset;
      } else {
        _image = asset.id;
        _imageState = asset;
      }
      _dirty = true;
      _message = 'Envio recebido. Salve a apresentação para vincular a mídia. Processamento continua no servidor.';
      _intent = null;
      _polls = 0;
    });
    await _states();
  }

  Future<void> _save() async {
    final p = _current;
    if (p == null || _busy) return;
    final g = _generation;
    setState(() => _busy = true);
    final c = _cancel = CancelToken();
    try {
      final value = await ref
          .read(discoveryRepositoryProvider)
          .save(
            widget.id,
            p,
            enabled: _enabled,
            consent: _consent,
            image: _image,
            video: _video,
            cancel: c,
          );
      if (mounted && g == _generation) {
        setState(() {
          _current = value;
          _dirty = false;
          _message = 'Apresentação salva. A exibição depende da agenda, visibilidade, moderação e mídia pronta.';
        });
      }
    } catch (e) {
      if (mounted && g == _generation) {
        setState(
          () => _message = e is AuthIssue && e.code == 'version_conflict'
              ? 'Outra alteração foi salva. Seus campos foram mantidos; reabra a configuração antes de confirmar.'
              : 'Não foi possível salvar. Confira o consentimento, processamento, visibilidade e acesso.',
        );
      }
    } finally {
      if (mounted && g == _generation) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _polls = 0;
      _states();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _timer?.cancel();
      _generation++;
      _cancel?.cancel();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _generation++;
    _timer?.cancel();
    _cancel?.cancel();
    _intent = null;
    super.dispose();
  }

  Widget _asset(
    String label,
    FlowAsset? state,
    String? id,
    VoidCallback remove,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(
      id == null
          ? 'Usar a capa da experiência como imagem'
          : switch (state?.status) {
              'READY' => 'Pronta',
              'PROCESSING' => 'Processando no servidor…',
              'FAILED' => 'Falha: escolha outro arquivo dentro dos limites.',
              'DELETED' => 'Mídia removida',
              _ => 'Aguardando verificação',
            },
    ),
    trailing: id == null
        ? null
        : IconButton(
            tooltip: 'Remover $label',
            onPressed: _busy ? null : remove,
            icon: const Icon(Icons.close),
          ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop) return;
      final discard = await confirmExperienceAction(
        context,
        title: 'Descartar alterações?',
        message: 'As alterações da apresentação ainda não foram salvas.',
        action: 'Descartar',
      );
      if (discard && context.mounted) {
        setState(() => _dirty = false);
        Navigator.of(context).pop();
      }
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Apresentação nos Flows')),
      body: SafeArea(
        child: _current == null
            ? FlowStateView(
                kind: _busy ? FlowViewState.loading : FlowViewState.error,
                message: _message ?? 'Carregando apresentação…',
                onRetry: _busy ? null : _load,
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    _experience?.displayTitle ?? '',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Flows apresentam experiências publicadas acontecendo agora ou próximas. Não são publicações pessoais.',
                  ),
                  const SizedBox(height: 16),
                  if (_experience?.input.visibility ==
                      ExperienceVisibility.private)
                    const Text(
                      'Experiências privadas nunca aparecem nos Flows públicos.',
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Exibir nos Flows'),
                    value: _enabled,
                    onChanged:
                        _busy ||
                            _experience?.input.visibility ==
                                ExperienceVisibility.private
                        ? null
                        : (v) => setState(() {
                            _enabled = v;
                            if (!v) _consent = false;
                            _dirty = true;
                          }),
                  ),
                  if (_experience?.input.visibility ==
                      ExperienceVisibility.unlisted)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Permitir descoberta pública desta experiência não listada',
                      ),
                      subtitle: const Text(
                        'Ao ativar, título, agenda, local e mídia poderão aparecer publicamente nos Flows, mesmo sem compartilhar o link. Desativar revoga essa exposição.',
                      ),
                      value: _consent,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _consent = v ?? false;
                              _dirty = true;
                            }),
                    ),
                  const Divider(height: 32),
                  const Text(
                    'Imagem JPEG/PNG até 5 MiB; vídeo MP4/MOV de até 15s e 32 MiB. Limite padrão de entrada: 1920 pixels por lado, ajustável pelo servidor. Sem vídeo, usamos imagem própria ou capa autorizada. Vídeo pronto gera um poster.',
                  ),
                  _asset(
                    'Imagem de apresentação',
                    _imageState,
                    _image,
                    () => setState(() {
                      _image = null;
                      _imageState = null;
                      _dirty = true;
                    }),
                  ),
                  _asset(
                    'Vídeo opcional',
                    _videoState,
                    _video,
                    () => setState(() {
                      _video = null;
                      _videoState = null;
                      _dirty = true;
                    }),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _choose(false),
                        icon: const Icon(Icons.photo_outlined),
                        label: const Text('Escolher imagem'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _choose(true),
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('Escolher vídeo'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                _polls = 0;
                                _states();
                              },
                        child: const Text('Atualizar processamento'),
                      ),
                    ],
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: LinearProgressIndicator(
                        semanticsLabel: 'Enviando ou salvando apresentação',
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_message!),
                    ),
                  if (_intent != null)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final g = _generation;
                              setState(() => _busy = true);
                              try {
                                await _send(
                                  _cancel = CancelToken(),
                                  g,
                                  _intent!.contentType.startsWith('video/'),
                                );
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => _message =
                                        'Não foi possível retomar o envio.',
                                  );
                                }
                              } finally {
                                if (mounted && g == _generation) {
                                  setState(() => _busy = false);
                                }
                              }
                            },
                      child: const Text('Retomar envio'),
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed:
                        _busy ||
                            (_enabled &&
                                _experience?.input.visibility ==
                                    ExperienceVisibility.unlisted &&
                                !_consent)
                        ? null
                        : _save,
                    child: const Text('Salvar apresentação'),
                  ),
                ],
              ),
      ),
    ),
  );
}
