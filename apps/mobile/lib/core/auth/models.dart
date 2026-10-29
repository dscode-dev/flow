import 'dart:convert';

class FlowUser {
  const FlowUser(
    this.id,
    this.onboardingRequired,
    this.displayName,
    this.handle,
  );
  final String id;
  final bool onboardingRequired;
  final String displayName;
  final String? handle;
  factory FlowUser.fromJson(Map<String, dynamic> json) {
    if (json['status'] != 'active') throw const AuthIssue('account_restricted');
    final profile = json['profile'] as Map<String, dynamic>;
    return FlowUser(
      json['id'] as String,
      json['onboarding_required'] as bool,
      profile['display_name'] as String,
      profile['handle'] as String?,
    );
  }
}

class LoginResult {
  LoginResult(
    this.access,
    this.refresh,
    this.sessionId,
    this.accessUntil,
    this.sessionUntil,
    this.user,
  );
  final String access, refresh, sessionId;
  final DateTime accessUntil, sessionUntil;
  final FlowUser user;
  factory LoginResult.fromJson(Map<String, dynamic> json, DateTime now) {
    final t = json['tokens'] as Map<String, dynamic>;
    if (t['token_type'] != 'Bearer' ||
        !(t['access_token'] as String).startsWith('fa_') ||
        !(t['refresh_token'] as String).startsWith('fr_') ||
        (t['expires_in'] as int) <= 0) {
      throw const FormatException('Sessão inválida');
    }
    return LoginResult(
      t['access_token'] as String,
      t['refresh_token'] as String,
      t['session_id'] as String,
      now.add(Duration(seconds: t['expires_in'] as int)),
      DateTime.parse(t['session_expires_at'] as String).toUtc(),
      FlowUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}

class StoredSession {
  const StoredSession(
    this.refresh,
    this.sessionId,
    this.until, {
    this.appleUser,
  });
  final String refresh, sessionId;
  final DateTime until;
  final String? appleUser;
  String encode() => jsonEncode({
    'v': 1,
    'refresh': refresh,
    'session_id': sessionId,
    'until': until.toUtc().toIso8601String(),
    'apple_user': appleUser,
  });
  factory StoredSession.decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (j['v'] != 1 ||
        j['pending'] == true ||
        j['refresh'] is! String ||
        !(j['refresh'] as String).startsWith('fr_') ||
        j['session_id'] is! String ||
        (j['session_id'] as String).isEmpty) {
      throw const FormatException('Sessão local inválida');
    }
    return StoredSession(
      j['refresh'] as String,
      j['session_id'] as String,
      DateTime.parse(j['until'] as String).toUtc(),
      appleUser: j['apple_user'] as String?,
    );
  }
}

class AuthChallenge {
  AuthChallenge(this.id, this.expiresAt, this.resendAt, this.nonce);
  final String id;
  final DateTime expiresAt, resendAt;
  final String? nonce;
  factory AuthChallenge.fromJson(Map<String, dynamic> j, DateTime now) =>
      AuthChallenge(
        j['challenge_id'] as String,
        DateTime.parse(j['expires_at'] as String).toUtc(),
        now.add(Duration(seconds: j['resend_after_seconds'] as int)),
        j['nonce'] as String?,
      );
}

class AuthIssue implements Exception {
  const AuthIssue(this.code, {this.requestId, this.retryAfter, this.status});
  final String code;
  final String? requestId;
  final Duration? retryAfter;
  final int? status;
  String get message => switch (code) {
    'canceled' => 'Entrada cancelada. Você pode escolher como continuar.',
    'invalid_request' => 'Confira os dados informados e tente novamente.',
    'invalid_credential' => 'Não foi possível validar esta tentativa. Confira o código ou solicite uma nova tentativa após o prazo.',
    'rate_limited' => 'Muitas tentativas. Aguarde o prazo indicado. Limites do serviço podem exigir mais tempo.',
    'account_restricted' =>
      'O acesso a esta conta está restrito. Procure o suporte do Flow.',
    'handle_unavailable' =>
      'Este nome de usuário não está disponível. Escolha outro.',
    'onboarding_already_completed' =>
      'Seu perfil já foi concluído. Atualize para continuar.',
    'session_limit' => 'Limite de sessões atingido. Use um dispositivo conectado para encerrar uma sessão ou procure suporte.',
    'identity_conflict' =>
      'Não foi possível usar esta identidade nesta operação.',
    'provider_configuration' => 'Este método precisa ser configurado para este aplicativo. Consulte as instruções de configuração do projeto.',
    'apple_unavailable' => 'A entrada com Apple está disponível neste aplicativo somente no iOS configurado.',
    'provider_unavailable' || 'temporarily_unavailable' =>
      'Este serviço está indisponível no momento. Tente mais tarde.',
    'storage' => 'Não foi possível acessar ou limpar a sessão segura. Tente limpar a sessão novamente antes de entrar.',
    'session_expired' ||
    'unauthorized' => 'Sua sessão terminou. Entre novamente para continuar.',
    'network' => 'Não foi possível confirmar a operação. Verifique sua conexão antes de iniciar uma nova tentativa.',
    _ => 'Não foi possível concluir a operação. Tente novamente.',
  };
  @override
  String toString() => 'AuthIssue($code)'; // Nunca payloads ou credenciais.
}
