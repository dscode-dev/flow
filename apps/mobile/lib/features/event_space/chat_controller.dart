import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/auth/auth_state.dart';
import '../../core/network/http_client.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';
import '../social/social_repository.dart';
import 'chat_socket.dart';

final chatConnectorProvider = Provider<ChatConnector>((ref) => connectChat);
final chatControllerProvider = Provider.autoDispose
    .family<ChatController, String>((ref, eid) {
      final access = ref.watch(experienceAccessProvider),
          api = ref.watch(socialRepositoryProvider),
          auth = ref.watch(authControllerProvider);
      final base = Uri.parse(ref.watch(httpClientProvider).options.baseUrl);
      final connector = ref.watch(chatConnectorProvider);
      final c = ChatController(
        eid,
        api,
        access,
        (uri) =>
            auth.authorized((token) => connector(uri, token), replaySafe: true),
        base,
      );
      ref.onDispose(c.dispose);
      return c;
    });

class ChatController extends ChangeNotifier {
  ChatController(this.eid, this.api, this.access, this.open, this.base) {
    access.addListener(_account);
  }
  final String eid;
  final SocialRepository api;
  final ExperienceAccess access;
  final Future<ChatSocket> Function(Uri) open;
  final Uri base;
  String get path => 'v1/experiences/$eid/space/chat';
  final messages = <String, Map<String, dynamic>>{},
      pending = <String, Map<String, dynamic>>{};
  Map<String, dynamic> capabilities = {}, header = {};
  String? before, cursor, issue;
  bool connected = false,
      loading = false,
      busy = false,
      newMessages = false,
      viewing = false,
      active = false;
  int bodyLimit = 2000;
  String draft = '';
  bool browsingOlder = false;
  bool _disposed = false;
  int _generation = 0, _attempt = 0, _pageGeneration = 0;
  ChatSocket? _socket;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _retry, _heartbeat;
  DateTime? _lastHeartbeat;
  bool get canWrite => connected && capabilities['can_write'] == true;
  List<Map<String, dynamic>> get rows => messages.values.toList()
    ..sort(
      (a, b) =>
          BigInt.parse(a['sequence'] as String)
              .compareTo(BigInt.parse(b['sequence'] as String)),
    );
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _account() {
    pause(clearPending: true);
  }

  void show(bool value) {
    viewing = value;
    if (value) newMessages = false;
    _notify();
  }

