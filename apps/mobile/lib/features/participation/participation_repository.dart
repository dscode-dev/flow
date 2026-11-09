import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';

/// Shares the central Dio/session boundary, refresh policy and cancellation.
class ParticipationRepository {
  ParticipationRepository(this.experiences);
  final ExperiencesRepository experiences;
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
  }) => experiences.discoveryRequest(
    method,
    path,
    body: body,
    query: query,
    headers: headers,
    cancel: cancel,
  );
}

final participationRepositoryProvider = Provider<ParticipationRepository>(
  (ref) => ParticipationRepository(ref.watch(experiencesRepositoryProvider)),
);

String participationMessage(Object? issue) {
  final code = issue is AuthIssue ? issue.code : 'unexpected';
  return switch (code) {
    'private_invitation_required' =>
      'Experiências privadas exigem convite individual.',
    'capacity_full' =>
      'Não há vagas agora. Sua solicitação ou convite foi preservado.',
    'capacity_below_confirmed' =>
      'O limite precisa comportar as participações já confirmadas.',
    'participation_transition' =>
      'Esta ação não está mais disponível. Atualize sua situação.',
    'invitation_unavailable' => 'Não foi possível convidar esse destinatário. Confira o identificador e sua elegibilidade.',
    'invitation_expired' => 'Este convite expirou.',
    'checkin_unavailable' =>
      'Check-in indisponível para esta participação ou horário.',
    'checkin_code_invalid' =>
      'Código inválido para esta experiência. Confira com o participante.',
    'checkin_code_expired' =>
      'O código expirou. O participante precisa gerar outro.',
    'checkin_code_used' => 'Este código já foi utilizado ou revogado.',
    'idempotency_conflict' => 'Esta tentativa já foi recebida com outros dados. Atualize antes de continuar.',
    'not_found' => 'Experiência indisponível ou sem acesso.',
    _ =>
      issue is AuthIssue
          ? issue.message
          : 'Não foi possível concluir agora. Tente novamente.',
  };
}

String participationLabel(String? state) => switch (state) {
  'NONE' => 'Sem participação',
  'PENDING' => 'Aguardando aprovação',
  'CONFIRMED' => 'Participação confirmada',
  'DECLINED' => 'Solicitação recusada',
  'CANCELLED' => 'Participação cancelada',
  'REMOVED' => 'Participação removida',
  'ACCEPTED' => 'Convite aceito',
  'REVOKED' => 'Convite revogado',
  'UNAVAILABLE' => 'Acesso indisponível',
  'ENDED' => 'Experiência encerrada',
  'EXPERIENCE_CANCELLED' => 'Experiência cancelada',
  'EXPERIENCE_ARCHIVED' => 'Experiência arquivada',
  _ => 'Situação indisponível',
};
String modeLabel(String mode) => switch (mode) {
  'FREE' => 'Entrada livre',
  'APPROVAL' => 'Com aprovação',
  _ => 'Somente por convite',
};
