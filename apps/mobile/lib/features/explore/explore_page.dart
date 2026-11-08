import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_time.dart';
import '../experiences/presentation/widgets/experience_widgets.dart';
import '../home/home_model.dart';
import '../home/home_page.dart' show RegionForm, RegionChoice;
import 'discovery_controller.dart';
import 'discovery_model.dart';
import 'flow_image.dart';

class ExplorePage extends ConsumerStatefulWidget {
  const ExplorePage({super.key});
  @override
  ConsumerState<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends ConsumerState<ExplorePage>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late DiscoveryPager<Experience> _results;
  late DiscoveryPager<FlowItem> _flows;
  late ExperienceAccess _access;
  List<ExperienceCategory> _categories = [];
  String? _category, _phase;
  DateTimeRange? _dates;
  DiscoveryRegion? _region;
  bool _opening = false;
  bool _modalOpen = false;
  ModalRoute<dynamic>? _ownerRoute;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _results = ref.read(explorePagerProvider);
    _flows = ref.read(flowsPagerProvider);
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_account);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _apply();
        _catalog();
      }
    });
  }

  void _account() {
    _generation++;
    _search.clear();
    _category = null;
    _phase = null;
    _dates = null;
    _region = null;
    _categories = [];
    if (_modalOpen && mounted) {
      _modalOpen = false;
      Navigator.of(context).popUntil((route) => route == _ownerRoute);
    }
    if (mounted) setState(() {});
  }

  Future<void> _catalog() async {
    final g = _generation;
    try {
      final c = await ref.read(experiencesRepositoryProvider).categories();
      if (mounted && g == _generation) setState(() => _categories = c);
    } catch (_) {}
  }

  void _apply({bool debounce = false, bool updateFlows = true}) {
    _results.change({
      'q': ?_search.text.trim().isEmpty ? null : _search.text.trim(),
      'category_id': ?_category,
      'phase': ?_phase,
      if (_dates != null) ...{
        'from': _dates!.start.toUtc().toIso8601String(),
        'until': DateTime(
          _dates!.end.year,
          _dates!.end.month,
          _dates!.end.day + 1,
        ).toUtc().toIso8601String(),
      },
      ...?_region?.query,
    }, debounce: debounce);
    if (updateFlows) {
      _flows.change({'category_id': ?_category, ...?_region?.query});
    }
  }

  Future<void> _open(String path) async {
    if (_opening) return;
    _opening = true;
    try {
      await context.push(path);
    } finally {
      _opening = false;
      if (mounted) {
        _results.load();
        _flows.load();
      }
    }
  }

  Future<void> _pickRegion() async {
    final g = _generation;
    _modalOpen = true;
    _ownerRoute = ModalRoute.of(context);
    final choice = await showFlowSheet<RegionChoice>(
      context,
      RegionForm(region: _region),
    );
    _modalOpen = false;
    if (mounted && g == _generation && choice != null) {
      setState(() => _region = choice.region);
      _apply();
    }
  }

  Future<void> _pickDates() async {
    final g = _generation;
    _modalOpen = true;
    _ownerRoute = ModalRoute.of(context);
    final now = DateUtils.dateOnly(DateTime.now());
    final value = await showDateRangePicker(
      context: context,
      firstDate: _dates != null && _dates!.start.isBefore(now)
          ? _dates!.start
          : now,
      lastDate: DateTime(now.year + 2),
      initialDateRange: _dates,
    );
    _modalOpen = false;
    if (!mounted || g != _generation || value == null) return;
    if (value.end.difference(value.start) > const Duration(days: 30)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Escolha até 31 dias.')));
      return;
    }
    setState(() => _dates = value);
    _apply(updateFlows: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_opening) {
      _results.load();
      _flows.load();
    } else if ({
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    }.contains(state)) {
      _results.pause();
      _flows.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_account);
    _generation++;
    _results.pause();
    _flows.pause();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(explorePagerProvider);
    ref.watch(flowsPagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explorar'),
        actions: [
          IconButton(
            tooltip: 'Atualizar Explorar',
            onPressed: () {
              _catalog();
              _results.load();
              _flows.load();
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([_results, _flows]),
          builder: (context, _) => ListView(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // Product order: Flows immediately after the page header, before search.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Flows',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _open('/flows'),
                      child: const Text('Ver todos'),
                    ),
                  ],
                ),
              ),
              if (_flows.loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Carregando Flows',
                  ),
                ),
              if (_flows.issue != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ExperienceIssueView(
                    _flows.issue!,
                    retry: () => _flows.load(),
                  ),
                ),
              if (!_flows.loading &&
                  _flows.items.isEmpty &&
                  _flows.issue == null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Text(
                    _flows.expired ? 'Atualize para ver os Flows disponíveis.' : 'Nenhum Flow disponível nesta região e categoria agora.',
                  ),
                ),
              if (_flows.items.isNotEmpty)
                SizedBox(
                  height:
                      220 +
                      40 *
                          (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(
                            0,
                            2,
                          ),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _flows.items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                      final f = _flows.items[i];
                      return SizedBox(
                        width: 156,
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _open('/flows/${f.experience.id}'),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                FlowImage(f, compact: true),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Color(0xEE10121C),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  bottom: 12,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        f.experience.phase == 'LIVE'
                                            ? 'LIVE'
                                            : 'Em breve',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        f.experience.displayTitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: TextField(
                  controller: _search,
                  maxLength: 120,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => _apply(debounce: true, updateFlows: false),
                  onSubmitted: (_) => _results.load(),
                  decoration: const InputDecoration(
                    labelText: 'Buscar experiências',
                    hintText: 'Título ou descrição',
                    prefixIcon: Icon(Icons.search),
                    counterText: '',
                  ),
                ),
              ),
              if (_categories.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Todas'),
                        selected: _category == null,
                        onSelected: (_) {
                          setState(() => _category = null);
                          _apply();
                        },
                      ),
                      ..._categories.map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: ChoiceChip(
                            label: Text(c.name),
                            selected: _category == c.id,
                            onSelected: (v) {
                              setState(() => _category = v ? c.id : null);
                              _apply();
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('LIVE'),
                      selected: _phase == 'LIVE',
                      onSelected: (v) {
                        setState(() => _phase = v ? 'LIVE' : null);
                        _apply(updateFlows: false);
                      },
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.date_range, size: 18),
                      label: Text(
                        _dates == null ? 'Período' : 'Período selecionado',
                      ),
                      onPressed: _pickDates,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.place_outlined, size: 18),
                      label: Text(_region?.name ?? 'Região e distância'),
                      onPressed: _pickRegion,
                    ),
                    if (_dates != null ||
                        _phase != null ||
                        _region != null ||
                        _category != null)
                      ActionChip(
                        label: const Text('Limpar filtros'),
                        onPressed: () {
                          setState(() {
                            _category = null;
                            _phase = null;
                            _dates = null;
                            _region = null;
                          });
                          _apply();
                        },
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Experiências',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (_results.loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Buscando experiências',
                  ),
                ),
              if (_results.issue != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: ExperienceIssueView(
                    _results.issue!,
                    retry: () => _results.load(),
                  ),
                ),
              if (!_results.loading &&
                  _results.items.isEmpty &&
                  _results.issue == null)
                FlowStateView(
                  kind: FlowViewState.empty,
                  message: _results.expired
                      ? 'Os resultados expiraram. Atualize a busca.'
                      : 'Nenhuma experiência encontrada. Tente outra busca ou região.',
                  onRetry: _results.expired ? () => _results.load() : null,
                ),
              ..._results.items.map(
                (e) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _open('/experiences/${e.id}'),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 80,
                              height: 80,
                              child: ExperienceCover(e, compact: true),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.displayTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    ExperienceTime.display(
                                      e.input.startsAt,
                                      e.input.timezone,
                                    ),
                                  ),
                                  Text(e.input.venueName),
                                  ExperienceStatusBadge(e),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_results.cursor != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: OutlinedButton(
                    onPressed: _results.moreLoading
                        ? null
                        : () => _results.load(more: true),
                    child: Text(
                      _results.moreLoading
                          ? 'Carregando…'
                          : 'Mais experiências',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
