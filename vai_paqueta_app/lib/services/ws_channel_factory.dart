import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_channel_factory_io.dart'
    if (dart.library.html) 'ws_channel_factory_web.dart';

WebSocketChannel connectWebSocket(
  Uri uri, {
  Map<String, dynamic>? headers,
}) {
  return createWebSocketChannel(uri, headers: headers);
}
