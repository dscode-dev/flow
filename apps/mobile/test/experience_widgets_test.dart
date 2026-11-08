import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/experiences/presentation/pages/experience_editor_page.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';

Future<ProviderContainer> mountExperiences(
  WidgetTester tester,
  Rig rig,
  FakeExperiencesRepository repository,
) async {
  rig.auth.lifecycle(false);
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWithValue(rig.auth),
      experiencesRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(() {
    container.dispose();
    rig.auth.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const FlowApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'capa com acesso revogado força revalidação e remove texto privado antigo',
    (tester) async {
      final rig = Rig();
      await rig.login(completed: true);
      final api = RevokedCoverRepository()
        ..current = sampleExperience(
          creator: 'other',
          status: ExperienceStatus.published,
          input: const ExperienceInput(
            title: 'Título anterior',
            description: 'Detalhe privado anterior',
            coverMediaId: 'media-1',
          ),
        );
      final container = await mountExperiences(tester, rig, api);
      container.read(routerProvider).go('/experiences/$experienceId');
      await tester.pumpAndSettle();
      expect(find.text('Detalhe privado anterior'), findsNothing);
      expect(find.text('Título anterior'), findsNothing);
      expect(find.textContaining('sem acesso'), findsOneWidget);
    },
  );
  testWidgets(
    'saída limpa também os campos visuais mesmo se o editor permanecer montado',
    (tester) async {
      final rig = Rig();
      await rig.login(completed: true);
      rig.auth.lifecycle(false);
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithValue(rig.auth),
          experiencesRepositoryProvider.overrideWithValue(
            FakeExperiencesRepository(),
          ),
        ],
      );
      addTearDown(() {
        container.dispose();
        rig.auth.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ExperienceEditorPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Título'),
        'Conteúdo da conta anterior',
      );
      await rig.auth.signOut();
      await tester.pumpAndSettle();
      expect(find.text('Conteúdo da conta anterior'), findsNothing);
      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Título'),
      );
      expect(field.initialValue, isEmpty);
    },
  );
  testWidgets('criar salva apenas após API e rascunho pode ser retomado', (
    tester,
  ) async {
    final rig = Rig();
    await rig.login(completed: true);
    final api = FakeExperiencesRepository();
    final container = await mountExperiences(tester, rig, api);
    container.read(routerProvider).go('/experiences');
    await tester.pumpAndSettle();
    expect(find.text('Uma ideia pode virar um encontro.'), findsOneWidget);
    await tester.tap(find.text('Criar experiência'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Título'),
      'Passeio de sábado',
    );
    await tester.scrollUntilVisible(
      find.text('Salvar rascunho'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar rascunho'));
    await tester.pumpAndSettle();
    expect(api.createdInputs.single.title, 'Passeio de sábado');
    expect(find.text('Rascunho salvo no servidor.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    container.read(routerProvider).go('/experiences/$experienceId/edit');
    await tester.pumpAndSettle();
    expect(find.text('Passeio de sábado'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Título'),
      'Passeio atualizado',
    );
    await tester.scrollUntilVisible(
      find.text('Salvar rascunho'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar rascunho'));
    await tester.pumpAndSettle();
    expect(api.updates.last, '"1"');
    expect(api.current.input.title, 'Passeio atualizado');
  });
  testWidgets(
    'redaction remove detalhes, coordenadas, ticket e ações de terceiros',
    (tester) async {
      final rig = Rig();
      await rig.login(completed: true);
      final api = FakeExperiencesRepository()
        ..current = sampleExperience(
          creator: 'other',
          status: ExperienceStatus.cancelled,
          redacted: true,
          input: const ExperienceInput(
            title: 'Histórico',
            description: 'Texto que não pode aparecer',
            address: 'Endereço que não pode aparecer',
            location: GeoPoint(1, 2),
            externalTicketUrl: 'https://tickets.flow.invalid/',
          ),
        );
      final container = await mountExperiences(tester, rig, api);
      container.read(routerProvider).go('/experiences/$experienceId');
      await tester.pumpAndSettle();
      expect(find.text('Histórico'), findsOneWidget);
      expect(find.text('Texto que não pode aparecer'), findsNothing);
      expect(
        find.textContaining('Endereço que não pode aparecer'),
        findsNothing,
      );
      expect(find.text('Ingressos em site externo'), findsNothing);
      expect(find.text('Publicar'), findsNothing);
      api.failure = const ExperienceIssue('not_found', status: 404);
      await tester.tap(find.byTooltip('Atualizar experiência'));
      await tester.pumpAndSettle();
      expect(find.text('Histórico'), findsNothing);
      expect(find.textContaining('sem acesso'), findsOneWidget);
    },
  );
  testWidgets(
    'rotas diretas exigem autenticação, sem retorno externo ou bypass de onboarding',
    (tester) async {
      final rig = Rig();
      await rig.auth.restore();
      final api = FakeExperiencesRepository();
      final container = await mountExperiences(tester, rig, api);
      container
          .read(routerProvider)
          .go('/experiences/$experienceId/edit?returnTo=https://evil.invalid');
      await tester.pumpAndSettle();
      expect(find.text('Continuar com telefone'), findsOneWidget);
      expect(find.text('Editar experiência'), findsNothing);
      expect(
        authRedirect(
          const AuthState(AuthStatus.onboardingRequired),
          '/experiences/$experienceId',
        ),
        '/onboarding',
      );
      expect(isExperiencePath('//evil.invalid'), false);
      expect(isExperiencePath('/experiences/not-an-id'), false);
    },
  );
  testWidgets(
    'formulário, lista e detalhes cabem em 320px/texto 200%/teclado nos dois temas',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final rig = Rig();
      await rig.login(completed: true);
      final api = FakeExperiencesRepository()..items = [sampleExperience()];
      final container = await mountExperiences(tester, rig, api);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        for (final path in [
          '/experiences',
          '/experiences/$experienceId',
          '/experiences/new',
        ]) {
          container.read(routerProvider).go(path);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final label in ['2 Quando', '3 Onde', '4 Acesso', '5 Revisão']) {
          final chip = find.text(label);
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        tester.view.resetViewInsets();
      }
    },
  );
}
