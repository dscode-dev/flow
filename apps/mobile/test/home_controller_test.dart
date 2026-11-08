import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/home/home_controller.dart';
import 'package:flow_mobile/features/home/home_model.dart';

import 'support/auth_fakes.dart';
import 'support/home_fakes.dart';

void main() {
  test('região manual limita precisão, valida entradas e não expõe valores em diagnóstico', () {
    final r = DiscoveryRegion.parse(
      'Minha região',
      '-8.0476',
      '-34,877',
      '25',
    )!;
    expect(r.point.latitude, -8.05);
    expect(r.point.longitude, -34.88);
    expect(r.query['radius_m'], 25000);
    expect(r.toString(), isNot(contains('-8')));
    for (final bad in ['NaN', 'Infinity', '91', '']) {
      expect(DiscoveryRegion.parse('Região', bad, '0', '25'), isNull);
    }
    expect(DiscoveryRegion.parse('', '0', '0', '25'), isNull);
    expect(DiscoveryRegion.parse('Região', '0', '0', '101'), isNull);
  });
  test('troca de região cancela busca obsoleta; resultado tardio não substitui região atual', () async {
    final rig = Rig();
    await rig.login(completed: true);
    final access = ExperienceAccess(rig.auth);
    final repo = HomeFixtureRepository();
    final home = HomeController(repo, access);
    addTearDown(() {
      home.dispose();
      access.dispose();
      rig.auth.dispose();
    });
    final old = Completer<Map<String, dynamic>>();
    repo.gate = old;
    final first = home.load();
    await home.load();
    expect(repo.homeQueries.length, 1);
    final region = DiscoveryRegion.parse('Região B', '-23.55', '-46.63', '10');
    await home.selectRegion(region);
    expect(repo.cancellations.first!.isCancelled, true);
    expect(repo.homeQueries.last['latitude'], -23.55);
    old.complete(homeFixture(title: 'Resultado da região anterior'));
    await first;
    expect(home.value.document!.isEmpty, true);
    await home.selectCategory('music');
    expect(repo.homeQueries.last['category_id'], 'music');
    await home.selectRegion(null);
    expect(repo.homeQueries.last.containsKey('latitude'), false);
  });
  test('logout cancela chamada e apaga cards, região e categoria; falha não conserva fase antiga', () async {
    final rig = Rig();
    await rig.login(completed: true);
    final access = ExperienceAccess(rig.auth);
    final repo = HomeFixtureRepository()
      ..document = homeFixture(title: 'Visível');
    final home = HomeController(repo, access);
    addTearDown(() {
      home.dispose();
      access.dispose();
      rig.auth.dispose();
    });
    await home.selectRegion(DiscoveryRegion.parse('Região', '0', '0', '25'));
    expect(home.value.document!.isEmpty, false);
    repo.failure = const ExperienceIssue('network');
    await home.load();
    expect(home.value.document, isNull);
    expect(home.value.issue!.code, 'network');
    repo.failure = null;
    final pending = Completer<Map<String, dynamic>>();
    repo.gate = pending;
    final loading = home.selectCategory('music');
    await rig.auth.signOut();
    expect(repo.cancellations.last!.isCancelled, true);
    expect(home.region, isNull);
    expect(home.category, isNull);
    pending.complete(homeFixture(title: 'Resposta depois de sair'));
    await loading;
    expect(home.value.document, isNull);
  });
}
