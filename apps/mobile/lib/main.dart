import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/environment.dart';
import 'core/errors/app_failure.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) => reportFailure(AppFailure.unexpected);
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    reportFailure(AppFailure.unexpected);
    return true;
  };
  try {
    final environment = AppEnvironment.fromDefines();
    runApp(
      ProviderScope(
        overrides: [environmentProvider.overrideWithValue(environment)],
        child: const FlowApp(),
      ),
    );
  } on FormatException {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Configuração do aplicativo inválida.')),
        ),
      ),
    );
  }
}
