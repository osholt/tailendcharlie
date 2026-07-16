import 'imported_route.dart';

abstract interface class RouteStore {
  Future<ImportedRoute?> loadActiveRoute();

  Future<void> saveActiveRoute(ImportedRoute route);

  Future<void> clearActiveRoute();
}

class InMemoryRouteStore implements RouteStore {
  InMemoryRouteStore([this._route]);

  ImportedRoute? _route;

  @override
  Future<void> clearActiveRoute() async => _route = null;

  @override
  Future<ImportedRoute?> loadActiveRoute() async => _route;

  @override
  Future<void> saveActiveRoute(ImportedRoute route) async => _route = route;
}
