import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AuthStatus { unknown, unauthenticated, authenticated }

class AuthState {
  const AuthState(this.status, {this.subject});
  final AuthStatus status;
  final String? subject;
}

abstract interface class AuthRepository {
  Stream<AuthState> get changes;
  Future<AuthState> restore();
  Future<void> signOut();
}

// PR-01 ligará restauração e repositório a um AsyncNotifier.
// unknown nunca libera uma rota protegida. Nenhum emissor ou sessão simulada.
final authStateProvider = Provider<AuthState>(
  (ref) => const AuthState(AuthStatus.unknown),
);
