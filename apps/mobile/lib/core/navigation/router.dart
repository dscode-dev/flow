import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const _FoundationScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Flow')),
      body: FlowStateView(
        kind: FlowViewState.error,
        message: 'Este link não está disponível.',
        onRetry: () => context.go('/'),
      ),
    ),
  );
  ref.onDispose(router.dispose);
  return router;
});

class _FoundationScreen extends StatelessWidget {
  const _FoundationScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Flow')),
    body: const FlowStateView(
      kind: FlowViewState.empty,
      message: 'Novas experiências começam aqui.',
    ),
  );
}
