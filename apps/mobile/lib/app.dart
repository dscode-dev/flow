import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/router.dart';
import 'core/auth/auth_state.dart';
import 'design/flow_theme.dart';

class FlowApp extends ConsumerStatefulWidget {
  const FlowApp({super.key});
  @override
  ConsumerState<FlowApp> createState() => _FlowAppState();
}

class _FlowAppState extends ConsumerState<FlowApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(authControllerProvider).lifecycle(true);
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ref.read(authControllerProvider).lifecycle(false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Flow',
    debugShowCheckedModeBanner: false,
    locale: const Locale('pt', 'BR'),
    supportedLocales: const [Locale('pt', 'BR')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: FlowTheme.light,
    darkTheme: FlowTheme.dark,
    themeMode: ThemeMode.system,
    routerConfig: ref.watch(routerProvider),
  );
}
