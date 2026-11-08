import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_state.dart';
import '../../../../design/components.dart';
import '../../application/experience_controllers.dart';
import '../../data/experiences_repository.dart';
import '../../domain/experience.dart';
import '../../domain/experience_time.dart';
import '../widgets/experience_widgets.dart';

class MyExperiencesPage extends ConsumerStatefulWidget {
  const MyExperiencesPage({super.key});
  @override
  ConsumerState<MyExperiencesPage> createState() => _MyExperiencesPageState();
}

class _MyExperiencesPageState extends ConsumerState<MyExperiencesPage>
    with WidgetsBindingObserver {
  late ExperiencesListController _controller;
  List<ExperienceCategory> _categories = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(experiencesListProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.load();
        _loadCategories();
      }
    });
  }

  Future<void> _loadCategories() async {
    try {
      final result = await ref.read(experiencesRepositoryProvider).categories();
      if (mounted) {
        setState(() => _categories = result);
      }
    } catch (_) {
      /* IDs remain accurate when catalog is unavailable. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) {
      _controller.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(experiencesListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas experiências'),
        actions: [
          IconButton(
            tooltip: 'Sair da conta',
            onPressed: () => ref.read(authControllerProvider).signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open('/experiences/new'),
        icon: const Icon(Icons.add),
        label: const Text('Criar'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, state, _) => RefreshIndicator(
                onRefresh: () => _controller.load(),
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Do plano ao encontro.',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Crie, retome ideias e acompanhe o que você publicou.',
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          children: [
                            for (final status in <ExperienceStatus?>[
                              null,
                              ...ExperienceStatus.values.where(
                                (s) => s != ExperienceStatus.unknown,
                              ),
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: FilterChip(
                                  label: Text(status?.label ?? 'Todas'),
                                  selected: state.status == status,
                                  onSelected: (_) => _controller.load(
                                    changeFilter: true,
                                    status: status,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (state.items.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: state.loading
                            ? const FlowStateView(
                                kind: FlowViewState.loading,
                                message: 'Buscando suas experiências…',
                              )
                            : state.issue != null
                            ? FlowStateView(
                                kind: FlowViewState.error,
                                message: state.issue!.message,
                                onRetry: () => _controller.load(),
                              )
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  32,
                                  24,
                                  100,
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.auto_awesome_outlined,
                                      size: 48,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      state.status == null
                                          ? 'Uma ideia pode virar um encontro.'
                                          : 'Nenhuma experiência neste estado.',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge,
                                    ),
                                    const SizedBox(height: 16),
                                    FilledButton.icon(
                                      onPressed: () =>
                                          _open('/experiences/new'),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Criar experiência'),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    if (state.items.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        sliver: SliverList.builder(
                          itemCount: state.items.length,
                          itemBuilder: (context, index) =>
                              _row(state.items[index]),
                        ),
                      ),
                    if (state.items.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 100),
                          child: Column(
                            children: [
                              if (state.issue != null)
                                ExperienceIssueView(
                                  state.issue!,
                                  retry: () => _controller.load(more: true),
                                ),
                              if (state.loading)
                                const CircularProgressIndicator(),
                              if (state.nextCursor != null && !state.loading)
                                TextButton(
                                  onPressed: () => _controller.load(more: true),
                                  child: const Text('Carregar mais'),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(Experience e) {
    final category =
        _categories
            .where((c) => c.id == e.input.categoryId)
            .firstOrNull
            ?.name ??
        e.input.categoryId;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open('/experiences/${e.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 56, child: ExperienceCover(e, compact: true)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (category != null)
                      Text(
                        category,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    const SizedBox(height: 6),
                    Text(
                      ExperienceTime.display(
                        e.input.startsAt,
                        e.input.timezone,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    ExperienceStatusBadge(e),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Ações da experiência',
                onSelected: (action) => _open(
                  '/experiences/${e.id}${action == 'edit' ? '/edit' : ''}',
                ),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'detail',
                    child: Text('Ver detalhes'),
                  ),
                  if (e.editable)
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(
                        e.status == ExperienceStatus.draft
                            ? 'Retomar rascunho'
                            : 'Editar',
                      ),
                    ),
                  if (e.status == ExperienceStatus.draft)
                    const PopupMenuItem(
                      value: 'review',
                      child: Text('Revisar e publicar'),
                    ),
                  if (e.cancelSuggested)
                    const PopupMenuItem(
                      value: 'cancel',
                      child: Text('Gerenciar cancelamento'),
                    ),
                  if (e.archiveSuggested)
                    const PopupMenuItem(
                      value: 'archive',
                      child: Text('Gerenciar arquivo'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
