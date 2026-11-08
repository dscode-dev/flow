import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

abstract class FlowPlayer {
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
  Widget view();
}

class NativeFlowPlayer implements FlowPlayer {
  NativeFlowPlayer(Uri uri)
    : controller = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
  final VideoPlayerController controller;
  @override
  Future<void> initialize() async {
    await controller.initialize();
    await controller.setVolume(0);
    await controller.setLooping(false);
  }

  @override
  Future<void> play() => controller.play();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> dispose() => controller.dispose();
  @override
  Widget view() => Center(
    child: AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    ),
  );
}

final flowPlayerFactoryProvider = Provider<FlowPlayer Function(Uri)>(
  (ref) => NativeFlowPlayer.new,
);

/// Serialized ownership: old player is disposed before a new player initializes.
/// Only the current visible item can play; muted, non-looping, no offscreen player.
class FlowPlayback extends ChangeNotifier {
  FlowPlayback(this.create);
  final FlowPlayer Function(Uri) create;
  FlowPlayer? player;
  bool loading = false, failed = false, playing = false, _disposed = false;
  int _generation = 0;
  Future<void> _queue = Future.value();
  Future<void> close() {
    _generation++;
    loading = false;
    playing = false;
    final old = player;
    player = null;
    _queue = _queue.catchError((Object _) {}).then((_) async {
      if (old != null) await old.dispose();
    });
    if (!_disposed) notifyListeners();
    return _queue;
  }

  Future<void> open(Uri uri, {required bool autoplay}) {
    close();
    final g = _generation;
    loading = true;
    failed = false;
    notifyListeners();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      if (_disposed || g != _generation) return;
      final next = create(uri);
      try {
        await next.initialize().timeout(const Duration(seconds: 12));
        if (_disposed || g != _generation) {
          await next.dispose();
          return;
        }
        player = next;
        if (autoplay) {
          await next.play();
          playing = true;
        }
      } catch (_) {
        await next.dispose();
        if (!_disposed && g == _generation) {
          player = null;
          failed = true;
        }
      } finally {
        if (!_disposed && g == _generation) {
          loading = false;
          notifyListeners();
        }
      }
    });
    return _queue;
  }

  Future<void> toggle() async {
    final p = player;
    if (p == null) return;
    if (playing) {
      await p.pause();
    } else {
      await p.play();
    }
    if (!_disposed && p == player) {
      playing = !playing;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    super.dispose();
  }
}
