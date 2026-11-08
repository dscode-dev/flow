import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_state.dart';
import '../../design/components.dart';
import '../../design/tokens.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_time.dart';
import '../experiences/presentation/widgets/experience_widgets.dart';
import 'home_controller.dart';
import 'home_model.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  late HomeController _controller;
  final _sectionKeys = <String, GlobalKey>{};
  final _scroll = ScrollController();
  double _savedOffset = 0;
  bool _wasLoading = false;
  void _homeChanged() {
    final state = _controller.value;
    if (state.loading && !_wasLoading && _scroll.hasClients) {
      _savedOffset = _scroll.offset;
    }
    if (!state.loading && state.document != null && _wasLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _scroll.hasClients &&
            _controller.value.document != null) {
          _scroll.jumpTo(
            _savedOffset.clamp(0, _scroll.position.maxScrollExtent),
          );
        }
      });
    }
    _wasLoading = state.loading;
  }

  final _checkedCovers = <String>{};
  int? _coverGeneration;
  void _coverDenied(HomeItem item) {
    final generation = ref.read(experienceAccessProvider).generation;
    if (_coverGeneration != generation) {
      _checkedCovers.clear();
      _coverGeneration = generation;
    }
    final e = item.experience;
    if (_checkedCovers.add('${e.id}:${e.version}:${e.input.coverMediaId}')) {
      _controller.load();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = ref.read(homeControllerProvider);
    _controller.addListener(_homeChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.load();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (ModalRoute.of(context)?.isCurrent ?? false) _controller.load();
    } else {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_homeChanged);
    _controller.pause();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    _controller.pause();
    await context.push(path);
    if (mounted) {
      await _controller.load();
      _savedOffset = offset;
    }
  }

  Future<void> _region() async {
    final access = ref.read(experienceAccessProvider);
    final generation = access.generation;
    final result = await showFlowSheet<RegionChoice>(
      context,
      RegionForm(
        region: _controller.region,
        defaultRadiusM: _controller.value.document?.defaultRadiusM,
      ),
    );
    if (!mounted || result == null || generation != access.generation) return;
    await _controller.selectRegion(result.region);
  }

  String get _greeting => switch (DateTime.now().hour) {
    < 12 => 'Bom dia',
    < 18 => 'Boa tarde',
    _ => 'Boa noite',
  };
  @override
  Widget build(BuildContext context) {
    ref.watch(homeControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flow'),
        actions: [
          IconButton(
            tooltip: 'Atualizar início',
            onPressed: () => _controller.load(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sair da conta',
            onPressed: () => ref.read(authControllerProvider).signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            alignment: WrapAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: () => _controller.load(),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Início'),
              ),
              TextButton.icon(
                onPressed: () => _open('/radar'),
                icon: const Icon(Icons.radar),
                label: const Text('Radar'),
              ),
              TextButton.icon(
                onPressed: () => _open('/experiences'),
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('Minhas experiências'),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, state, _) {
                final home = state.document;
                final sections =
                    home?.sections
                        .where((s) => s.title.isNotEmpty && s.items.isNotEmpty)
                        .toList() ??
                    <HomeSection>[];
                return RefreshIndicator(
                  onRefresh: () => _controller.load(),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: _scroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _greeting,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Encontre seu próximo encontro.',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _region,
                                icon: const Icon(Icons.place_outlined),
                                label: Text(
                                  _controller.region?.name ?? 'Escolher região',
                                ),
                              ),
                              Text(
                                _controller.region == null
                                    ? 'Descoberta geral · sem usar sua localização'
                                    : 'Região aproximada · raio de ${_controller.region!.radiusM / 1000} km',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (_controller.category != null)
                                TextButton(
                                  onPressed: () =>
                                      _controller.selectCategory(null),
                                  child: const Text('Limpar categoria'),
                                ),
                              if (home != null &&
                                  home.categories.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: ChoiceChip(
                                          label: const Text(
                                            'Todas as categorias',
                                          ),
                                          selected:
                                              _controller.category == null,
                                          onSelected: (_) =>
                                              _controller.selectCategory(null),
                                        ),
                                      ),
                                      for (final category in home.categories)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: ChoiceChip(
                                            label: Text(category.name),
                                            selected:
                                                _controller.category ==
                                                category.id,
                                            onSelected: (_) => _controller
                                                .selectCategory(category.id),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const Text(
                                  'A categoria refina a seção Para você.',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (state.loading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(48),
                            child: FlowStateView(
                              kind: FlowViewState.loading,
                              message: 'Buscando encontros…',
                            ),
                          ),
                        ),
                      if (state.issue != null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: ExperienceIssueView(
                              state.issue!,
                              retry: () => _controller.load(),
                            ),
                          ),
                        ),
                      if (home != null && home.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: FlowStateView(
                              kind: FlowViewState.empty,
                              message: 'Ainda não há experiências públicas para descobrir.\nVolte mais tarde ou escolha outra região.',
                            ),
                          ),
                        ),
                      if (home != null && _controller.region == null)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Perto de você',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    const Text(
                                      'Escolha uma região para descobrir encontros próximos. Não precisamos de GPS.',
                                    ),
                                    TextButton(
                                      onPressed: _region,
                                      child: const Text('Selecionar região'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (sections.length > 1)
                        SliverToBoxAdapter(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Row(
                              children: [
                                for (final section in sections)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ActionChip(
                                      label: Text(section.title),
                                      onPressed: () {
                                        final target = _sectionKeys[section.id]
                                            ?.currentContext;
                                        if (target != null) {
                                          Scrollable.ensureVisible(
                                            target,
                                            duration:
                                                MediaQuery.disableAnimationsOf(
                                                  context,
                                                )
                                                ? Duration.zero
                                                : FlowMotion.standard,
                                          );
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      for (final section in sections)
                        SliverToBoxAdapter(
                          child: Padding(
                            key: _sectionKeys.putIfAbsent(
                              section.id,
                              GlobalKey.new,
                            ),
                            padding: const EdgeInsets.only(top: 24, bottom: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        section.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        section.subtitle(home!),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                if (section.id == 'highlights')
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: HomeExperienceCard(
                                      item: section.items.first,
                                      onTap: () => _open(
                                        '/experiences/${section.items.first.experience.id}',
                                      ),
                                      onAccessDenied: () =>
                                          _coverDenied(section.items.first),
                                    ),
                                  )
                                else
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (final item in section.items)
                                          SizedBox(
                                            width:
                                                (MediaQuery.sizeOf(context)
                                                            .width -
                                                        48)
                                                    .clamp(240, 320)
                                                    .toDouble(),
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                right: 12,
                                              ),
                                              child: HomeExperienceCard(
                                                item: item,
                                                onTap: () => _open(
                                                  '/experiences/${item.experience.id}',
                                                ),
                                                onAccessDenied: () =>
                                                    _coverDenied(item),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 32)),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class HomeExperienceCard extends StatelessWidget {
  const HomeExperienceCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onAccessDenied,
  });
  final HomeItem item;
  final VoidCallback onTap, onAccessDenied;
  @override
  Widget build(BuildContext context) {
    final e = item.experience;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExperienceCover(e, onAccessDenied: onAccessDenied),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.categoryName,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    e.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ExperienceTime.display(e.input.startsAt, e.input.timezone),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    e.input.venueName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.distanceM != null)
                    Text(
                      'Aprox. ${(item.distanceM! / 1000).toStringAsFixed(1)} km do centro escolhido',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  ExperienceStatusBadge(e),
                  if (e.input.externalTicketUrl != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Ingresso em site externo'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RegionChoice {
  const RegionChoice(this.region);
  final DiscoveryRegion? region;
}

class RegionForm extends StatefulWidget {
  const RegionForm({super.key, this.region, this.defaultRadiusM});
  final DiscoveryRegion? region;
  final int? defaultRadiusM;
  @override
  State<RegionForm> createState() => _RegionFormState();
}

class _RegionFormState extends State<RegionForm> {
  final _name = TextEditingController(),
      _latitude = TextEditingController(),
      _longitude = TextEditingController(),
      _radius = TextEditingController();
  String? _error;
  @override
  void initState() {
    super.initState();
    final r = widget.region;
    _name.text = r?.name ?? '';
    _latitude.text = r?.point.latitude.toStringAsFixed(2) ?? '';
    _longitude.text = r?.point.longitude.toStringAsFixed(2) ?? '';
    final radius = r?.radiusM ?? widget.defaultRadiusM;
    _radius.text = radius == null ? '' : (radius / 1000).toString();
  }

  @override
  void dispose() {
    for (final c in [_name, _latitude, _longitude, _radius]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'Sua região de descoberta',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      const Text(
        'Escolha um centro aproximado da cidade ou região. A busca de cidades por mapa ainda não está configurada. O nome é apenas um rótulo; informe o centro desejado. Usamos duas casas decimais, sem GPS e sem guardar histórico.',
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _name,
        maxLength: 60,
        decoration: const InputDecoration(
          labelText: 'Nome da cidade ou região',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _latitude,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: const InputDecoration(
          labelText: 'Latitude aproximada (−90 a 90)',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _longitude,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: const InputDecoration(
          labelText: 'Longitude aproximada (−180 a 180)',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _radius,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Raio em km (1 a 100)'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () {
          final region = DiscoveryRegion.parse(
            _name.text,
            _latitude.text,
            _longitude.text,
            _radius.text,
          );
          if (region == null) {
            setState(() => _error = 'Confira o nome, as coordenadas e o raio.');
            return;
          }
          Navigator.pop(context, RegionChoice(region));
        },
        child: const Text('Usar região'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, const RegionChoice(null)),
        child: const Text('Continuar sem localidade'),
      ),
    ],
  );
}
