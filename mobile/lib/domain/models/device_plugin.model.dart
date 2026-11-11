List<String> _strings(Object? value) => value is List ? value.whereType<String>().toList() : const [];

Map<String, dynamic> _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

class DevicePluginMethod {
  final String name;
  final String title;
  final String description;
  final List<String> types;
  final bool hostFunctions;
  final List<String> allowedHosts;
  final List<String> uiHints;
  final Map<String, dynamic> schema;

  const DevicePluginMethod({
    required this.name,
    required this.title,
    required this.description,
    required this.types,
    required this.hostFunctions,
    required this.allowedHosts,
    required this.uiHints,
    required this.schema,
  });

  factory DevicePluginMethod.fromJson(Map<String, dynamic> json) => DevicePluginMethod(
    name: json['name'] as String,
    title: json['title'] as String? ?? json['name'] as String,
    description: json['description'] as String? ?? '',
    types: _strings(json['types']),
    hostFunctions: json['hostFunctions'] == true,
    allowedHosts: _strings(json['allowedHosts']),
    uiHints: _strings(json['uiHints']),
    schema: _map(json['schema']),
  );

  bool get isFilter => uiHints.contains('Filter');

  bool get isGalleryView => uiHints.contains('GalleryView') || types.contains('GalleryViewV1');
}

class DevicePlugin {
  final String name;
  final String version;
  final String title;
  final String description;
  final String author;
  final String wasmPath;
  final List<DevicePluginMethod> methods;
  final List<Map<String, dynamic>> templates;
  final bool enabled;
  final bool bundled;

  const DevicePlugin({
    required this.name,
    required this.version,
    required this.title,
    required this.description,
    required this.author,
    required this.wasmPath,
    required this.methods,
    required this.templates,
    required this.enabled,
    required this.bundled,
  });

  factory DevicePlugin.fromManifest(
    Map<String, dynamic> json, {
    required String wasmPath,
    required bool enabled,
    required bool bundled,
  }) => DevicePlugin(
    name: json['name'] as String,
    version: json['version'] as String? ?? '0.0.0',
    title: json['title'] as String? ?? json['name'] as String,
    description: json['description'] as String? ?? '',
    author: json['author'] as String? ?? '',
    wasmPath: wasmPath,
    methods: (json['methods'] as List? ?? const [])
        .whereType<Map>()
        .map((method) => DevicePluginMethod.fromJson(Map<String, dynamic>.from(method)))
        .toList(),
    templates: (json['templates'] as List? ?? const []).whereType<Map>().map(Map<String, dynamic>.from).toList(),
    enabled: enabled,
    bundled: bundled,
  );

  bool get usesHostFunctions => methods.any((method) => method.hostFunctions);

  DevicePluginMethod? method(String name) {
    for (final method in methods) {
      if (method.name == name) {
        return method;
      }
    }
    return null;
  }
}

class DeviceWorkflowStep {
  final String id;
  final String pluginName;
  final String methodName;
  final Map<String, dynamic> config;
  final bool enabled;

  const DeviceWorkflowStep({
    required this.id,
    required this.pluginName,
    required this.methodName,
    required this.config,
    this.enabled = true,
  });

  factory DeviceWorkflowStep.fromJson(Map<String, dynamic> json) => DeviceWorkflowStep(
    id: json['id'] as String,
    pluginName: json['pluginName'] as String,
    methodName: json['methodName'] as String,
    config: _map(json['config']),
    enabled: json['enabled'] != false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pluginName': pluginName,
    'methodName': methodName,
    'config': config,
    'enabled': enabled,
  };

  DeviceWorkflowStep copyWith({Map<String, dynamic>? config, bool? enabled}) => DeviceWorkflowStep(
    id: id,
    pluginName: pluginName,
    methodName: methodName,
    config: config ?? this.config,
    enabled: enabled ?? this.enabled,
  );
}

class DeviceWorkflow {
  final String id;
  final String name;
  final String trigger;
  final bool enabled;
  final List<DeviceWorkflowStep> steps;

  const DeviceWorkflow({
    required this.id,
    required this.name,
    required this.trigger,
    required this.enabled,
    required this.steps,
  });

  factory DeviceWorkflow.fromJson(Map<String, dynamic> json) => DeviceWorkflow(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Workflow',
    trigger: json['trigger'] as String? ?? deviceAssetCreateTrigger,
    enabled: json['enabled'] != false,
    steps: (json['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((step) => DeviceWorkflowStep.fromJson(Map<String, dynamic>.from(step)))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trigger': trigger,
    'enabled': enabled,
    'steps': steps.map((step) => step.toJson()).toList(),
  };

  DeviceWorkflow copyWith({String? name, bool? enabled, List<DeviceWorkflowStep>? steps}) => DeviceWorkflow(
    id: id,
    name: name ?? this.name,
    trigger: trigger,
    enabled: enabled ?? this.enabled,
    steps: steps ?? this.steps,
  );
}

const deviceAssetCreateTrigger = 'AssetCreate';
const deviceAssetType = 'AssetV1';
