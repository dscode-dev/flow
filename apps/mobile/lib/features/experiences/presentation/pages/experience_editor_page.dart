import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../design/components.dart';
import '../../../../design/tokens.dart';
import '../../application/experience_controllers.dart';
import '../../data/cover_upload.dart';
import '../../data/experiences_repository.dart';
import '../../domain/experience.dart';
import '../../domain/experience_time.dart';
import '../../domain/location_search.dart';
import '../widgets/experience_widgets.dart';

class ExperienceEditorPage extends ConsumerStatefulWidget {
  const ExperienceEditorPage({super.key, this.id});
  final String? id;
  @override
  ConsumerState<ExperienceEditorPage> createState() =>
      _ExperienceEditorPageState();
}

class _ExperienceEditorPageState extends ConsumerState<ExperienceEditorPage> {
  late ExperienceEditorController _controller;
  final _form = GlobalKey<FormState>();
  int _step = 0;
  bool _allowPop = false;
  String _latitude = '', _longitude = '';
  int _revision = -1;
  static const _steps = ['Identidade', 'Quando', 'Onde', 'Acesso', 'Revisão'];
  int get _accountGeneration => ref.read(experienceAccessProvider).generation;
  bool _sameAccount(int generation) =>
      mounted && generation == _accountGeneration;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(experienceEditorProvider(widget.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _controller.load(widget.id);
        _recoverPicker();
      }
    });
  }

  Future<void> _recoverPicker() async {
    final generation = _accountGeneration;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final result = await ImagePicker().retrieveLostData();
      if (!mounted ||
          !_sameAccount(generation) ||
          result.files?.isNotEmpty != true) {
        return;
      }
      final use = await confirmExperienceAction(
        context,
        title: 'Seleção de imagem interrompida',
        message: 'O sistema recuperou uma imagem selecionada antes de reiniciar o aplicativo. Deseja usá-la nesta edição? Nenhum rascunho não salvo foi recuperado.',
        action: 'Usar imagem',
      );
      if (use && _sameAccount(generation)) await _selected(result.files!.first);
    } catch (_) {
      /* User can reopen the system picker. No automatic association. */
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _leave() async {
    if (_controller.changed &&
        !await confirmExperienceAction(
          context,
          title: 'Sair desta edição?',
          message: _controller.value.creationPending
              ? 'O salvamento ainda não foi confirmado. Resolva a tentativa pendente antes de sair para evitar criar uma duplicata. Sair descarta a chave desta tentativa; confira suas experiências antes de criar outra.'
              : 'Alterações não confirmadas serão descartadas. O último rascunho salvo no servidor continuará disponível.',
          action: 'Descartar edição',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/experiences');
        }
      }
    });
  }

  Future<void> _pickCover() async {
    final generation = _accountGeneration;
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
        // A 3072px square stays below the server's 12MP decoded-pixel budget.
        maxWidth: 3072,
        maxHeight: 3072,
        imageQuality: 90,
      );
      if (file != null && _sameAccount(generation)) await _selected(file);
    } catch (_) {
      _notice(
        'Não foi possível abrir a imagem. Permita a seleção nas configurações do aparelho ou escolha outro arquivo.',
      );
    }
  }

  Future<void> _selected(XFile file) async {
    final generation = _accountGeneration;
    try {
      final selection = await CoverSelection.read(file);
      if (_sameAccount(generation)) {
        await _controller.sendCover(selection, restart: true);
      }
    } catch (e) {
      _notice(safeExperienceIssue(e).message);
    }
  }

  Future<void> _pickZone() async {
    final generation = _accountGeneration;
    final zone = await showSearch<String>(
      context: context,
      delegate: _ZoneSearch(),
    );
    if (zone != null && zone.isNotEmpty && _sameAccount(generation)) {
      _controller.field('timezone', zone);
      if (_controller.value.input.startsAt != null) {
        _notice(
          'Os instantes foram preservados e agora aparecem no fuso escolhido. Se necessário, ajuste as horas.',
        );
      }
    }
  }

  Future<void> _pickInstant(bool start) async {
    final generation = _accountGeneration;
    final input = _controller.value.input;
    final zone = input.timezone;
    if (zone == null) {
      _notice('Escolha primeiro o fuso da experiência.');
      return;
    }
    final current =
        (start ? input.startsAt : input.endsAt) ??
        input.startsAt ??
        DateTime.now().toUtc();
    final local = ExperienceTime.local(current, zone);
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(local.year, local.month, local.day),
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted || !_sameAccount(generation)) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: local.hour, minute: local.minute),
    );
    if (time == null || !mounted || !_sameAccount(generation)) return;
    final candidates = ExperienceTime.candidates(
      zone,
      DateTime.utc(date.year, date.month, date.day, time.hour, time.minute),
    );
    if (candidates.isEmpty) {
      _notice(
        'Este horário não existe nesse fuso por uma mudança de horário de verão. Escolha outro horário.',
      );
      return;
    }
    DateTime? selected = candidates.singleOrNull;
    selected ??= await showDialog<DateTime>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Este horário acontece duas vezes'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Escolha o instante desejado. Nenhuma opção foi selecionada automaticamente.',
            ),
          ),
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, candidate),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${ExperienceTime.local(candidate, zone).timeZoneName} · ${candidate.toIso8601String()}',
                ),
              ),
            ),
        ],
      ),
    );
    if (selected != null && _sameAccount(generation)) {
      _controller.field(
        start ? 'starts_at' : 'ends_at',
        selected.toUtc().toIso8601String(),
      );
    }
  }

  void _pointChanged() {
    final lat = double.tryParse(_latitude.replaceAll(',', '.')),
        lng = double.tryParse(_longitude.replaceAll(',', '.'));
    _controller.field(
      'location',
      lat != null && lng != null && lat.isFinite && lng.isFinite
          ? GeoPoint(lat, lng).toJson()
          : null,
    );
  }

  Future<void> _searchLocation() async {
    final generation = _accountGeneration;
    final provider = ref.read(locationSearchProvider);
    if (!provider.available) return;
    final selected = await showSearch<LocationSuggestion>(
      context: context,
      delegate: _LocationSearch(provider),
    );
    if (selected == null || !mounted || !_sameAccount(generation)) return;
    final confirmed = await confirmExperienceAction(
      context,
      title: 'Confirmar local?',
      message:
          '${selected.label}\n${selected.point.latitude}, ${selected.point.longitude}',
      action: 'Usar este local',
    );
    if (confirmed && _sameAccount(generation)) {
      _latitude = selected.point.latitude.toString();
      _longitude = selected.point.longitude.toString();
      _controller.field('location', selected.point.toJson());
      _controller.field('address', selected.label);
      _controller.refreshFormFields();
    }
  }

  Future<void> _save({bool review = false}) async {
    if (!_controller.value.creationPending &&
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    final result = await _controller.save();
    if (!mounted || result == null) return;
    _notice(
      result.status == ExperienceStatus.draft
          ? 'Rascunho salvo no servidor.'
          : 'Alterações confirmadas no servidor.',
    );
    if (review) {
      setState(() => _allowPop = true);
      context.go('/experiences/${result.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(experienceEditorProvider(widget.id));
    return ValueListenableBuilder(
      valueListenable: _controller,
      builder: (context, state, _) {
        if (_revision != state.revision) {
          _revision = state.revision;
          _latitude = state.input.location?.latitude.toString() ?? '';
          _longitude = state.input.location?.longitude.toString() ?? '';
        }
        final published = state.saved?.status == ExperienceStatus.published;
        final enabled =
            !state.busy &&
            !state.creationPending &&
            state.issue?.code != 'version_conflict';
        final editable = state.saved == null || state.saved!.editable;
        return PopScope(
          canPop: _allowPop || !_controller.changed,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _leave();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                widget.id == null ? 'Criar experiência' : 'Editar experiência',
              ),
              leading: BackButton(onPressed: _leave),
            ),
            body: SafeArea(
              child: state.loading
                  ? const FlowStateView(
                      kind: FlowViewState.loading,
                      message: 'Retomando rascunho…',
                    )
                  : widget.id != null && state.saved == null
                  ? FlowStateView(
                      kind: FlowViewState.error,
                      message:
                          state.issue?.message ?? 'Experiência indisponível.',
                      onRetry: () => _controller.load(widget.id),
                    )
                  : !editable
                  ? const FlowStateView(
                      kind: FlowViewState.error,
                      message: 'Esta experiência não permite mais edição. Volte aos detalhes e atualize o estado.',
                    )
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Form(
                          key: _form,
                          child: Column(
                            children: [
                              Container(
                                height: 3,
                                decoration: const BoxDecoration(
                                  gradient: FlowColors.accent,
                                ),
                              ),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    for (var i = 0; i < _steps.length; i++)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: ChoiceChip(
                                          label: Text('${i + 1} ${_steps[i]}'),
                                          selected: _step == i,
                                          onSelected: (_) {
                                            if (_form.currentState
                                                    ?.validate() ??
                                                true) {
                                              setState(() => _step = i);
                                            }
                                          },
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: ListView(
                                  key: PageStorageKey('experience-step-$_step'),
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    12,
                                    24,
                                    24,
                                  ),
                                  children: [
                                    Text(
                                      _steps[_step],
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(switch (_step) {
                                      0 => 'Dê forma à sua ideia. Você pode salvar e continuar depois.',
                                      1 => 'A agenda usa o fuso da experiência, independente do aparelho.',
                                      2 => 'Escolha o local do encontro. Sua posição atual não é necessária.',
                                      3 => 'Decida quem poderá descobrir e acessar os detalhes.',
                                      _ => 'Confira os dados antes de salvar e publicar.',
                                    }),
                                    const SizedBox(height: 24),
                                    if (published)
                                      const Padding(
                                        padding: EdgeInsets.only(bottom: 16),
                                        child: Text(
                                          'Publicada: somente título, descrição, ticket e capa podem ser corrigidos antes do fim.',
                                        ),
                                      ),
                                    ..._section(state, enabled, published),
                                    if (state.issue != null)
                                      ExperienceIssueView(
                                        state.issue!,
                                        retry:
                                            state.issue!.code ==
                                                'version_conflict'
                                            ? _controller.compareLatest
                                            : null,
                                        actionLabel:
                                            'Comparar com a versão atual',
                                      ),
                                    if (state.latest case final latest?) ...[
                                      const Divider(height: 32),
                                      Text(
                                        'Versão atual no servidor',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge,
                                      ),
                                      ExperienceSummary(
                                        latest.input,
                                        redacted: latest.detailsRedacted,
                                      ),
                                      const SizedBox(height: 16),
                                      OutlinedButton(
                                        onPressed: state.busy
                                            ? null
                                            : () async {
                                                if (await confirmExperienceAction(
                                                      context,
                                                      title: 'Usar a versão do servidor?',
                                                      message: 'Sua edição local será descartada. Revise os dados atuais e edite novamente o que precisar.',
                                                      action:
                                                          'Usar versão atual',
                                                    ) &&
                                                    mounted) {
                                                  _controller.useLatest();
                                                }
                                              },
                                        child: const Text(
                                          'Descartar edição local e usar versão atual',
                                        ),
                                      ),
                                    ],
                                    if (state.creationPending)
                                      const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 16,
                                        ),
                                        child: Text(
                                          'Salvamento ainda não confirmado. Os campos estão preservados. Tente confirmar novamente com a mesma chave antes de editar.',
                                        ),
                                      ),
                                    if (state.busy) ...[
                                      const LinearProgressIndicator(
                                        semanticsLabel: 'Confirmando operação',
                                      ),
                                      const SizedBox(height: 8),
                                      Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          state.uploadStatus ?? 'Aguardando confirmação do servidor…',
                                        ),
                                      ),
                                      if (state.uploadStatus != null)
                                        TextButton(
                                          onPressed: _controller.cancelUpload,
                                          child: const Text(
                                            'Interromper envio',
                                          ),
                                        ),
                                    ],
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        8,
                                        16,
                                        12,
                                      ),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        alignment: WrapAlignment.end,
                                        children: [
                                          if (_step > 0)
                                            TextButton(
                                              onPressed: state.busy
                                                  ? null
                                                  : () =>
                                                        setState(() => _step--),
                                              child: const Text('Anterior'),
                                            ),
                                          OutlinedButton.icon(
                                            onPressed:
                                                state.busy ||
                                                    state.issue?.code ==
                                                        'version_conflict'
                                                ? null
                                                : () => _save(),
                                            icon: const Icon(
                                              Icons.save_outlined,
                                            ),
                                            label: Text(
                                              state.creationPending
                                                  ? 'Confirmar salvamento'
                                                  : published
                                                  ? 'Salvar alterações'
                                                  : 'Salvar rascunho',
                                            ),
                                          ),
                                          if (_step < 4)
                                            FilledButton(
                                              onPressed: state.busy
                                                  ? null
                                                  : () {
                                                      if (_form.currentState
                                                              ?.validate() ??
                                                          false) {
                                                        setState(() => _step++);
                                                      }
                                                    },
                                              child: const Text('Continuar'),
                                            ),
                                          if (_step == 4)
                                            FilledButton(
                                              onPressed:
                                                  state.busy ||
                                                      state.creationPending ||
                                                      state.issue?.code ==
                                                          'version_conflict'
                                                  ? null
                                                  : () => _save(review: true),
                                              child: Text(
                                                published
                                                    ? 'Salvar e ver detalhes'
                                                    : 'Salvar e revisar publicação',
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
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
        );
      },
    );
  }

  List<Widget> _section(
    ExperienceEditorState state,
    bool enabled,
    bool published,
  ) {
    final input = state.input;
    final unlocked = enabled && !published;
    switch (_step) {
      case 0:
        final categories = state.categories;
        final historical =
            input.categoryId != null &&
            !categories.any((c) => c.id == input.categoryId);
        return [
          _text(state, 'title', 'Título', enabled: enabled, max: 120),
          _text(
            state,
            'description',
            'Descrição',
            enabled: enabled,
            max: 5000,
            lines: 5,
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('${state.revision}:category:${categories.length}'),
            initialValue: input.categoryId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Categoria'),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Definir depois'),
              ),
              if (historical)
                DropdownMenuItem(
                  value: input.categoryId,
                  enabled: false,
                  child: Text('${input.categoryId} · indisponível'),
                ),
              for (final category in categories)
                DropdownMenuItem(
                  value: category.id,
                  child: Text(category.name),
                ),
            ],
            onChanged: unlocked
                ? (v) => _controller.field('category_id', v)
                : null,
          ),
          if (state.categoryIssue != null)
            ExperienceIssueView(
              state.categoryIssue!,
              retry: _controller.loadCategories,
            ),
          const SizedBox(height: 20),
          if (state.saved != null &&
              input.coverMediaId == state.saved!.input.coverMediaId)
            ExperienceCover(state.saved!),
          if (input.coverMediaId != null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Capa verificada pelo servidor. A imagem aparece após salvar a associação.',
              ),
            ),
          Text(
            'JPEG ou PNG · até 5 MiB · até 4096 px por lado e 12 MP',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: enabled ? _pickCover : null,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Escolher capa'),
              ),
              if (input.coverMediaId != null)
                TextButton(
                  onPressed: enabled
                      ? () => _controller.field('cover_media_id', null)
                      : null,
                  child: const Text('Remover capa'),
                ),
              if (_controller.upload != null && state.issue != null)
                TextButton(
                  onPressed: enabled
                      ? () => _controller.sendCover(
                          _controller.upload!.selection,
                          restart: {
                            'upload_expired',
                            'media_invalid',
                            'upload_not_pending',
                          }.contains(state.issue?.code),
                        )
                      : null,
                  child: Text(
                    state.issue?.code == 'upload_expired'
                        ? 'Autorizar novo envio'
                        : 'Tentar envio novamente',
                  ),
                ),
            ],
          ),
          if (state.uploadStatus != null) Text(state.uploadStatus!),
        ];
      case 1:
        return [
          OutlinedButton.icon(
            onPressed: unlocked ? _pickZone : null,
            icon: const Icon(Icons.public),
            label: Text(input.timezone ?? 'Escolher fuso IANA'),
          ),
          const SizedBox(height: 16),
          _dateRow(
            'Início',
            input.startsAt,
            input.timezone,
            unlocked,
            () => _pickInstant(true),
            () => _controller.field('starts_at', null),
          ),
          _dateRow(
            'Fim',
            input.endsAt,
            input.timezone,
            unlocked,
            () => _pickInstant(false),
            () => _controller.field('ends_at', null),
          ),
          if (input.startsAt != null && input.endsAt != null)
            Text(
              'Duração entre instantes: ${input.endsAt!.difference(input.startsAt!).inMinutes} minutos. Pode atravessar a meia-noite.',
            ),
          const SizedBox(height: 16),
          const Text(
            'Horários inexistentes são recusados; horários repetidos exigem escolher um dos instantes. O servidor confirma a validade da agenda ao salvar/publicar.',
          ),
        ];
      case 2:
        final search = ref.read(locationSearchProvider);
        return [
          if (search.available)
            OutlinedButton.icon(
              onPressed: unlocked ? _searchLocation : null,
              icon: const Icon(Icons.search),
              label: const Text('Buscar local'),
            )
          else
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Busca e mapa ainda não estão disponíveis. Informe o endereço e confirme as coordenadas do encontro.',
              ),
            ),
          _text(
            state,
            'venue_name',
            'Nome do local',
            enabled: unlocked,
            max: 160,
          ),
          _text(
            state,
            'address',
            'Endereço para exibição',
            enabled: unlocked,
            max: 300,
            lines: 2,
          ),
          TextFormField(
            key: ValueKey('${state.revision}:lat:$_revision'),
            initialValue: _latitude,
            enabled: unlocked,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(labelText: 'Latitude (−90 a 90)'),
            onChanged: (v) {
              _latitude = v;
              _pointChanged();
            },
            validator: (v) => _coordinateError(v, _longitude, 90),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey('${state.revision}:lng:$_revision'),
            initialValue: _longitude,
            enabled: unlocked,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: const InputDecoration(
              labelText: 'Longitude (−180 a 180)',
            ),
            onChanged: (v) {
              _longitude = v;
              _pointChanged();
            },
            validator: (v) => _coordinateError(v, _latitude, 180),
          ),
          const SizedBox(height: 16),
          if (input.location case final point?)
            OutlinedButton.icon(
              onPressed: () => _notice(
                'Local confirmado nesta edição: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}. Salve para persistir.',
              ),
              icon: const Icon(Icons.location_on_outlined),
              label: const Text('Conferir ponto escolhido'),
            ),
          const SizedBox(height: 16),
          const Text(
            'O ponto será exibido conforme a audiência escolhida. Evite divulgar endereço residencial ou outro local sensível sem intenção.',
          ),
        ];
      case 3:
        return [
          for (final v in ExperienceVisibility.values.where(
            (v) => v != ExperienceVisibility.unknown,
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  enabled: unlocked,
                  selected: input.visibility == v,
                  leading: Icon(
                    input.visibility == v
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(v.label),
                  subtitle: Text(v.explanation),
                  onTap: unlocked
                      ? () => _controller.field('visibility', v.wire)
                      : null,
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextFormField(
            key: ValueKey('${state.revision}:capacity'),
            initialValue: input.capacity?.toString() ?? '',
            enabled: unlocked,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Capacidade (opcional)',
              helperText: 'Informativa; não reserva vagas.',
            ),
            onChanged: (v) => _controller.field('capacity', int.tryParse(v)),
            validator: (v) {
              if (v == null || v.isEmpty) return null;
              final n = int.tryParse(v);
              return n == null || n < 1 || n > 1000000
                  ? 'Informe um inteiro entre 1 e 1.000.000.'
                  : null;
            },
          ),
          const SizedBox(height: 16),
          _text(
            state,
            'external_ticket_url',
            'Link externo de ingressos (opcional)',
            enabled: enabled,
            max: 2048,
            keyboard: TextInputType.url,
            validator: (v) =>
                v == null || v.isEmpty || safeTicketUri(v) != null ? null : 'Use HTTPS, domínio e porta padrão, sem credenciais ou fragmento.',
          ),
          const Text(
            'A compra ocorre fora do Flow. O link não comprova pagamento nem participação.',
          ),
        ];
      default:
        final category = state.categories
            .where((c) => c.id == input.categoryId)
            .firstOrNull
            ?.name;
        return [
          if (state.saved != null &&
              input.coverMediaId == state.saved!.input.coverMediaId)
            ExperienceCover(state.saved!),
          const SizedBox(height: 16),
          ExperienceSummary(input, categoryName: category),
          const Divider(height: 40),
          Text(
            state.dirty
                ? 'Há alterações ainda não salvas.'
                : 'Dados confirmados na última gravação.',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Para publicar, informe título, descrição, categoria disponível, início/fim, fuso, ponto e nome do local. A capa é opcional. O servidor valida a agenda, os dados e sua autorização.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Salvar não publica. A publicação exige confirmação na tela de detalhes.',
          ),
        ];
    }
  }

  Widget _text(
    ExperienceEditorState state,
    String field,
    String label, {
    required bool enabled,
    int? max,
    int lines = 1,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('${state.revision}:$field'),
      initialValue: state.input.toJson()[field] as String? ?? '',
      enabled: enabled,
      maxLength: max,
      maxLines: lines,
      keyboardType:
          keyboard ??
          (lines > 1 ? TextInputType.multiline : TextInputType.text),
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: lines > 1,
      ),
      validator: validator,
      onChanged: (v) => _controller.field(
        field,
        field == 'external_ticket_url' && v.isEmpty ? null : v,
      ),
    ),
  );
  String? _coordinateError(String? value, String other, int limit) {
    if ((value ?? '').isEmpty && other.isEmpty) return null;
    final n = double.tryParse((value ?? '').replaceAll(',', '.'));
    return n == null || !n.isFinite || n.abs() > limit
        ? 'Informe uma coordenada entre −$limit e $limit.'
        : null;
  }

  Widget _dateRow(
    String title,
    DateTime? date,
    String? zone,
    bool enabled,
    VoidCallback choose,
    VoidCallback clear,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Text(ExperienceTime.display(date, zone)),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: enabled ? choose : null,
              icon: const Icon(Icons.calendar_today_outlined),
              label: const Text('Escolher data e hora'),
            ),
            if (date != null)
              TextButton(
                onPressed: enabled ? clear : null,
                child: const Text('Limpar'),
              ),
          ],
        ),
      ],
    ),
  );
}

