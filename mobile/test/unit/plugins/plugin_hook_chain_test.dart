import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';
import 'package:immich_mobile/domain/plugins/plugin_hook_runner.dart';
import 'package:immich_mobile/domain/plugins/plugin_ids.dart';

PluginHookHandler _handler(String plugin, HookPhase phase, {int priority = 0, Object? when}) =>
    PluginHookHandler(plugin: plugin, hook: 'asset.delete', phase: phase, method: 'm', priority: priority, when: when);

void main() {
  group('PluginHookChain', () {
    test('runs the original unchanged without handlers', () async {
      final chain = PluginHookChain(hook: 'h', bindings: const [], invoke: (_, _) async => null);
      expect(await chain.run<int>({'a': 1}, (args) async => args['a'] as int), 1);
    });

    test('before merges args, instead replaces, after changes the result', () async {
      final calls = <String>[];
      final chain = PluginHookChain(
        hook: 'asset.delete',
        bindings: [
          _handler('after', HookPhase.after),
          _handler('instead-low', HookPhase.instead),
          _handler('before', HookPhase.before),
          _handler('instead-high', HookPhase.instead, priority: 5),
        ],
        invoke: (binding, data) async {
          calls.add(binding.plugin);
          return switch (binding.plugin) {
            'before' => {
              'args': {'b': 2},
            },
            'instead-high' => {'fallthrough': true},
            'instead-low' => {'result': (data['args'] as Map)['b']},
            'after' => {'result': ((data['result'] as int) * 10)},
            _ => null,
          };
        },
      );
      final result = await chain.run<int>({'a': 1}, (args) async => -1);
      expect(result, 20);
      expect(calls, ['before', 'instead-high', 'instead-low', 'after']);
    });

    test('cancel throws PluginCancelled with the message; failures fall back', () async {
      final cancelling = PluginHookChain(
        hook: 'asset.delete',
        bindings: [_handler('p', HookPhase.before)],
        invoke: (_, _) async => {'cancel': true, 'message': 'no'},
      );
      await expectLater(
        cancelling.run<int>({}, (_) async => 1),
        throwsA(isA<PluginCancelled>().having((error) => error.message, 'message', 'no')),
      );

      final errors = <Object>[];
      final failing = PluginHookChain(
        hook: 'asset.delete',
        bindings: [_handler('p', HookPhase.before), _handler('q', HookPhase.instead)],
        invoke: (binding, _) => binding.plugin == 'p'
            ? Future<Map<String, dynamic>?>.error(StateError('boom'))
            : Completer<Map<String, dynamic>?>().future,
        onError: (_, error, _) => errors.add(error),
        timeout: const Duration(milliseconds: 50),
      );
      expect(await failing.run<int>({}, (_) async => 7), 7);
      expect(errors.length, 2);
    });

    test('non-cancellable hooks ignore cancel', () async {
      final chain = PluginHookChain(
        hook: 'q',
        bindings: [_handler('p', HookPhase.before)],
        invoke: (_, _) async => {'cancel': true},
        cancellable: false,
      );
      expect(await chain.run<int>({}, (_) async => 3), 3);
    });
  });

  group('when and patterns', () {
    test('matchesWhen', () {
      expect(matchesWhen({'assetType': 'IMAGE'}, {'assetType': 'IMAGE'}), isTrue);
      expect(matchesWhen({'assetType': ['VIDEO', 'IMAGE']}, {'assetType': 'IMAGE'}), isTrue);
      expect(
        matchesWhen({
          'assetType': {'not': 'VIDEO'},
        }, {'assetType': 'IMAGE'}),
        isTrue,
      );
      expect(
        matchesWhen({
          'selectionCount': {'gte': 2},
        }, {'selectionCount': 1}),
        isFalse,
      );
      expect(matchesWhen({'asset.exifInfo.make': 'Apple'}, {
        'asset': {
          'exifInfo': {'make': 'Apple'},
        },
      }), isTrue);
      expect(_handler('p', HookPhase.after, when: {'scope': 'main'}).appliesTo({'scope': 'album'}), isFalse);
    });

    test('event patterns', () {
      expect(matchesEventPattern('asset.*', 'asset.deleted'), isTrue);
      expect(matchesEventPattern('asset.*', 'assets.deleted'), isFalse);
      expect(matchesEventPattern('*', 'anything'), isTrue);
    });
  });

  group('manifest v2', () {
    test('legacy contributions become slot items and v2 fields parse', () {
      final plugin = DevicePlugin.fromManifest(
        {
          'name': 'demo',
          'contributes': {
            'buttons': [
              {'id': 'go', 'title': 'Go', 'method': 'onGo'},
            ],
            'slots': [
              {'id': 'shield', 'slot': 'viewer.topBar', 'kind': 'toggle', 'icon': 'shield', 'default': true},
            ],
            'builtins': {
              'viewer.topBar': {
                'hide': ['favorite'],
                'order': ['share', '*'],
              },
            },
            'hooks': {
              'asset.delete': {'before': 'confirm', 'priority': 3, 'timeoutMs': 500},
            },
            'events': {
              'asset.*': 'onAsset',
              'video.position': {'method': 'onPos', 'throttleMs': 250},
            },
            'settings': {'title': 'Demo', 'uiMethod': 'settings'},
            'theme': {'seedColor': '#FF4150AF', 'variant': 'vibrant'},
          },
        },
        codePath: '/x',
        enabled: true,
        bundled: false,
      );
      expect(plugin.contributions.single.kind, PluginContributionKind.button);
      expect(plugin.slots.map((item) => item.kind), [PluginSlotKind.button, PluginSlotKind.toggle]);
      expect(plugin.slots.first.slot, 'viewer.topBar');
      expect(plugin.slots.first.isLegacy, isTrue);
      expect(plugin.slots.last.defaultValue, isTrue);
      expect(plugin.builtins['viewer.topBar']!.hides('favorite'), isTrue);
      expect(plugin.hooks.single.priority, 3);
      expect(plugin.events, {'asset.*': 'onAsset', 'video.position': 'onPos'});
      expect(plugin.eventThrottleMs['video.position'], 250);
      expect(plugin.settings.single.uiMethod, 'settings');
      expect(plugin.theme!.toJson()['variant'], 'vibrant');

      final arranged = plugin.builtins['viewer.topBar']!.arrange<String>(
        ['favorite', 'edit', 'share'],
        (id) => id,
        [plugin.slots.last],
      );
      expect(arranged.map((entry) => entry.id), ['share', 'edit', 'plugin:demo/shield']);
    });
  });
}