  Future<void> start() async {
    if (_disposed || access.ownerId == null || active) return;
    active = true;
    _attempt = 0;
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed || !active) return;
    final g = ++_generation;
    loading = true;
    issue = null;
    _notify();
    try {
      final space = await api.request('GET', 'v1/experiences/$eid/space');
      final resume = cursor;
      var page = await api.request('GET', '$path/messages');
      final replay = <dynamic>[];
      if (resume != null) {
        String? next = resume;
        int pages = 0;
        while (next != null && pages++ < 10) {
          final delta = await api.request(
            'GET',
            '$path/messages',
            query: {'after': next},
          );
          if (delta['reset'] == true) {
            page = await api.request('GET', '$path/messages');
            break;
          }
          replay.addAll(delta['items'] as List);
          next = delta['next_cursor'] as String?;
        }
        if (next != null && pages >= 10) issue = 'history_gap';
      }
      if (_disposed || g != _generation || !active) return;
      bodyLimit = page['body_limit'] as int? ?? 2000;
      header = space;
      messages.clear();
      _apply(page['items'] as List);
      _apply(replay);
      before = page['next_cursor'] as String?;
      cursor = page['resume_cursor'] as String;
      capabilities = (page['capabilities'] as Map).cast<String, dynamic>();
      final http = base.resolve('$path/socket');
      final uri = http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
      final socket = await open(uri);
      if (_disposed || g != _generation || !active) {
        await socket.close();
        return;
      }
      _socket = socket;
      connected = true;
      loading = false;
      _lastHeartbeat = DateTime.now();
      _subscription = socket.frames.listen(
        (f) => _frame(f, g),
        onError: (Object e) => _lost(g),
        onDone: () => _lost(g),
      );
      _send('chat.join', {'cursor': cursor});
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        if (DateTime.now().difference(_lastHeartbeat!) >
            const Duration(seconds: 6)) {
          _lost(g);
        }
        for (final p in pending.values) {
          final sent = p['sent_at'];
          if (p['state'] == 'pending' &&
              sent is DateTime &&
              DateTime.now().difference(sent) > const Duration(seconds: 20)) {
            p['state'] = 'failed';
          }
        }
        _notify();
      });
      // Ambiguous sends retain their original UUID; reconciliation never invents a
      // second message. Definitive failures require an explicit user retry.
      for (final p in pending.values.toList()) {
        if (p['state'] == 'pending') {
          if (canWrite) {
            _transmit(p);
          } else {
            p['state'] = 'failed';
            p['error'] = 'space_read_only';
          }
        }
      }
      _notify();
    } catch (e) {
      if (g != _generation || _disposed) return;
      loading = false;
      issue = e is ExperienceIssue ? e.code : 'network';
      if (e is ExperienceIssue && e.status == 400) cursor = null;
      if (e is ExperienceIssue && {401, 403, 404}.contains(e.status)) {
        pause(clearPending: true);
        issue = 'access_revoked';
        _notify();
        return;
      }
      _lost(g);
    }
  }

  void _apply(List items) {
    for (final value in items) {
      final m = (value as Map).cast<String, dynamic>();
      if (m['id'] is! String ||
          m['experience_id'] != eid ||
          m['sequence'] is! String ||
          !RegExp(r'^\d+$').hasMatch(m['sequence'] as String) ||
          m['created_at'] is! String ||
          DateTime.tryParse(m['created_at'] as String) == null ||
          m['removed'] is! bool ||
          m['can_delete'] is! bool ||
          m['can_moderate'] is! bool) {
        throw const FormatException('Invalid chat message');
      }
      if (m['removed'] != true &&
          (m['body'] is! String ||
              m['author'] is! Map ||
              (m['author'] as Map)['display_name'] is! String)) {
        throw const FormatException('Invalid chat content');
      }

      final previous = messages[m['id']];
      final incoming = BigInt.parse(
        (m['change_sequence'] ?? m['sequence']) as String,
      );
      final old = previous == null
          ? BigInt.zero
          : BigInt.parse(
              (previous['change_sequence'] ?? previous['sequence']) as String,
            );
      if (incoming >= old) messages[m['id'] as String] = m;
      final client = m['client_message_id'];
      if (client != null) pending.remove(client);
    }
    if (messages.length > 500) {
      for (final row in (browsingOlder ? rows.reversed : rows).take(
        messages.length - 500,
      )) {
        messages.remove(row['id']);
      }
    }
  }

  void _frame(Map<String, dynamic> f, int g) {
    try {
      _handleFrame(f, g);
    } catch (_) {
      _lost(g);
    }
  }

  void _handleFrame(Map<String, dynamic> f, int g) {
    if (g != _generation || _disposed || !active) return;
    if (f['version'] != 1 || f['payload'] is! Map) {
      _lost(g);
      return;
    }
    _lastHeartbeat = DateTime.now();
    final p = (f['payload'] as Map).cast<String, dynamic>();
    switch (f['type']) {
      case 'chat.message.ack':
        _apply([p]);
      case 'chat.message.created':
      case 'chat.message.removed':
        final existed = messages.containsKey(p['id']);
        _apply([p]);
        if ((!viewing || browsingOlder) &&
            !existed &&
            f['type'] == 'chat.message.created') {
          newMessages = true;
        }
      case 'chat.sync':
        cursor = p['cursor'] as String;
        capabilities = (p['capabilities'] as Map).cast<String, dynamic>();
        _attempt = 0;
      case 'chat.reset':
        _resync();
        return;
      case 'chat.access.revoked':
        if (p['code'] == 'unauthorized') {
          _lost(g);
        } else {
          pause(clearPending: true);
          issue = 'access_revoked';
        }
        _notify();
        return;
      case 'chat.error':
        final id = p['client_message_id'];
        if (pending[id] != null) {
          pending[id]!['state'] = 'failed';
          pending[id]!['error'] = p['code'];
        }
        issue = p['code'] as String?;
    }
    _notify();
  }

  void _send(String type, Map<String, dynamic> payload) {
    _socket?.send({
      'message_id': const Uuid().v4(),
      'type': type,
      'version': 1,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'payload': payload,
    });
  }

  bool send(String body) {
    body = body.trim();
    if (!canWrite ||
        body.isEmpty ||
        body.runes.length > bodyLimit ||
        pending.length >= 20) {
      return false;
    }
    final id = const Uuid().v4();
    final p = <String, dynamic>{
      'client_message_id': id,
      'body': body,
      'state': 'pending',
      'sent_at': DateTime.now(),
    };
    pending[id] = p;
    _transmit(p);
    _notify();
    return true;
  }

  void _transmit(Map<String, dynamic> p) {
    if (!canWrite) return;
    try {
      _send('chat.message.send', {
        'client_message_id': p['client_message_id'],
        'body': p['body'],
      });
    } catch (_) {
      _lost(_generation);
    }
  }

  void retry(String id) {
    final p = pending[id];
    if (p == null || !canWrite) return;
    p['state'] = 'pending';
    _transmit(p);
    _notify();
  }

  void _lost(int g) {
    if (g != _generation || _disposed) return;
    _generation++;
    connected = false;
    loading = false;
    messages.clear();
    browsingOlder = false;
    header = {};
    capabilities = {};
    newMessages = false;
    _heartbeat?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    issue = 'network';
    _retry?.cancel();
    if (active && _attempt < 8) {
      final ms =
          (1000 * pow(2, _attempt++).toInt()).clamp(1000, 30000) +
          Random().nextInt(500);
      _retry = Timer(Duration(milliseconds: ms), _connect);
    } else {
      for (final p in pending.values) {
        p['state'] = 'failed';
      }
    }
    _notify();
  }

  Future<void> reconnect() async {
    pause();
    await start();
  }

  Future<void> _resync() async {
    if (!active) return;
    pause();
    await start();
  }

  Future<void> older() async {
    if (before == null || busy || !active) return;
    busy = true;
    browsingOlder = true;
    final g = _generation, pg = ++_pageGeneration;
    _notify();
    try {
      final p = await api.request(
        'GET',
        '$path/messages',
        query: {'cursor': before},
      );
      if (g != _generation || pg != _pageGeneration) return;
      if (p['reset'] == true) {
        await _resync();
        return;
      }
      _apply(p['items'] as List);
      before = p['next_cursor'] as String?;
    } catch (e) {
      issue = 'network';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> remove(String id, String reason) async {
    try {
      await api.request(
        'DELETE',
        '$path/messages/$id',
        body: {'reason': reason},
      );
      final m = messages[id];
      if (m != null) {
        messages[id] = {...m, 'body': null, 'author': null, 'removed': true};
      }
      _notify();
    } catch (e) {
      issue = e is ExperienceIssue ? e.code : 'network';
      _notify();
    }
  }

  Future<void> report(String id, String reason) async {
    try {
      await api.request(
        'POST',
        'v1/social/reports',
        body: {
          'target_type': 'CHAT_MESSAGE',
          'target_id': id,
          'reason': reason,
        },
        headers: {'Idempotency-Key': const Uuid().v4()},
      );
    } catch (e) {
      issue = e is ExperienceIssue ? e.code : 'network';
    }
    _notify();
  }

  void pause({bool clearPending = false}) {
    active = false;
    _generation++;
    _pageGeneration++;
    _retry?.cancel();
    _heartbeat?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    messages.clear();
    browsingOlder = false;
    header = {};
    capabilities = {};
    before = null;
    cursor = null;
    newMessages = false;
    connected = false;
    loading = false;
    busy = false;
    if (clearPending) {
      pending.clear();
      draft = '';
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    pause(clearPending: true);
    access.removeListener(_account);
    super.dispose();
  }
}
