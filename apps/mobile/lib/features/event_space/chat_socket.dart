import 'dart:async';

import 'chat_socket_stub.dart'
    if (dart.library.io) 'chat_socket_io.dart'
    as native;

abstract interface class ChatSocket {
  Stream<Map<String, dynamic>> get frames;
  void send(Map<String, dynamic> frame);
  Future<void> close();
}

typedef ChatConnector = Future<ChatSocket> Function(Uri uri, String access);
Future<ChatSocket> connectChat(Uri uri, String access) =>
    native.connectChat(uri, access);
