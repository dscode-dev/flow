import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/router.dart';
import 'design/flow_theme.dart';

class FlowApp extends ConsumerWidget {
  const FlowApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
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
