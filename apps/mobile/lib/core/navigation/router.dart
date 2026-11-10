import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_state.dart';
import '../../features/auth/auth_screens.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/experiences/presentation/pages/my_experiences_page.dart';
import '../../features/experiences/presentation/pages/experience_detail_page.dart';
import '../../features/experiences/presentation/pages/experience_editor_page.dart';
import '../../features/home/home_page.dart';
import '../../features/radar/radar_page.dart';
import '../../features/explore/explore_page.dart';
import '../../features/explore/flows_viewer_page.dart';
import '../../features/explore/flow_management_page.dart';
import '../../features/participation/agenda_page.dart';
import '../../features/participation/participation_management_page.dart';
import '../../features/participation/checkin_page.dart';
import '../../features/social/social_page.dart';
import '../../features/event_space/event_space_page.dart';
import '../../features/social/social_compose_page.dart';

bool isExperiencePath(String path) =>
    path == '/app' ||
    path == '/radar' ||
    path == '/explore' ||
    path == '/agenda' ||
    path == '/social' ||
    path == '/social/new' ||
    path == '/social/blocks' ||
    RegExp(
      r'^/social/(posts|profiles)/[0-9a-fA-F-]{36}(/edit|/followers|/following)?$',
    ).hasMatch(path) ||
    path == '/flows' ||
    RegExp(r'^/flows/[0-9a-fA-F-]{36}$').hasMatch(path) ||
    path == '/experiences' ||
    path == '/experiences/new' ||
    RegExp(
      r'^/experiences/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/edit|/flow|/participants|/check-in|/space|/space/new)?$',
    ).hasMatch(path);

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
    return isExperiencePath(path) ? null : destination;
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
      if (isExperiencePath(state.uri.path) &&
          state.uri.query.isEmpty &&
          state.uri.fragment.isEmpty) {
        destination = state.uri.path;
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
      GoRoute(path: '/app', builder: (_, _) => const HomePage()),
      GoRoute(path: '/radar', builder: (_, _) => const RadarPage()),
      GoRoute(path: '/explore', builder: (_, _) => const ExplorePage()),
      GoRoute(path: '/agenda', builder: (_, _) => const AgendaPage()),
      GoRoute(
        path: '/experiences/:id/space/new',
        builder: (_, s) => SocialComposePage(
          spaceId: s.pathParameters['id']!,
          key: ValueKey('space-compose:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/experiences/:id/space',
        builder: (_, s) => EventSpacePage(
          s.pathParameters['id']!,
          key: ValueKey('space:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(path: '/social', builder: (_, _) => const SocialPage()),
      GoRoute(
        path: '/social/new',
        builder: (_, _) => const SocialComposePage(),
      ),
      GoRoute(
        path: '/social/blocks',
        builder: (_, _) => const SocialPage(section: 'blocks'),
      ),
      GoRoute(
        path: '/social/posts/:id/edit',
        builder: (_, s) => SocialComposePage(
          id: s.pathParameters['id']!,
          key: ValueKey('social-edit:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/social/posts/:id',
        builder: (_, s) => SocialPage(
          postId: s.pathParameters['id']!,
          key: ValueKey('social-post:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/social/profiles/:id/followers',
        builder: (_, s) => SocialPage(
          userId: s.pathParameters['id']!,
          section: 'followers',
          key: ValueKey('social-followers:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/social/profiles/:id/following',
        builder: (_, s) => SocialPage(
          userId: s.pathParameters['id']!,
          section: 'following',
          key: ValueKey('social-following:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/social/profiles/:id',
        builder: (_, s) => SocialPage(
          userId: s.pathParameters['id']!,
          key: ValueKey('social-profile:${s.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/experiences/:id/participants',
        builder: (_, state) =>
            ParticipationManagementPage(state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/experiences/:id/check-in',
        builder: (_, state) => CheckinPage(state.pathParameters['id']!),
      ),
      GoRoute(path: '/flows', builder: (_, _) => const FlowsViewerPage()),
      GoRoute(
        path: '/flows/:id',
        builder: (_, state) =>
            FlowsViewerPage(initialId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/experiences/:id/flow',
        builder: (_, state) => FlowManagementPage(state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/experiences',
        builder: (_, _) => const MyExperiencesPage(),
      ),
      GoRoute(
        path: '/experiences/new',
        builder: (_, _) => const ExperienceEditorPage(),
      ),
      GoRoute(
        path: '/experiences/:id/edit',
        builder: (_, state) =>
            ExperienceEditorPage(id: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/experiences/:id',
        builder: (_, state) =>
            ExperienceDetailPage(state.pathParameters['id']!),
      ),
    ],
    errorBuilder: (_, _) => const WelcomeScreen(),
  );
  ref.onDispose(router.dispose);
  return router;
});