class _ZoneSearch extends SearchDelegate<String> {
  _ZoneSearch()
    : super(searchFieldLabel: 'Buscar fuso IANA, ex.: America/Recife');
  @override
  List<Widget> buildActions(BuildContext context) => [
    IconButton(
      tooltip: 'Limpar busca',
      onPressed: () {
        query = '';
      },
      icon: const Icon(Icons.clear),
    ),
  ];
  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => close(context, ''));
  Widget _results(BuildContext context) {
    final zones = ExperienceTime.zones
        .where((v) => v.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return ListView.builder(
      itemCount: zones.length,
      itemBuilder: (context, index) => ListTile(
        title: Text(zones[index]),
        onTap: () => close(context, zones[index]),
      ),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);
}

class _LocationSearch extends SearchDelegate<LocationSuggestion> {
  _LocationSearch(this.provider)
    : super(searchFieldLabel: 'Buscar endereço em outra cidade');
  final LocationSearch provider;
  String? _last;
  Future<List<LocationSuggestion>>? _request;
  @override
  List<Widget> buildActions(BuildContext context) => [];
  @override
  Widget buildLeading(BuildContext context) =>
      BackButton(onPressed: () => Navigator.pop(context));
  @override
  Widget buildSuggestions(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Text('Digite um endereço e toque em buscar.'),
  );
  @override
  Widget buildResults(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    if (_last != query) {
      _last = query;
      _request = provider.search(query.trim());
    }
    return FutureBuilder(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const FlowStateView(
            kind: FlowViewState.error,
            message: 'A busca de locais está indisponível. Informe o ponto manualmente.',
          );
        }
        if (!snapshot.hasData) {
          return const FlowStateView(
            kind: FlowViewState.loading,
            message: 'Buscando locais…',
          );
        }
        final results = snapshot.data!;
        if (results.isEmpty) {
          return const FlowStateView(
            kind: FlowViewState.empty,
            message: 'Nenhum local encontrado. Você pode informar o ponto manualmente.',
          );
        }
        return ListView(
          children: [
            for (final suggestion in results)
              ListTile(
                title: Text(suggestion.label),
                onTap: () => close(context, suggestion),
              ),
          ],
        );
      },
    );
  }
}
