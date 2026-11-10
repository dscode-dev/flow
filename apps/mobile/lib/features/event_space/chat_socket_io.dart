import 'dart:convert';
import 'dart:io';

import 'chat_socket.dart';

Future<ChatSocket> connectChat(Uri uri, String access) async => _Native(
  await WebSocket.connect(
    uri.toString(),
    protocols: ['flow.chat.v1'],
    headers: {'Authorization': 'Bearer $access'},
  ).timeout(const Duration(seconds: 10)),
);

class _Native implements ChatSocket {
  _Native(this.socket) {
    socket.pingInterval = const Duration(seconds: 20);
  }
  final WebSocket socket;
  @override
  Stream<Map<String, dynamic>> get frames => socket.map((v) {
    if (v is! String || v.length > 65536) {
      throw const FormatException('Invalid frame');
    }
    return (jsonDecode(v) as Map).cast<String, dynamic>();
  });
  @override
  void send(Map<String, dynamic> frame) => socket.add(jsonEncode(frame));
  @override
  Future<void> close() async {
    await socket
        .close(WebSocketStatus.normalClosure)
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
  }
}
