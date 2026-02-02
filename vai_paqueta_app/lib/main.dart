import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_router.dart';
import 'services/driver_background_service.dart';
import 'services/fcm_service.dart';
import 'services/map_tile_cache_service.dart';
import 'services/notification_service.dart';

final _router = buildRouter();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  await FcmService.initialize();
  await DriverBackgroundService.initialize();
  await MapTileCacheService.initialize();
  runApp(const ProviderScope(child: VaiPaquetaApp()));
}

class VaiPaquetaApp extends ConsumerWidget {
  const VaiPaquetaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Vai Paquetá',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green.shade700),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}

