import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';

void main() {
  test('parses a native plugin manifest with contributions', () {
    final plugin = DevicePlugin.fromManifest(
      {
        'name': 'demo',
        'version': '1.0.0',
        'runtime': 'dex',
        'entry': 'com.example.Demo',
        'methods': [
          {
            'name': 'filter',
            'types': [deviceAssetType],
            'uiHints': ['Filter'],
          },
          {
            'name': 'blur',
            'types': ['CensorStyleV1'],
            'pixels': true,
          },
        ],
        'contributes': {
          'buttons': [
            {'id': 'go', 'title': 'Go', 'slot': 'main.appBar', 'icon': 'bolt', 'method': 'onGo'},
          ],
          'pages': [
            {'id': 'home', 'title': 'Home', 'view': 'home'},
          ],
          'overlays': [
            {'id': 'hud', 'slot': 'global', 'view': 'hud', 'interactive': true},
          ],
          'events': {'app.start': 'onStart', 'viewer.open': 'onOpen'},
          'routes': {
            'MainTimelineRoute': {'view': 'gallery', 'title': 'Gallery'},
          },
        },
      },
      codePath: 'plugin.dex',
      enabled: true,
      bundled: false,
    );

    expect(plugin.entry, 'com.example.Demo');
    expect(plugin.method('filter')?.isFilter, isTrue);
    expect(plugin.method('blur')?.isCensorStyle, isTrue);
    expect(plugin.method('blur')?.pixels, isTrue);
    expect(plugin.contributions.map((item) => (item.kind, item.slot, item.id)), [
      (PluginContributionKind.button, 'main.appBar', 'go'),
      (PluginContributionKind.page, 'plugins.page', 'home'),
      (PluginContributionKind.overlay, 'global', 'hud'),
    ]);
    expect(plugin.contributions.last.interactive, isTrue);
    expect(plugin.events, {'app.start': 'onStart', 'viewer.open': 'onOpen'});
    expect(plugin.routes['MainTimelineRoute']?['view'], 'gallery');
  });

  test('round trips a workflow', () {
    const workflow = DeviceWorkflow(
      id: 'w1',
      name: 'Screenshots',
      trigger: deviceAssetCreateTrigger,
      enabled: true,
      steps: [
        DeviceWorkflowStep(
          id: 's1',
          pluginName: 'immich-plugin-core',
          methodName: 'assetFileFilter',
          config: {'pattern': 'screenshot'},
        ),
        DeviceWorkflowStep(
          id: 's2',
          pluginName: 'immich-plugin-core',
          methodName: 'assetFavorite',
          config: {},
          enabled: false,
        ),
      ],
    );

    final restored = DeviceWorkflow.fromJson(jsonDecode(jsonEncode(workflow.toJson())) as Map<String, dynamic>);

    expect(restored.name, 'Screenshots');
    expect(restored.steps.map((step) => step.methodName), ['assetFileFilter', 'assetFavorite']);
    expect(restored.steps.first.config, {'pattern': 'screenshot'});
    expect(restored.steps.last.enabled, isFalse);
  });
}
