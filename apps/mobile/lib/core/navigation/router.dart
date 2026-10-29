import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../../features/auth/auth_screens.dart';
import '../../features/onboarding/onboarding_screen.dart';

// Only an explicit local route is retained. Never accept returnTo/absolute URLs.
String? authRedirect(
  AuthState auth,
  String path, {
  String destination = '/app',
}) {
  if ({AuthStatus.initializing, AuthStatus.refreshing}.contains(auth.status) &&
      auth.user != null) {
    final retained = auth.user!.onboardingRequired
        ? '/onboarding'
        : destination;
    return path == retained ? null : retained;
  }
  if ({
    AuthStatus.initializing,
    AuthStatus.refreshing,
    AuthStatus.error,
    AuthStatus.restricted,
  }.contains(auth.status)) {
    return path == '/session' ? null : '/session';
  }
  if (auth.status == AuthStatus.authenticated) {
    return path == destination ? null : destination;
  }
  if (auth.status == AuthStatus.onboardingRequired) {
    return path == '/onboarding' ? null : '/onboarding';
  }
  if (auth.status == AuthStatus.challengePending && auth.challenge != null) {
    return path == '/otp' ? null : '/otp';
  }
  if (path == '/welcome' || path == '/phone') return null;
  return '/welcome';
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authControllerProvider);
  var destination = '/app';
  final router = GoRouter(
    initialLocation: '/welcome',
    refreshListenable: auth,
    redirect: (context, state) {
      if (state.uri.path == '/app' &&
          state.uri.query.isEmpty &&
          state.uri.fragment.isEmpty) {
        destination = '/app';
      }
      return authRedirect(auth.value, state.uri.path, destination: destination);
    },
    routes: [
      GoRoute(path: '/', redirect: (_, _) => '/welcome'),
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: '/phone', builder: (_, _) => const PhoneScreen()),
      GoRoute(path: '/otp', builder: (_, _) => const OtpScreen()),
      GoRoute(path: '/session', builder: (_, _) => const SessionGateScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/app', builder: (_, _) => const DevelopmentShell()),
    ],
    errorBuilder: (_, _) => const WelcomeScreen(),
  );
  ref.onDispose(router.dispose);
  return router;
});
