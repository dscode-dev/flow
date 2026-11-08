import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/components.dart';
import '../experiences/application/experience_controllers.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_time.dart';
import '../experiences/presentation/widgets/experience_widgets.dart';
import '../home/home_controller.dart';
import '../home/home_page.dart' show RegionForm, RegionChoice;
import 'radar_config.dart';
import 'radar_controller.dart';
import 'radar_location.dart';
import 'radar_map.dart';
import 'radar_model.dart';

class RadarPage extends ConsumerStatefulWidget {
  const RadarPage({super.key});
  @override
  ConsumerState<RadarPage> createState() => _RadarPageState();
}

class _RadarPageState extends ConsumerState<RadarPage>
    with WidgetsBindingObserver {
  late RadarController _controller;
  late RadarLocation _location;
  late ExperienceAccess _access;
  Widget? _canvas;
  int _mapRevision = 0;
  bool _locating = false;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(radarControllerProvider);
    _location = ref.read(radarLocationProvider);
    _access = ref.read(experienceAccessProvider);
    _access.addListener(_accountChanged);
    WidgetsBinding.instance.addObserver(this);
    final region = ref.read(homeControllerProvider).region;
    _controller.camera ??= region != null
        ? RadarCamera(region.point, 10)
        : ref.read(radarConfigProvider).initial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.resume();
        _controller.catalog();
      }
    });
  }

  bool _modalOpen = false;
  ModalRoute<dynamic>? _ownerRoute;
  Future<T?> _sheet<T>(Widget child) async {
    _ownerRoute = ModalRoute.of(context);
    _modalOpen = true;
    try {
      return await showFlowSheet<T>(context, child);
    } finally {
      _modalOpen = false;
    }
  }

  void _accountChanged() {
    _cancelLocation();
    if (mounted && _modalOpen && _ownerRoute?.isActive == true) {
      final owner = _ownerRoute;
      Navigator.of(context)
          .popUntil((route) => identical(route, owner) || route.isFirst);
    }
    if (mounted) {
      setState(() {
        _canvas = null;
        _mapRevision++;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _access.ownerId != null) {
          _controller.resume();
          _controller.catalog();
        }
      });
    }
  }

  void _cancelLocation() {
    _location.cancel();
    if (mounted && _locating) setState(() => _locating = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (ModalRoute.of(context)?.isCurrent ?? false) _controller.resume();
    } else if ({
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    }.contains(state)) {
      _cancelLocation();
      _controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _access.removeListener(_accountChanged);
    _location.cancel();
    _controller.pause();
    super.dispose();
  }

  Future<void> _open(String path) async {
    _cancelLocation();
    _controller.pause();
    await context.push(path);
    if (mounted) _controller.resume();
  }

  Future<void> _locate() async {
    final generation = _access.generation;
    _ownerRoute = ModalRoute.of(context);
    _modalOpen = true;
    final agree = await confirmExperienceAction(
      context,
      title: 'Centralizar na sua região?',
      message: 'Vamos usar uma leitura aproximada da localização durante o uso para mover o mapa. Não guardamos deslocamentos. Você pode continuar explorando sem permitir.',
      action: 'Usar localização aproximada',
    );
    _modalOpen = false;
    if (!mounted || !agree || generation != _access.generation) return;
    setState(() => _locating = true);
    try {
      final point = await _location.locate();
      if (mounted && generation == _access.generation) {
        _controller.center(point);
      }
    } catch (e) {
      if (!mounted || generation != _access.generation) return;
      final code = safeExperienceIssue(e).code;
      if (code != 'canceled') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (code) {
              'location_denied' => 'Localização não autorizada. Explore pelo mapa ou escolha uma região.',
              'location_disabled' => 'O serviço de localização está desativado. Você pode continuar pelo mapa.',
              'location_timeout' => 'Não foi possível obter a região a tempo. Tente novamente ou use o mapa.',
              _ => 'Localização indisponível. A descoberta pelo mapa continua disponível.',
            }),
          ),
        );
      }
    } finally {
      if (mounted && generation == _access.generation) {
        setState(() => _locating = false);
      }
    }
  }

  Future<void> _region() async {
    final generation = _access.generation;
    final result = await _sheet<RegionChoice>(
      RegionForm(
        region: ref.read(homeControllerProvider).region,
        defaultRadiusM: 25000,
      ),
    );
    if (!mounted ||
        generation != _access.generation ||
        result?.region == null) {
      return;
    }
    final region = result!.region!;
    final old = _controller.filters;
    _controller.filters = RadarFilters(
      category: old.category,
      phase: old.phase,
      from: old.from,
      until: old.until,
      center: region.point,
      radiusM: region.radiusM,
    );
    _controller.center(region.point, zoom: 10);
  }

  Future<void> _filters() async {
    final generation = _access.generation;
    await _controller.catalog();
    if (!mounted || generation != _access.generation) return;
    final result = await _sheet<RadarFilters>(
      RadarFilterForm(
        categories: _controller.categories,
        current: _controller.filters,
        center: _controller.camera?.center,
      ),
    );
    if (mounted && generation == _access.generation && result != null) {
      await _controller.setFilters(result);
    }
  }

  Future<void> _select(String id) async {
    final generation = _access.generation;
    await _controller.refresh(force: true);
    if (!mounted ||
        generation != _access.generation ||
        _controller.value.document?.items.any((m) => m.id == id) != true) {
      return;
    }
    _controller.select(id);
    bool open = true;
    void guard() {
      if (open &&
          mounted &&
          (_access.generation != generation ||
              _controller.value.document?.items.any((m) => m.id == id) !=
                  true)) {
        open = false;
        Navigator.of(context).pop();
      }
    }

    _controller.addListener(guard);
    String? detail;
    try {
      detail = await _sheet<String>(RadarPreview(id: id));
    } finally {
      open = false;
      _controller.removeListener(guard);
      _controller.select(null);
    }
    if (!mounted || generation != _access.generation) return;
    if (detail != null) await _open('/experiences/$detail');
  }

  Future<void> _list() async {
    final items = _controller.value.document?.items ?? [];
    final id = await _sheet<String>(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Experiências desta área',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Lista dos marcadores recebidos; refine o mapa se o limite foi atingido.',
          ),
          for (final m in items)
            ListTile(
              title: Text(m.title),
              subtitle: Text(
                '${m.categoryName} · ${ExperienceTime.display(m.startsAt, m.timezone)}',
              ),
              onTap: () => Navigator.pop(context, m.id),
            ),
        ],
      ),
    );
    if (mounted && id != null) await _select(id);
  }

  void _info() {
    final m = _controller.metrics;
    _sheet<void>(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Sobre o Radar', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Pins representam experiências públicas recebidas da API. Clusters contam apenas esses pins, não todas as experiências da região. A borda rosa indica que já começaram.',
          ),
          const SizedBox(height: 12),
          const Text(
            'O mapa usa Mapbox e transmite ao provedor recursos da área exibida e informações técnicas. A atribuição ⓘ do próprio mapa mantém os créditos e a opção de exclusão da telemetria. A localização é opcional e usada em uma única leitura aproximada, sem rastreamento.',
          ),
          if (m.queryMs != null)
            Text(
              'Última consulta: ${m.queryMs} ms · ${m.returned} marcadores.',
            ),
          if (m.pinsFrameMs != null)
            Text('Fonte ao próximo frame completo: ${m.pinsFrameMs} ms.'),
          Text(
            'Consultas canceladas: ${m.canceled}; respostas obsoletas: ${m.obsolete}; erros de mapa: ${m.mapErrors}. Sem envio destes diagnósticos a analytics.',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(radarControllerProvider);
    final config = ref.watch(radarConfigProvider);
    if (config.available) {
      _canvas ??= ref.read(radarMapBuilderProvider)(
        _controller,
        config,
        _select,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radar'),
        actions: [
          IconButton(
            tooltip: 'Sobre o Radar',
            onPressed: _info,
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: 'Atualizar área',
            onPressed: config.available
                ? () => _controller.refresh(force: true)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: () => context.go('/app'),
              icon: const Icon(Icons.home_outlined),
              label: const Text('Início'),
            ),
            TextButton.icon(
              onPressed: () => _open('/experiences'),
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('Minhas experiências'),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: !config.available
            ? const FlowStateView(
                kind: FlowViewState.empty,
                message: 'Radar indisponível: a configuração pública do Mapbox ainda não está pronta. O restante do Flow continua disponível.',
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _filters,
                          icon: const Icon(Icons.tune),
                          label: const Text('Filtros'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _region,
                          icon: const Icon(Icons.place_outlined),
                          label: const Text('Região'),
                        ),
                        IconButton(
                          tooltip: 'Usar minha região aproximada',
                          onPressed: _locating ? null : _locate,
                          icon: const Icon(Icons.my_location),
                        ),
                        IconButton(
                          tooltip: 'Ampliar mapa',
                          onPressed: () {
                            final c = _controller.camera;
                            if (c != null) {
                              _controller.center(c.center, zoom: c.zoom + 1);
                            }
                          },
                          icon: const Icon(Icons.add),
                        ),
                        IconButton(
                          tooltip: 'Reduzir mapa',
                          onPressed: () {
                            final c = _controller.camera;
                            if (c != null) {
                              _controller.center(c.center, zoom: c.zoom - 1);
                            }
                          },
                          icon: const Icon(Icons.remove),
                        ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder(
                    valueListenable: _controller,
                    builder: (context, state, _) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          if (_controller.filters.active)
                            TextButton(
                              onPressed: () =>
                                  _controller.setFilters(const RadarFilters()),
                              child: const Text('Limpar filtros'),
                            ),
                          if (state.loading)
                            const LinearProgressIndicator(
                              semanticsLabel:
                                  'Consultando experiências desta área',
                            ),
                          if (_controller.mapLoading)
                            const Text('Carregando mapa…'),
                          if (state.mapError != null) Text(state.mapError!),
                          if (state.mapError != null)
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _canvas = null;
                                  _mapRevision++;
                                });
                                _controller.mapReloading();
                              },
                              child: const Text('Recarregar mapa'),
                            ),
                          if (state.issue != null)
                            Text(
                              state.issue!.code == 'radar_area_too_large'
                                  ? 'Aproxime o mapa para buscar nesta região.'
                                  : state.issue!.message,
                            ),
                          if (state.issue != null &&
                              state.issue!.code != 'radar_area_too_large')
                            TextButton(
                              onPressed: () => _controller.refresh(force: true),
                              child: const Text('Tentar novamente'),
                            ),
                          if (state.expired)
                            TextButton(
                              onPressed: () => _controller.refresh(force: true),
                              child: const Text(
                                'Atualizar experiências desta área',
                              ),
                            ),
                          if (state.document?.truncated == true)
                            const Text(
                              'Há mais experiências nesta área. Aproxime ou refine os filtros; os clusters contam somente os pins recebidos.',
                            ),
                          if (state.document != null &&
                              !state.document!.truncated &&
                              state.document!.items.isEmpty)
                            const Text(
                              'Nenhuma experiência pública encontrada nesta área e filtros.',
                            ),
                          if (state.document?.items.isNotEmpty == true)
                            TextButton.icon(
                              onPressed: _list,
                              icon: const Icon(Icons.list),
                              label: const Text('Ver experiências da área'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey(_mapRevision),
                      child: _canvas!,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class RadarPreview extends ConsumerStatefulWidget {
  const RadarPreview({super.key, required this.id});
  final String id;
  @override
  ConsumerState<RadarPreview> createState() => _RadarPreviewState();
}

class _RadarPreviewState extends ConsumerState<RadarPreview> {
  late ExperienceDetailController _detail;
  String? _checkedCover;
  void _coverDenied() {
    final e = _detail.value.experience;
    if (e == null) return;
    final key = '${e.id}:${e.version}:${e.input.coverMediaId}';
    if (_checkedCover != key) {
      _checkedCover = key;
      _detail.load();
    }
  }

  @override
  void initState() {
    super.initState();
    _detail = ref.read(experienceDetailProvider(widget.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _detail.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(experienceDetailProvider(widget.id));
    return ValueListenableBuilder(
      valueListenable: _detail,
      builder: (context, state, _) {
        final e = state.experience;
        if (state.loading) {
          return const FlowStateView(
            kind: FlowViewState.loading,
            message: 'Conferindo experiência…',
          );
        }
        if (state.issue != null) {
          return ExperienceIssueView(state.issue!, retry: _detail.load);
        }
        if (e == null) return const SizedBox.shrink();
        if (e.detailsRedacted ||
            e.status != ExperienceStatus.published ||
            e.input.visibility != ExperienceVisibility.public ||
            e.phase == 'ENDED') {
          return const Text(
            'Esta experiência não está mais disponível no Radar. Atualize a área.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Center(child: Icon(Icons.drag_handle)),
            ExperienceCover(e, onAccessDenied: _coverDenied),
            const SizedBox(height: 12),
            Text(e.displayTitle, style: Theme.of(context).textTheme.titleLarge),
            Text(
              ref
                      .read(radarControllerProvider)
                      .categories
                      .where((c) => c.id == e.input.categoryId)
                      .firstOrNull
                      ?.name ??
                  e.input.categoryId ??
                  '',
            ),
            Text(ExperienceTime.display(e.input.startsAt, e.input.timezone)),
            Text(e.input.venueName),
            ExperienceStatusBadge(e),
            if (e.input.externalTicketUrl != null)
              const Text('Ingresso em site externo'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, e.id),
              child: const Text('Ver detalhes'),
            ),
          ],
        );
      },
    );
  }
}

class RadarFilterForm extends StatefulWidget {
  const RadarFilterForm({
    super.key,
    required this.categories,
    required this.current,
    this.center,
  });
  final List<ExperienceCategory> categories;
  final RadarFilters current;
  final GeoPoint? center;
  @override
  State<RadarFilterForm> createState() => _RadarFilterFormState();
}

class _RadarFilterFormState extends State<RadarFilterForm> {
  String? _category, _phase;
  DateTimeRange? _dates;
  bool _distance = false;
  double _radius = 25;
  @override
  void initState() {
    super.initState();
    _category = widget.current.category;
    _phase = widget.current.phase;
    _distance = widget.current.center != null;
    _radius = (widget.current.radiusM ?? 25000) / 1000;
    if (widget.current.from != null) {
      _dates = DateTimeRange(
        start: widget.current.from!.toLocal(),
        end: widget.current.until!
            .subtract(const Duration(microseconds: 1))
            .toLocal(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Filtros do Radar', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (widget.categories.isEmpty)
        const Text(
          'Catálogo indisponível. Tente reabrir os filtros; nenhuma categoria foi inventada.',
        ),
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Todas'),
            selected: _category == null,
            onSelected: (_) => setState(() => _category = null),
          ),
          for (final c in widget.categories)
            ChoiceChip(
              label: Text(c.name),
              selected: _category == c.id,
              onSelected: (_) => setState(() => _category = c.id),
            ),
        ],
      ),
      const SizedBox(height: 12),
      FilterChip(
        label: const Text('Acontecendo agora'),
        selected: _phase == 'LIVE',
        onSelected: (v) => setState(() => _phase = v ? 'LIVE' : null),
      ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () async {
          final now = DateTime.now();
          final range = await showDateRangePicker(
            context: context,
            firstDate:
                _dates != null &&
                    _dates!.start.isBefore(DateUtils.dateOnly(now))
                ? DateUtils.dateOnly(_dates!.start)
                : DateUtils.dateOnly(now),
            lastDate: now.add(const Duration(days: 366)),
            initialDateRange: _dates,
            helpText: 'Período de até 31 dias',
          );
          if (!context.mounted || range == null) return;
          final end = DateTime(
            range.end.year,
            range.end.month,
            range.end.day + 1,
          );
          final start = DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          );
          if (end.toUtc().difference(start.toUtc()) >
              const Duration(days: 31)) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Escolha um período de até 31 dias.'),
              ),
            );
            return;
          }
          setState(() => _dates = DateTimeRange(start: start, end: range.end));
        },
        icon: const Icon(Icons.date_range),
        label: Text(
          _dates == null
              ? 'Escolher período'
              : '${_dates!.start.day}/${_dates!.start.month} até ${_dates!.end.day}/${_dates!.end.month}',
        ),
      ),
      if (_dates != null)
        TextButton(
          onPressed: () => setState(() => _dates = null),
          child: const Text('Remover período'),
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Limitar distância ao centro do mapa'),
        subtitle: const Text('Centro aproximado, não sua posição atual.'),
        value: _distance,
        onChanged: widget.center == null
            ? null
            : (v) => setState(() => _distance = v),
      ),
      if (_distance) ...[
        Text('Raio: ${_radius.round()} km'),
        Slider(
          value: _radius.clamp(1, 100),
          min: 1,
          max: 100,
          divisions: 99,
          onChanged: (v) => setState(() => _radius = v),
        ),
      ],
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () {
          final range = _dates;
          Navigator.pop(
            context,
            RadarFilters(
              category: _category,
              phase: _phase,
              from: range == null
                  ? null
                  : DateTime(
                      range.start.year,
                      range.start.month,
                      range.start.day,
                    ).toUtc(),
              until: range == null
                  ? null
                  : DateTime(
                      range.end.year,
                      range.end.month,
                      range.end.day + 1,
                    ).toUtc(),
              center: _distance ? widget.center : null,
              radiusM: _distance ? (_radius * 1000).round() : null,
            ),
          );
        },
        child: const Text('Aplicar filtros'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, const RadarFilters()),
        child: const Text('Limpar filtros'),
      ),
    ],
  );
}
