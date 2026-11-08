import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/tokens.dart';
import '../experiences/data/experiences_repository.dart';
import 'discovery_model.dart';
import 'discovery_repository.dart';

/// Decoded memory belongs to this widget/account, never a permanent signed URL.
class FlowImage extends ConsumerStatefulWidget {
  const FlowImage(this.item, {super.key, this.compact = false});
  final FlowItem item;
  final bool compact;
  @override
  ConsumerState<FlowImage> createState() => _FlowImageState();
}

class _FlowImageState extends ConsumerState<FlowImage>
    with WidgetsBindingObserver {
  ui.Image? _image;
  CancelToken? _cancel;
  int _generation = 0;
  bool _failed = false;
  late ExperienceAccess _access;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_clear);
    _load();
  }

  void _clear() {
    _generation++;
    _cancel?.cancel();
    _image?.dispose();
    _image = null;
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    _clear();
    _failed = false;
    if (_access.ownerId == null) return;
    final g = _generation;
    final c = _cancel = CancelToken();
    ui.Codec? codec;
    try {
      final repo = ref.read(discoveryRepositoryProvider);
      final item = await repo.flow(widget.item.experience.id, cancel: c);
      final bytes = await repo.image(item, c);
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: widget.compact ? 280 : 1080,
      );
      final frame = await codec.getNextFrame();
      if (!mounted || g != _generation) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted && g == _generation) setState(() => _failed = true);
    } finally {
      codec?.dispose();
    }
  }

  @override
  void didUpdateWidget(covariant FlowImage old) {
    super.didUpdateWidget(old);
    if (old.item.experience.id != widget.item.experience.id ||
        old.item.experience.version != widget.item.experience.version ||
        old.item.imageUrl != widget.item.imageUrl) {
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    } else {
      _clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_clear);
    _cancel?.cancel();
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(gradient: FlowColors.accent),
    child: SizedBox.expand(
      child: _image != null
          ? Semantics(
              image: true,
              label: 'Imagem da experiência',
              child: RawImage(image: _image, fit: BoxFit.cover),
            )
          : Center(
              child: _failed
                  ? IconButton(
                      tooltip: 'Tentar carregar imagem',
                      onPressed: _load,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                    )
                  : const Icon(Icons.landscape_outlined, color: Colors.white),
            ),
    ),
  );
}
