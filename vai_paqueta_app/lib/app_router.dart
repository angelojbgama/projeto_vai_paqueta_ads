import 'package:go_router/go_router.dart';
import 'package:flutter/widgets.dart';

import 'features/auth/auth_page.dart';
import 'features/driver/driver_page.dart';
import 'features/history/history_page.dart';
import 'features/home/home_page.dart';
import 'features/passenger/passenger_page.dart';
import 'features/profile/profile_edit_page.dart';
import 'features/splash/splash_page.dart';

GoRouter buildRouter({GlobalKey<NavigatorState>? navigatorKey}) {
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashPage(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthPage(),
      ),
      GoRoute(
        path: '/historico',
        builder: (context, state) => const HistoryPage(),
      ),
      GoRoute(
        path: '/motorista',
        builder: (context, state) => const DriverPage(),
      ),
      GoRoute(
        path: '/passageiro',
        builder: (context, state) => const PassengerPage(),
      ),
      GoRoute(
        name: 'perfil',
        path: '/perfil',
        builder: (context, state) => const ProfileEditPage(),
      ),
    ],
  );
}
