import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/device_plugin.model.dart';

void main() {
  test('parses the bundled core plugin manifest', () {
    final json = jsonDecode(File('assets/plugins/immich-plugin-core/manifest.json').readAsStringSync()) as Map;
    final plugin = DevicePlugin.fromManifest(
      Map<String, dynamic>.from(json),
      wasmPath: 'plugin.wasm',
      enabled: true,
      bundled: true,
    );

    expect(plugin.name, 'immich-plugin-core');
    expect(plugin.usesHostFunctions, isTrue);
    expect(plugin.method('assetEdit')?.hostFunctions, isTrue);
    expect(plugin.method('assetFavorite')?.types, contains(deviceAssetType));
    expect(plugin.method('assetFileFilter')?.isFilter, isTrue);
    expect(plugin.templates, isNotEmpty);
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
