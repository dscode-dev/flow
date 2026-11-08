import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/cover_upload.dart';
import '../data/experiences_repository.dart';
import '../domain/experience.dart';
import '../domain/experience_issue.dart';

AuthIssue safeExperienceIssue(Object e) =>
    e is AuthIssue ? e : const ExperienceIssue('unexpected');

class ExperiencesListState {
  const ExperiencesListState({
    this.items = const [],
    this.loading = false,
    this.nextCursor,
    this.issue,
    this.status,
    this.loaded = false,
  });
  final List<Experience> items;
  final bool loading, loaded;
  final String? nextCursor;
  final AuthIssue? issue;
  final ExperienceStatus? status;
}

class ExperiencesListController extends ValueNotifier<ExperiencesListState> {
  ExperiencesListController(this.repository, this.access)
    : super(const ExperiencesListState()) {
    access.addListener(_accountChanged);
  }
  final ExperiencesRepository repository;
  final ExperienceAccess access;
  CancelToken? _cancel;
  int _generation = 0;
  bool _disposed = false;
  void _accountChanged() {
    _cancel?.cancel();
    _generation++;
    if (!_disposed) value = const ExperiencesListState();
  }

  Future<void> load({
    bool more = false,
    ExperienceStatus? status,
    bool changeFilter = false,
  }) async {
    if (more && (value.loading || value.nextCursor == null)) return;
    _cancel?.cancel();
    final cancel = _cancel = CancelToken();
    final g = ++_generation;
    final filter = changeFilter ? status : value.status;
    final previous = more ? value.items : <Experience>[];
    final cursor = more ? value.nextCursor : null;
    value = ExperiencesListState(
      items: previous,
      loading: true,
      status: filter,
      nextCursor: cursor,
      loaded: more,
    );
    try {
      final result = await repository.mine(
        cursor: cursor,
        status: filter,
        cancel: cancel,
      );
      if (_disposed || g != _generation) return;
      final items = <String, Experience>{
        for (final e in previous) e.id: e,
        for (final e in result.items) e.id: e,
      };
      value = ExperiencesListState(
        items: items.values.toList(),
        nextCursor: result.nextCursor,
        status: filter,
        loaded: true,
      );
    } catch (e) {
      if (_disposed || g != _generation) return;
      final issue = safeExperienceIssue(e);
      // A failed authorization must never leave an old page visible.
      value = ExperiencesListState(
        items: {401, 403, 404}.contains(issue.status) ? [] : previous,
        nextCursor: cursor,
        status: filter,
        loaded: true,
        issue: issue,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancel?.cancel();
    access.removeListener(_accountChanged);
    super.dispose();
  }
}

class ExperienceDetailState {
  const ExperienceDetailState({
    this.experience,
    this.issue,
    this.loading = false,
    this.busy = false,
  });
  final Experience? experience;
  final AuthIssue? issue;
  final bool loading, busy;
}

class ExperienceDetailController extends ValueNotifier<ExperienceDetailState> {
  ExperienceDetailController(this.repository, this.access, this.id)
    : super(const ExperienceDetailState()) {
    access.addListener(_clear);
  }
  final ExperiencesRepository repository;
  final ExperienceAccess access;
  final String id;
  CancelToken? _cancel;
  int _generation = 0;
  bool _disposed = false;
  void _clear() {
    _generation++;
    _cancel?.cancel();
    if (!_disposed) value = const ExperienceDetailState();
  }

  Future<void> load() async {
    if (value.busy) return;
    _cancel?.cancel();
    final c = _cancel = CancelToken();
    final g = ++_generation;
    value = const ExperienceDetailState(loading: true);
    try {
      final e = await repository.get(id, cancel: c);
      if (!_disposed && g == _generation) {
        value = ExperienceDetailState(experience: e);
      }
    } catch (e) {
      if (!_disposed && g == _generation) {
        value = ExperienceDetailState(issue: safeExperienceIssue(e));
      }
    }
  }

  Future<void> transition(String action) async {
    final current = value.experience;
    if (current == null || value.busy) return;
    final c = _cancel = CancelToken();
    final g = ++_generation;
    value = ExperienceDetailState(experience: current, busy: true);
    try {
      final result = await repository.transition(current, action, cancel: c);
      if (!_disposed && g == _generation) {
        value = ExperienceDetailState(experience: result);
      }
    } catch (e) {
      if (_disposed || g != _generation) return;
      final issue = safeExperienceIssue(e);
      value = ExperienceDetailState(
        experience: {401, 403, 404}.contains(issue.status) ? null : current,
        issue: issue,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _clear();
    access.removeListener(_clear);
    super.dispose();
  }
}

class ExperienceEditorState {
  const ExperienceEditorState({
    this.input = const ExperienceInput(),
    this.saved,
    this.latest,
    this.loading = false,
    this.busy = false,
    this.dirty = false,
    this.issue,
    this.categories = const [],
    this.categoryIssue,
    this.uploadStatus,
    this.revision = 0,
    this.creationPending = false,
  });
  final ExperienceInput input;
  final Experience? saved, latest;
  final bool loading, busy, dirty, creationPending;
  final AuthIssue? issue, categoryIssue;
  final List<ExperienceCategory> categories;
  final String? uploadStatus;
  final int revision;
  ExperienceEditorState copy({
    ExperienceInput? input,
    Experience? saved,
    Experience? latest,
    bool? loading,
    bool? busy,
    bool? dirty,
    AuthIssue? issue,
    List<ExperienceCategory>? categories,
    AuthIssue? categoryIssue,
    String? uploadStatus,
    int? revision,
    bool? creationPending,
    bool clearLatest = false,
  }) => ExperienceEditorState(
    input: input ?? this.input,
    saved: saved ?? this.saved,
    latest: clearLatest ? null : latest ?? this.latest,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    dirty: dirty ?? this.dirty,
    issue: issue,
    categories: categories ?? this.categories,
    categoryIssue: categoryIssue,
    uploadStatus: uploadStatus,
    revision: revision ?? this.revision,
    creationPending: creationPending ?? this.creationPending,
  );
}

class ExperienceEditorController extends ValueNotifier<ExperienceEditorState> {
  ExperienceEditorController(this.repository, this.access)
    : super(const ExperienceEditorState()) {
    access.addListener(_clear);
  }
  final ExperiencesRepository repository;
  final ExperienceAccess access;
  CancelToken _cancel = CancelToken();
  CancelToken _categoryCancel = CancelToken();
  final Dio _storage = createStorageTransport();
  ExperienceInput? _createInput;
  String? _createKey;
  String? _createdId;
  DateTime? _createUntil;
  CoverUpload? upload;
  int _generation = 0;
  bool _disposed = false;
  Future<Experience?>? _saveFlight;
  void _clear() {
    _generation++;
    _cancel.cancel();
    _categoryCancel.cancel();
    _createInput = null;
    _createKey = null;
    _createdId = null;
    _createUntil = null;
    upload = null;
    if (!_disposed) value = ExperienceEditorState(revision: value.revision + 1);
  }

  void change(ExperienceInput input) {
    if (value.busy || value.loading || value.creationPending) return;
    value = value.copy(
      input: input,
      dirty: true,
      issue: value.issue?.code == 'version_conflict' ? value.issue : null,
      categoryIssue: value.categoryIssue,
    );
  }

  void field(String name, dynamic fieldValue) => change(
    ExperienceInput.fromJson({...value.input.toJson(), name: fieldValue}),
  );
  void refreshFormFields() {
    value = value.copy(revision: value.revision + 1, dirty: value.dirty);
  }

  Future<void> load(String? id) async {
    if (id == null) {
      await loadCategories();
      return;
    }
    final g = ++_generation;
    _cancel.cancel();
    _cancel = CancelToken();
    value = value.copy(loading: true);
    final catalog = loadCategories();
    try {
      final e = await repository.get(id, cancel: _cancel);
      if (!_disposed && g == _generation) {
        value = value.copy(
          input: e.input,
          saved: e,
          loading: false,
          dirty: false,
          revision: value.revision + 1,
        );
      }
    } catch (e) {
      if (!_disposed && g == _generation) {
        value = value.copy(loading: false, issue: safeExperienceIssue(e));
      }
    }
    await catalog;
  }

  Future<void> loadCategories() async {
    final g = _generation;
    _categoryCancel.cancel();
    _categoryCancel = CancelToken();
    try {
      final categories = await repository.categories(cancel: _categoryCancel);
      if (!_disposed && g == _generation) {
        value = value.copy(categories: categories, issue: value.issue);
      }
    } catch (e) {
      if (!_disposed && g == _generation) {
        value = value.copy(
          categoryIssue: safeExperienceIssue(e),
          issue: value.issue,
        );
      }
    }
  }

  Future<Experience?> save() =>
      _saveFlight ??= _save().whenComplete(() => _saveFlight = null);
  Future<Experience?> _save() async {
    if (value.busy ||
        value.loading ||
        value.latest != null ||
        value.issue?.code == 'version_conflict') {
      return null;
    }
    final snapshot = value.input;
    final existing = value.saved;
    final g = _generation;
    _cancel = CancelToken();
    value = value.copy(busy: true);
    try {
      Experience result;
      if (existing == null) {
        if (_createdId == null &&
            _createUntil != null &&
            !DateTime.now().isBefore(_createUntil!)) {
          throw const ExperienceIssue('idempotency_conflict', status: 409);
        }
        _createInput ??= snapshot;
        _createKey ??= const Uuid().v4();
        _createUntil ??= DateTime.now().add(const Duration(hours: 24));
        if (_createdId == null) {
          final created = await repository.create(
            _createInput!,
            _createKey!,
            cancel: _cancel,
          );
          _createdId = created.id;
        }
        // Idempotency replay is the original snapshot, possibly older than GET.
        result = await repository.get(_createdId!, cancel: _cancel);
      } else {
        result = await repository.update(existing, snapshot, cancel: _cancel);
      }
      if (_disposed || g != _generation) return null;
      _createInput = null;
      _createKey = null;
      _createdId = null;
      _createUntil = null;
      value = value.copy(
        saved: result,
        input: result.input,
        busy: false,
        dirty: false,
        creationPending: false,
        revision: value.revision + 1,
      );
      return result;
    } catch (e) {
      if (_disposed || g != _generation) return null;
      final issue = safeExperienceIssue(e);
      final definitive = {400, 403, 404, 413, 422, 429}.contains(issue.status);
      if (definitive && _createdId == null) {
        _createKey = null;
        _createInput = null;
        _createUntil = null;
      }
      value = value.copy(
        busy: false,
        issue: issue,
        creationPending: existing == null && _createKey != null,
        dirty: true,
      );
      return null;
    }
  }

  Future<void> compareLatest() async {
    final current = value.saved;
    if (current == null || value.busy) return;
    final g = _generation;
    _cancel = CancelToken();
    value = value.copy(busy: true, issue: value.issue);
    try {
      final fresh = await repository.get(current.id, cancel: _cancel);
      if (!_disposed && g == _generation) {
        value = value.copy(
          latest: fresh,
          busy: false,
          issue: const ExperienceIssue('version_conflict'),
        );
      }
    } catch (e) {
      if (!_disposed && g == _generation) {
        final issue = safeExperienceIssue(e);
        if ({401, 403, 404}.contains(issue.status)) {
          _clear();
          value = value.copy(issue: issue);
        } else {
          value = value.copy(busy: false, issue: issue);
        }
      }
    }
  }

  /// Discard local changes only after the person reviews and confirms the latest.
  void useLatest() {
    final latest = value.latest;
    if (latest == null || value.busy) return;
    value = value.copy(
      input: latest.input,
      saved: latest,
      dirty: false,
      clearLatest: true,
      revision: value.revision + 1,
    );
  }

  Future<void> sendCover(
    CoverSelection selection, {
    bool restart = false,
  }) async {
    if (value.busy ||
        value.creationPending ||
        value.issue?.code == 'version_conflict') {
      return;
    }
    final g = _generation;
    _cancel = CancelToken();
    if (restart || upload == null || !identical(upload!.selection, selection)) {
      upload = CoverUpload(repository, _storage, selection);
    }
    value = value.copy(busy: true, uploadStatus: 'Preparando capa…');
    try {
      final verified = await upload!.run(
        _cancel,
        progress: (text) {
          if (!_disposed && g == _generation) {
            value = value.copy(busy: true, uploadStatus: text);
          }
        },
      );
      if (!_disposed && g == _generation) {
        value = value.copy(
          input: value.input.withCover(verified.id),
          busy: false,
          dirty: true,
          uploadStatus: 'Capa verificada. Salve para associar.',
        );
      }
    } catch (e) {
      if (!_disposed && g == _generation) {
        value = value.copy(busy: false, issue: safeExperienceIssue(e));
      }
    }
  }

  void cancelUpload() {
    _cancel.cancel();
  }

  bool get changed => value.dirty || value.creationPending || value.busy;
  String get localReview =>
      const JsonEncoder.withIndent('  ').convert(value.input.toJson());
  @override
  void dispose() {
    _disposed = true;
    _clear();
    _storage.close(force: true);
    access.removeListener(_clear);
    super.dispose();
  }
}

final experiencesListProvider = Provider.autoDispose<ExperiencesListController>(
  (ref) {
    final c = ExperiencesListController(
      ref.watch(experiencesRepositoryProvider),
      ref.watch(experienceAccessProvider),
    );
    ref.onDispose(c.dispose);
    return c;
  },
);
final experienceDetailProvider = Provider.autoDispose
    .family<ExperienceDetailController, String>((ref, id) {
      final c = ExperienceDetailController(
        ref.watch(experiencesRepositoryProvider),
        ref.watch(experienceAccessProvider),
        id,
      );
      ref.onDispose(c.dispose);
      return c;
    });
final experienceEditorProvider = Provider.autoDispose
    .family<ExperienceEditorController, String?>((ref, id) {
      final c = ExperienceEditorController(
        ref.watch(experiencesRepositoryProvider),
        ref.watch(experienceAccessProvider),
      );
      ref.onDispose(c.dispose);
      return c;
    });
