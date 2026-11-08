import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/experiences/application/experience_controllers.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';

class DelayedPages extends FakeExperiencesRepository {
  final pending = <Completer<ExperiencePage>>[];
  final tokens = <CancelToken?>[];
  @override
  Future<ExperiencePage> mine({
    String? cursor,
    ExperienceStatus? status,
    CancelToken? cancel,
  }) {
    tokens.add(cancel);
    final gate = Completer<ExperiencePage>();
    pending.add(gate);
    return gate.future;
  }
}

class InterruptedRead extends FakeExperiencesRepository {
  bool interrupted = true;
  @override
  Future<Experience> get(String id, {CancelToken? cancel}) async {
    if (interrupted) {
      interrupted = false;
      throw const ExperienceIssue('not_found', status: 404);
    }
    return current;
  }
}

void main() {
  late Rig rig;
  late ExperienceAccess access;
  late FakeExperiencesRepository api;
  setUp(() async {
    rig = Rig();
    await rig.login(completed: true);
    access = ExperienceAccess(rig.auth);
    api = FakeExperiencesRepository();
  });
  tearDown(() {
    access.dispose();
    rig.auth.dispose();
  });
  test('resposta obsoleta não substitui filtro novo e request anterior é cancelado', () async {
    final delayed = DelayedPages();
    final controller = ExperiencesListController(delayed, access);
    addTearDown(controller.dispose);
    final first = controller.load();
    final second = controller.load(
      changeFilter: true,
      status: ExperienceStatus.archived,
    );
    expect(delayed.tokens.first!.isCancelled, true);
    delayed.pending.last.complete(
      ExperiencePage([
        sampleExperience(status: ExperienceStatus.archived),
      ], null),
    );
    await second;
    delayed.pending.first.complete(
      ExperiencePage([sampleExperience(status: ExperienceStatus.draft)], null),
    );
    await first;
    expect(controller.value.items.single.status, ExperienceStatus.archived);
  });
  test('POST confirmado seguido de falha GET conserva ID e não recria ao reconciliar', () async {
    final interrupted = InterruptedRead();
    final editor = ExperienceEditorController(interrupted, access);
    addTearDown(editor.dispose);
    editor.field('title', 'Uma única experiência');
    await editor.save();
    expect(editor.value.creationPending, true);
    expect(editor.value.saved, isNull);
    await editor.save();
    expect(interrupted.createdKeys.length, 1);
    expect(editor.value.saved, isNotNull);
  });
  test(
    'criação ambígua mantém chave/corpo, bloqueia edição e deduplica toques',
    () async {
      final editor = ExperienceEditorController(api, access);
      addTearDown(editor.dispose);
      editor.field('title', 'Minha ideia');
      api.failure = const ExperienceIssue('network');
      final one = editor.save();
      final two = editor.save();
      await Future.wait([one, two]);
      expect(api.createdKeys.length, 1);
      expect(editor.value.creationPending, true);
      editor.field('title', 'Outra ideia');
      expect(editor.value.input.title, 'Minha ideia');
      api.failure = null;
      await editor.save();
      expect(api.createdKeys.toSet().length, 1);
      expect(api.createdInputs.last.toJson(), api.createdInputs.first.toJson());
      expect(editor.value.saved!.input.title, 'Minha ideia');
      expect(editor.value.dirty, false);
    },
  );
  test('rascunho retoma documento completo; 412 conserva edição e não atualiza ETag até revisão explícita', () async {
    final editor = ExperienceEditorController(api, access);
    addTearDown(editor.dispose);
    await editor.load(experienceId);
    editor.field('title', 'Edição local');
    api.failure = const ExperienceIssue('version_conflict', status: 412);
    await editor.save();
    expect(editor.value.input.title, 'Edição local');
    expect(editor.value.saved!.etag, '"1"');
    await editor.save();
    expect(api.updates.length, 1);
    api.failure = null;
    api.current = sampleExperience(
      version: 4,
      input: const ExperienceInput(title: 'Edição de outra janela'),
    );
    await editor.compareLatest();
    expect(editor.value.input.title, 'Edição local');
    expect(editor.value.latest!.etag, '"4"');
    editor.useLatest();
    expect(editor.value.input.title, 'Edição de outra janela');
    expect(editor.value.saved!.etag, '"4"');
    editor.field('description', 'Nova revisão consciente');
    await editor.save();
    expect(api.updates.last, '"4"');
  });
  test('erro de publicação não finge sucesso; lifecycle só muda após resposta e acesso revogado limpa detalhes', () async {
    final detail = ExperienceDetailController(api, access, experienceId);
    addTearDown(detail.dispose);
    await detail.load();
    api.failure = const ExperienceIssue('experience_invalid', status: 422);
    await detail.transition('publish');
    expect(detail.value.experience!.status, ExperienceStatus.draft);
    expect(detail.value.issue!.code, 'experience_invalid');
    api.failure = null;
    await detail.transition('publish');
    expect(detail.value.experience!.status, ExperienceStatus.published);
    await detail.transition('cancel');
    expect(detail.value.experience!.status, ExperienceStatus.cancelled);
    await detail.transition('archive');
    expect(detail.value.experience!.status, ExperienceStatus.archived);
    api.failure = const ExperienceIssue('not_found', status: 404);
    await detail.load();
    expect(detail.value.experience, isNull);
  });
  test('paginação deduplica IDs, preserva erro da próxima página e troca filtro reinicia cursor', () async {
    final list = ExperiencesListController(api, access);
    addTearDown(list.dispose);
    api.items = [sampleExperience()];
    api.nextCursor = 'next';
    await list.load();
    await list.load(more: true);
    expect(list.value.items.length, 1);
    expect(api.cursors, [null, 'next']);
    api.failure = const ExperienceIssue('network');
    await list.load(more: true);
    expect(list.value.items.length, 1);
    expect(list.value.issue!.code, 'network');
    api.failure = null;
    await list.load(changeFilter: true, status: ExperienceStatus.archived);
    expect(api.cursors.last, isNull);
  });
  test(
    'saída/restrição de conta limpa lista, editor, capa temporária e detalhes',
    () async {
      final list = ExperiencesListController(api, access),
          detail = ExperienceDetailController(api, access, experienceId);
      final editor = ExperienceEditorController(api, access);
      addTearDown(list.dispose);
      addTearDown(detail.dispose);
      addTearDown(editor.dispose);
      api.items = [sampleExperience()];
      await list.load();
      await detail.load();
      editor.field('address', 'Local privado');
      await rig.auth.signOut();
      expect(list.value.items, isEmpty);
      expect(detail.value.experience, isNull);
      expect(editor.value.input.address, isEmpty);
      expect(access.ownerId, isNull);
    },
  );
}
