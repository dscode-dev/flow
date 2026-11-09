import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/data/experiences_repository.dart';
import '../explore/flow_playback.dart';
import 'social_repository.dart';

/// One coordinator per Social route. Opening another item disposes the old
/// native player first. Images and URLs are widget-local, cleared on expiry.
class SocialMedia extends ConsumerStatefulWidget {
  const SocialMedia(
    this.postId,
    this.asset, {
    required this.playback,
    super.key,
  });
  final String? postId;
  final Map<String, dynamic> asset;
  final FlowPlayback playback;
  @override
  ConsumerState<SocialMedia> createState() => _SocialMediaState();
}

class _SocialMediaState extends ConsumerState<SocialMedia>
    with WidgetsBindingObserver {
  Uri? _source;
  ui.Image? _image;
  CancelToken? _cancel;
  Timer? _ttl;
  int _revision = 0;
  bool _failed = false, _active = false, _loading = false;
  late ExperienceAccess _access;
  @override
  void initState() {
    super.initState();
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_clear);
    WidgetsBinding.instance.addObserver(this);
  }

  void _clear() {
    _revision++;
    _cancel?.cancel();
    _ttl?.cancel();
    _image?.dispose();
    _image = null;
    _loading = false;
    if (_active && widget.playback.source == _source) {
      unawaited(widget.playback.close());
    }
    _active = false;
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _clear();
    setState(() => _loading = true);
    final g = _revision;
    final c = _cancel = CancelToken();
    ui.Codec? codec;
    try {
      final repo = ref.read(socialRepositoryProvider);
      final watch = Stopwatch()..start();
      final post = await repo.request(
        'GET',
        widget.postId == null
            ? 'v1/social/media/${widget.asset['id']}'
            : 'v1/social/posts/${widget.postId}',
        cancel: c,
      );
      final media = widget.postId == null
          ? post
          : (post['media'] as List).cast<Map<String, dynamic>>().firstWhere(
              (m) => m['id'] == widget.asset['id'],
            );
      if (!mounted || g != _revision) return;
      if (media['status'] != 'READY') throw StateError('unavailable');
      final remaining =
          DateTime.parse(media['expires_at'] as String)
              .difference(DateTime.parse(post['as_of'] as String)) -
          watch.elapsed;
      if (remaining <= Duration.zero) throw StateError('expired');
      _ttl = Timer(remaining, _clear);
      if (media['duration_ms'] != null) {
        _active = true;
        _source = repo.mediaUri(media['url'] as String);
        await widget.playback.open(_source!, autoplay: false);
        if (!mounted || g != _revision) {
          if (widget.playback.source == _source) await widget.playback.close();
          return;
        }
      } else {
        final bytes = await repo.image(media['url'] as String, c);
        codec = await ui.instantiateImageCodec(bytes, targetWidth: 1080);
        final frame = await codec.getNextFrame();
        if (!mounted || g != _revision) {
          frame.image.dispose();
          return;
        }
        _image = frame.image;
      }
      if (mounted && g == _revision) setState(() => _failed = false);
    } catch (_) {
      if (mounted && g == _revision) setState(() => _failed = true);
    } finally {
      codec?.dispose();
      if (mounted && g == _revision) setState(() => _loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) _clear();
  }

  @override
  void didUpdateWidget(covariant SocialMedia old) {
    super.didUpdateWidget(old);
    if (old.asset['id'] != widget.asset['id'] ||
        old.asset['url'] != widget.asset['url']) {
      _clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_clear);
    _cancel?.cancel();
    _ttl?.cancel();
    _revision++;
    _image?.dispose();
    if (_active && widget.playback.source == _source) {
      unawaited(widget.playback.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 4 / 3,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListenableBuilder(
          listenable: widget.playback,
          builder: (context, _) {
            final p = widget.playback;
            if (_active && p.source == _source && p.player != null) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  p.player!.view(),
                  IconButton.filled(
                    tooltip: p.playing
                        ? 'Pausar vídeo'
                        : 'Reproduzir vídeo sem som',
                    onPressed: p.toggle,
                    icon: Icon(p.playing ? Icons.pause : Icons.play_arrow),
                  ),
                ],
              );
            }
            if (_image != null) {
              return Semantics(
                image: true,
                label: 'Imagem da publicação',
                child: RawImage(image: _image, fit: BoxFit.contain),
              );
            }
            if (_loading) {
              return const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: "Carregando mídia",
                ),
              );
            }
            return Center(
              child: TextButton.icon(
                onPressed: _load,
                icon: Icon(
                  (widget.asset['duration_ms'] != null ||
                          (widget.asset['content_type'] as String? ?? '')
                              .startsWith('video/'))
                      ? Icons.play_circle_outline
                      : Icons.image_outlined,
                ),
                label: Text(
                  _failed || (_active && p.failed)
                      ? 'Tentar carregar mídia'
                      : (widget.asset['duration_ms'] != null ||
                            (widget.asset['content_type'] as String? ?? '')
                                .startsWith('video/'))
                      ? 'Abrir vídeo · até 15s'
                      : 'Ver imagem',
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}
