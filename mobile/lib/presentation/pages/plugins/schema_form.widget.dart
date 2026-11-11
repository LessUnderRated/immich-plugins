import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

typedef ConfigChanged = void Function(Map<String, dynamic> config);
typedef AlbumOption = ({String id, String name});
typedef AlbumOptionsLoader = Future<List<AlbumOption>> Function();

Future<List<AlbumOption>> deviceFolderOptions() async => [
  for (final path in await PhotoManager.getAssetPathList(type: RequestType.common, hasAll: false))
    (id: path.id, name: path.name),
];

class SchemaForm extends StatelessWidget {
  final Map<String, dynamic> schema;
  final Map<String, dynamic> config;
  final ConfigChanged onChanged;
  final AlbumOptionsLoader albumOptions;

  const SchemaForm({
    super.key,
    required this.schema,
    required this.config,
    required this.onChanged,
    this.albumOptions = deviceFolderOptions,
  });

  @override
  Widget build(BuildContext context) {
    final properties = schema['properties'] is Map ? Map<String, dynamic>.from(schema['properties'] as Map) : {};
    if (properties.isEmpty) {
      return const SizedBox.shrink();
    }

    final entries = properties.entries.toList()..sort((a, b) => _order(a.value).compareTo(_order(b.value)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          _SchemaField(
            key: ValueKey(entry.key),
            name: entry.key,
            property: Map<String, dynamic>.from(entry.value as Map),
            value: config[entry.key],
            albumOptions: albumOptions,
            onChanged: (value) {
              final next = Map<String, dynamic>.from(config);
              value == null ? next.remove(entry.key) : next[entry.key] = value;
              onChanged(next);
            },
          ),
      ],
    );
  }

  static int _order(Object? property) {
    if (property is Map && property['uiHint'] is Map) {
      final order = (property['uiHint'] as Map)['order'];
      if (order is num) {
        return order.toInt();
      }
    }
    return 1000;
  }
}

class _SchemaField extends StatelessWidget {
  final String name;
  final Map<String, dynamic> property;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final AlbumOptionsLoader albumOptions;

  const _SchemaField({
    super.key,
    required this.name,
    required this.property,
    required this.value,
    required this.onChanged,
    required this.albumOptions,
  });

  String get _title => property['title'] as String? ?? name;
  String? get _description => property['description'] as String?;
  bool get _isArray => property['array'] == true;
  List<String> get _enum => property['enum'] is List ? (property['enum'] as List).map((e) => '$e').toList() : const [];
  String? get _hint => property['uiHint'] is Map ? (property['uiHint'] as Map)['type'] as String? : null;

  @override
  Widget build(BuildContext context) {
    final type = property['type'] as String? ?? (property['properties'] != null ? 'object' : 'string');

    if (type == 'object') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_title, style: Theme.of(context).textTheme.titleSmall),
                if (_description != null) Text(_description!, style: Theme.of(context).textTheme.bodySmall),
                SchemaForm(
                  schema: property,
                  config: value is Map ? Map<String, dynamic>.from(value as Map) : {},
                  albumOptions: albumOptions,
                  onChanged: (next) => onChanged(next.isEmpty ? null : next),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (type == 'boolean') {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(_title),
        subtitle: _description == null ? null : Text(_description!),
        value: value is bool ? value as bool : property['default'] == true,
        onChanged: onChanged,
      );
    }

    if (_hint == 'AlbumId') {
      return _AlbumPicker(
        title: _title,
        albumOptions: albumOptions,
        description: _description,
        multiple: _isArray,
        value: value,
        onChanged: onChanged,
      );
    }

    if (_enum.isNotEmpty && _isArray) {
      final selected = value is List ? (value as List).map((e) => '$e').toSet() : <String>{};
      return _Labeled(
        title: _title,
        description: _description,
        child: Wrap(
          spacing: 8,
          children: [
            for (final option in _enum)
              FilterChip(
                label: Text(option),
                selected: selected.contains(option),
                onSelected: (on) {
                  final next = {...selected};
                  on ? next.add(option) : next.remove(option);
                  onChanged(next.isEmpty ? null : next.toList());
                },
              ),
          ],
        ),
      );
    }

    if (_enum.isNotEmpty) {
      final current = value?.toString() ?? property['default']?.toString();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: DropdownButtonFormField<String>(
          initialValue: _enum.contains(current) ? current : null,
          decoration: InputDecoration(labelText: _title, helperText: _description, helperMaxLines: 3),
          items: [for (final option in _enum) DropdownMenuItem(value: option, child: Text(option))],
          onChanged: onChanged,
        ),
      );
    }

    final isNumber = type == 'number' || type == 'integer';
    final initial = _isArray && value is List
        ? (value as List).join(', ')
        : (value ?? property['default'])?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        initialValue: initial,
        keyboardType: isNumber ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
        decoration: InputDecoration(
          labelText: _title,
          helperText: [?_description, if (_isArray) 'Separate values with commas'].join('\n'),
          helperMaxLines: 4,
        ),
        onChanged: (text) {
          final trimmed = text.trim();
          if (trimmed.isEmpty) {
            onChanged(null);
          } else if (_isArray) {
            onChanged(trimmed.split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList());
          } else if (isNumber) {
            onChanged(num.tryParse(trimmed));
          } else {
            onChanged(text);
          }
        },
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  const _Labeled({required this.title, required this.description, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodyLarge),
          if (description != null) Text(description!, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _AlbumPicker extends StatelessWidget {
  final AlbumOptionsLoader albumOptions;
  final String title;
  final String? description;
  final bool multiple;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  const _AlbumPicker({
    required this.albumOptions,
    required this.title,
    required this.description,
    required this.multiple,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value is List ? (value as List).map((e) => '$e').toSet() : {if (value is String) value as String};

    return _Labeled(
      title: title,
      description: description,
      child: FutureBuilder<List<AlbumOption>>(
        future: albumOptions(),
        builder: (context, snapshot) {
          final albums = snapshot.data;
          if (albums == null) {
            return const LinearProgressIndicator();
          }
          if (albums.isEmpty) {
            return const Text('No albums on this device');
          }
          return Wrap(
            spacing: 8,
            children: [
              for (final album in albums)
                FilterChip(
                  label: Text(album.name),
                  selected: selected.contains(album.id),
                  onSelected: (on) {
                    if (!multiple) {
                      onChanged(on ? album.id : null);
                      return;
                    }
                    final next = {...selected};
                    on ? next.add(album.id) : next.remove(album.id);
                    onChanged(next.toList());
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}
