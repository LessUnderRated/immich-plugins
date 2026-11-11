import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';

class AuthGuard extends AutoRouteGuard {
  AuthGuard(ApiService _, AuthService _);

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    resolver.next(true);
  }
}
