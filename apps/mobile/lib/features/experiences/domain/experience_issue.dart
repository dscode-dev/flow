import '../../../core/auth/models.dart';
export '../../../core/auth/models.dart' show AuthIssue;

class ExperienceIssue extends AuthIssue {
  const ExperienceIssue(
    super.code, {
    super.status,
    super.requestId,
    super.retryAfter,
  });
  @override
  String get message => switch (code) {
    'version_conflict' => 'Outra alteração foi salva. Sua edição foi mantida. Compare com a versão atual antes de continuar.',
    'experience_invalid' => 'Confira título, descrição, categoria, agenda, fuso e local. O servidor não aceitou os dados.',
    'protected_attributes' => 'Agenda, local, categoria, capacidade e visibilidade estão protegidos após publicar.',
    'invalid_transition' =>
      'Esta ação não está mais disponível. Atualize a experiência.',
    'not_found' => 'Experiência indisponível ou sem acesso.',
    'publishing_restricted' =>
      'A publicação está indisponível para esta experiência ou conta.',
    'onboarding_required' => 'Conclua seu perfil antes de criar experiências.',
    'draft_limit' =>
      'Seu limite de rascunhos foi atingido. Gerencie os rascunhos existentes.',
    'idempotency_conflict' => 'Esta tentativa já foi recebida com outros dados. Confira suas experiências antes de criar outra.',
    'media_invalid' => 'Escolha uma imagem JPEG ou PNG de até 5 MiB, 4096 pixels por lado e 12 megapixels.',
    'media_not_ready' =>
      'A capa ainda não foi verificada. Confirme o envio antes de salvar.',
    'upload_expired' =>
      'A autorização de envio expirou. Inicie um novo envio explicitamente.',
    'upload_not_pending' => 'Este envio não está mais pendente. Confira a confirmação ou escolha outra imagem.',
    'media_unavailable' => 'Não foi possível enviar ou ler a capa agora. O restante da experiência foi preservado.',
    'payload_too_large' =>
      'O conteúdo excede o limite. Reduza os textos ou a imagem.',
    'precondition_required' =>
      'Não foi possível confirmar a versão. Reabra a experiência.',
    'canceled' => 'Operação interrompida. Uma gravação já enviada pode ter sido recebida; confira antes de repetir.',
    _ => super.message,
  };
}
