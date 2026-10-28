import 'package:flutter/material.dart';

import 'tokens.dart';

enum FlowViewState { loading, empty, error, success }

class FlowStateView extends StatelessWidget {
  const FlowStateView({
    super.key,
    required this.kind,
    required this.message,
    this.onRetry,
  });
  final FlowViewState kind;
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      FlowViewState.loading => null,
      FlowViewState.empty => Icons.explore_outlined,
      FlowViewState.error => Icons.error_outline,
      FlowViewState.success => Icons.check_circle_outline,
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FlowSpace.lg),
        child: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : FlowMotion.standard,
          switchInCurve: FlowMotion.curve,
          child: Column(
            key: ValueKey(kind),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon == null)
                const CircularProgressIndicator(semanticsLabel: 'Carregando')
              else
                Icon(
                  icon,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              const SizedBox(height: FlowSpace.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: FlowSpace.md),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Tentar novamente'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FlowCard extends StatelessWidget {
  const FlowCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(FlowSpace.md), child: child),
  );
}

Future<T?> showFlowSheet<T>(BuildContext context, Widget child) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          FlowSpace.lg,
          FlowSpace.md,
          FlowSpace.lg,
          MediaQuery.viewInsetsOf(context).bottom + FlowSpace.lg,
        ),
        child: SingleChildScrollView(child: child),
      ),
    );
