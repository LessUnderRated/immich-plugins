import 'dart:async';

import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_settings.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';

/// Provides access to a persistent key-value store with an in-memory cache.
/// Listens for repository changes to keep the cache updated.
class StoreService {
  final StoreRepository _storeRepository;

  /// In-memory cache. Keys are [StoreKey.id]
  final Map<int, Object?> _cache = {};
  StreamSubscription<List<StoreDto>>? _storeUpdateSubscription;

  StoreService._({required StoreRepository isarStoreRepository}) : _storeRepository = isarStoreRepository;

  // TODO: Temporary typedef to make minimal changes. Remove this and make the presentation layer access store through a provider
  static StoreService? _instance;
  static StoreService get I {
    if (_instance == null) {
      throw UnsupportedError("StoreService not initialized. Call init() first");
    }
    return _instance!;
  }

  // TODO: Replace the implementation with the one from create after removing the typedef
  static Future<StoreService> init({required StoreRepository storeRepository, bool listenUpdates = true}) async {
    _instance ??= await create(storeRepository: storeRepository, listenUpdates: listenUpdates);
    return _instance!;
  }

  static Future<StoreService> create({required StoreRepository storeRepository, bool listenUpdates = true}) async {
    final instance = StoreService._(isarStoreRepository: storeRepository);
    await instance.populateCache();
    if (listenUpdates) {
      instance._storeUpdateSubscription = instance._listenForChange();
    }
    return instance;
  }

  Future<void> populateCache() async {
    final storeValues = await _storeRepository.getAll();
    for (StoreDto storeValue in storeValues) {
      _cache[storeValue.key.id] = storeValue.value;
    }
  }

  StreamSubscription<List<StoreDto>> _listenForChange() => _storeRepository.watchAll().listen((events) {
    _cache.clear();
    for (final event in events) {
      _cache[event.key.id] = event.value;
    }
  });

  /// Disposes the store and cancels the subscription. To reuse the store call init() again
  Future<void> dispose() async {
    await _storeUpdateSubscription?.cancel();
    _storeUpdateSubscription = null;
    _cache.clear();
    // Allow a subsequent init() (e.g. when a worker isolate is reused) to
    // create a fresh instance instead of returning this disposed one.
    if (identical(_instance, this)) {
      _instance = null;
    }
  }

  /// Returns the cached value for [key], or `null`
  T? tryGet<T>(StoreKey<T> key) => _cache[key.id] as T?;

  /// Returns the stored value for [key] or [defaultValue].
  /// Throws [StoreKeyNotFoundException] if value and [defaultValue] are null.
  T get<T>(StoreKey<T> key, [T? defaultValue]) {
    final value = tryGet(key) ?? defaultValue;
    if (value == null) {
      throw StoreKeyNotFoundException(key);
    }
    return value;
  }

  /// Stores the [value] for the [key]. Skips write if value hasn't changed.
  ///
  /// Runs as `settings.set` (`store: "store"`) and emits `settings.changed`.
  Future<void> put<U extends StoreKey<T>, T>(U key, T value) async {
    if (_cache[key.id] == value) {
      return;
    }
    final previous = _cache[key.id];
    await PluginHooks.run<void>(
      DataHooks.settingsSet,
      () => {
        'key': PluginSettings.storeKey(key),
        'store': 'store',
        'value': PluginSettings.encodeStore(value),
        'previous': PluginSettings.encodeStore(previous),
      },
      () => _put(key, value),
      withArgs: (args) {
        final changed = PluginSettings.decodeStore(key, args['value']);
        return changed == null ? _delete(key) : _put(key, changed as T);
      },
      event: DataEvents.settingsChanged,
    );
  }

  Future<void> _put<T>(StoreKey<T> key, T value) async {
    await _storeRepository.upsert(key, value);
    _cache[key.id] = value;
  }

  /// Returns a stream that emits the value for [key] on change.
  Stream<T?> watch<T>(StoreKey<T> key) => _storeRepository.watch(key);

  /// Removes the value for [key]; runs as `settings.set` with `reset: true` and emits `settings.changed`.
  Future<void> delete<T>(StoreKey<T> key) {
    final previous = _cache[key.id];
    return PluginHooks.run<void>(
      DataHooks.settingsSet,
      () => {
        'key': PluginSettings.storeKey(key),
        'store': 'store',
        'value': null,
        'previous': PluginSettings.encodeStore(previous),
        'reset': true,
      },
      () => _delete(key),
      event: DataEvents.settingsChanged,
    );
  }

  Future<void> _delete<T>(StoreKey<T> key) async {
    await _storeRepository.deleteValue(key);
    _cache.remove(key.id);
  }

  /// Every key with a cached value, for `settings.list`.
  Map<StoreKey, Object?> get values => {
    for (final key in StoreKey.values)
      if (_cache.containsKey(key.id)) key: _cache[key.id],
  };

  /// Clears all values from the store (cache and DB)
  Future<void> clear() async {
    await _storeRepository.deleteAll();
    _cache.clear();
  }
}

class StoreKeyNotFoundException implements Exception {
  final StoreKey key;
  const StoreKeyNotFoundException(this.key);

  @override
  String toString() => "Key - <${key.name}> not available in Store";
}
