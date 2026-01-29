import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel createWebSocketChannel(
  Uri uri, {
  Map<String, dynamic>? headers,
}) {
  return WebSocketChannel.connect(uri);
}
