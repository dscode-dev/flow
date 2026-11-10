import 'chat_socket.dart';

Future<ChatSocket> connectChat(Uri uri, String access) => Future.error(
  UnsupportedError('Chat nativo indisponível nesta plataforma.'),
);
