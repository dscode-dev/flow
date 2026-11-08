import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_time.dart';
import '../experiences/presentation/widgets/experience_widgets.dart';
import 'discovery_controller.dart';
import 'discovery_model.dart';
import 'discovery_repository.dart';
import 'flow_image.dart';
import 'flow_playback.dart';

class FlowsViewerPage extends ConsumerStatefulWidget {
  const FlowsViewerPage({super.key, this.initialId});
  final String? initialId;
  @override
  ConsumerState<FlowsViewerPage> createState() => _FlowsViewerPageState();
}

class _FlowsViewerPageState extends ConsumerState<FlowsViewerPage>
    with WidgetsBindingObserver {
  late DiscoveryPager<FlowItem> _pager;
  late FlowPlayback _playback;
  late ExperienceAccess _access;
  PageController? _pages;
  int _index = 0, _generation = 0;
  bool _foreground = true, _details = false, _reduceMotion = false;
  String? _activeId;
  CancelToken? _cancel;
  CancelToken? _catalogCancel;
  Map<String, String> _categoryNames = {};
  Timer? _expiry;
  String? _message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pager = ref.read(flowsPagerProvider);
    _playback = FlowPlayback(ref.read(flowPlayerFactoryProvider));
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    _pager.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _catalog();
        _reduceMotion =
            MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.accessibleNavigationOf(context);
        if (_pager.items.isEmpty) {
          _pager.load();
        } else {
          _changed();
        }
      }
    });
  }

  void _account() {
    _catalogCancel?.cancel();
    _categoryNames = {};
    _index = 0;
    _stop();
    _activeId = null;
    if (mounted) setState(() {});
    if (_access.ownerId != null) _catalog();
  }

  Future<void> _catalog() async {
    final generation = _access.generation;
    final cancel = _catalogCancel = CancelToken();
    try {
      final categories = await ref
          .read(experiencesRepositoryProvider)
          .categories(cancel: cancel);
      if (mounted && generation == _access.generation) {
        setState(
          () => _categoryNames = {for (final c in categories) c.id: c.name},
        );
      }
    } catch (_) {
      /* Agenda and detail remain available; never show an internal category ID. */
    }
  }

  void _stop() {
    _generation++;
    _cancel?.cancel();
    _expiry?.cancel();
    _playback.close();
  }

  void _changed() {
    if (!mounted) return;
    if (_pager.items.isEmpty) {
      _stop();
      _activeId = null;
      _index = 0;
      final old = _pages;
      _pages = null;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    } else {
      if (_pages == null) {
        final initial = _pager.items.indexWhere(
          (f) => f.experience.id == widget.initialId,
        );
        _index = initial < 0 ? 0 : initial;
        _pages = PageController(initialPage: _index);
      }
      if (_index >= _pager.items.length) {
        _stop();
        _activeId = null;
        setState(() {});
        return;
      }
      final id = _pager.items[_index].experience.id;
      if (id != _activeId) {
        _activeId = id;
        _activate();
      }
    }
    setState(() {});
  }

  Future<void> _activate({bool playExplicitly = false}) async {
    _stop();
    if (!_foreground ||
        _details ||
        _pager.items.isEmpty ||
        _index >= _pager.items.length ||
        _access.ownerId == null) {
      return;
    }
    final g = _generation;
    final id = _pager.items[_index].experience.id;
    final c = _cancel = CancelToken();
    _message = null;
    try {
      final repo = ref.read(discoveryRepositoryProvider);
      final item = await repo.flow(id, cancel: c);
      if (!mounted || g != _generation) return;
      // URL lifetime30s from the server. Revoke the current player at that bound;
      // renewing is explicit, while each range also checks current authorization.
      _expiry = Timer(const Duration(seconds: 29), () {
        if (mounted && g == _generation) {
          _stop();
          setState(() => _message = 'Atualize este Flow para continuar.');
        }
      });
      if (item.hasVideo && item.videoUrl != null) {
        await _playback.open(
          repo.mediaUri(item.videoUrl!),
          autoplay: playExplicitly || !_reduceMotion,
        );
      }
    } catch (_) {
      if (mounted && g == _generation) {
        _stop();
        setState(
          () => _message = 'Este Flow está indisponível. Atualize a lista.',
        );
      }
    }
  }

  Future<void> _detail(String id) async {
    _details = true;
    _stop();
    try {
      await context.push('/experiences/$id');
    } finally {
      _details = false;
      if (mounted) _activate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _activate();
    } else {
      _foreground = false;
      _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _catalogCancel?.cancel();
    _pager.removeListener(_changed);
    _stop();
    _playback.dispose();
    _pages?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(flowsPagerProvider);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text('Flows'),
        actions: [
          IconButton(
            tooltip: 'Atualizar Flows',
            onPressed: () {
              _activeId = null;
              _pager.load();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_pager, _playback]),
          builder: (context, _) {
            if (_pager.loading && _pager.items.isEmpty) {
              return const FlowStateView(
                kind: FlowViewState.loading,
                message: 'Abrindo Flows…',
              );
            }
            if (_pager.items.isEmpty) {
              return FlowStateView(
                kind: _pager.issue != null
                    ? FlowViewState.error
                    : FlowViewState.empty,
                message:
                    _pager.issue?.message ??
                    (_pager.expired
                        ? 'Atualize os Flows disponíveis.'
                        : 'Nenhum Flow disponível agora.'),
                onRetry: () => _pager.load(),
              );
            }
            return PageView.builder(
              controller: _pages,
              scrollDirection: Axis.vertical,
              itemCount: _pager.items.length + 1,
              onPageChanged: (index) {
                _stop();
                _index = index;
                if (index >= _pager.items.length) {
                  _activeId = null;
                  _pager.load(more: true);
                  return;
                }
                _activeId = _pager.items[index].experience.id;
                _activate();
                setState(() {});
              },
              itemBuilder: (context, index) {
                if (index >= _pager.items.length) {
                  return Center(
                    child: _pager.cursor == null
                        ? const Text(
                            'Você chegou ao fim dos Flows disponíveis.',
                          )
                        : _pager.issue != null
                        ? ExperienceIssueView(
                            _pager.issue!,
                            retry: () => _pager.load(more: true),
                          )
                        : FilledButton(
                            onPressed: _pager.moreLoading
                                ? null
                                : () => _pager.load(more: true),
                            child: Text(
                              _pager.moreLoading ? 'Carregando…' : 'Mais Flows',
                            ),
                          ),
                  );
                }
                final f = _pager.items[index];
                final e = f.experience;
                final active = index == _index && !_details && _foreground;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    FlowImage(f, key: ValueKey('image:${e.id}')),
                    if (active && _playback.player != null)
                      _playback.player!.view(),
                    const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x33000000),
                              Colors.transparent,
                              Color(0xEE10121C),
                            ],
                            stops: [0, .3, 1],
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              e.phase == 'LIVE'
                                  ? 'LIVE · Acontecendo agora'
                                  : 'Em breve',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              e.displayTitle,
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(color: Colors.white),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              [
                                if (_categoryNames[e.input.categoryId] != null)
                                  _categoryNames[e.input.categoryId]!,
                                ExperienceTime.display(
                                  e.input.startsAt,
                                  e.input.timezone,
                                ),
                              ].join(' · '),
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              e.input.venueName,
                              style: const TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 16),
                            if (active && _message != null)
                              Text(
                                _message!,
                                style: const TextStyle(color: Colors.white),
                              ),
                            if (active && _playback.loading)
                              const Text(
                                'Carregando vídeo…',
                                style: TextStyle(color: Colors.white),
                              ),
                            if (active && _playback.failed)
                              const Text(
                                'Vídeo indisponível. Você pode tentar novamente ou abrir os detalhes.',
                                style: TextStyle(color: Colors.white),
                              ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: () => _detail(e.id),
                                  child: const Text('Ver detalhes'),
                                ),
                                if (f.hasVideo && active)
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: const BorderSide(
                                        color: Colors.white,
                                      ),
                                    ),
                                    onPressed: () => _playback.player != null
                                        ? _playback.toggle()
                                        : _activate(playExplicitly: true),
                                    icon: Icon(
                                      _playback.playing
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    label: Text(
                                      _playback.playing
                                          ? 'Pausar'
                                          : 'Reproduzir sem som',
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Deslize para explorar',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
