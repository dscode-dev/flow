// Enabled only by TestFlutterFlowsNative, with isolated Go/PostGIS/S3 fixtures.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flow_mobile/features/explore/flow_playback.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const origin = String.fromEnvironment('FLOW_NATIVE_CONTRACT_URL');
  testWidgets('player nativo lê MP4 progressivo real, silencioso e sem loop', (
    tester,
  ) async {
    final http = Dio(BaseOptions(baseUrl: origin, followRedirects: false));
    try {
      final result = (await http.get<Map<String, dynamic>>('__fixture/flow'))
          .data!;
      final relative = result['video_url'] as String;
      final player = NativeFlowPlayer(Uri.parse(origin).resolve(relative));
      try {
        await player.initialize().timeout(const Duration(seconds: 20));
        expect(
          player.controller.value.duration.inMilliseconds,
          inInclusiveRange(1, 15000),
        );
        expect(player.controller.value.size.width, greaterThan(0));
        expect(player.controller.value.volume, 0);
        expect(player.controller.value.isLooping, false);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: player.view())),
        );
        await player.play();
        await tester.pump(const Duration(milliseconds: 500));
        await player.pause();
        expect(player.controller.value.isPlaying, false);
        expect(player.controller.value.position.inMilliseconds, greaterThan(0));
      } finally {
        await player.dispose();
        await tester.pumpWidget(const SizedBox());
      }
    } finally {
      http.close(force: true);
    }
  }, skip: origin.isEmpty);
}
