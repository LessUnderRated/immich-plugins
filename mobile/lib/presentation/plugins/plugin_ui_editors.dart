import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';

// -------------------------------------------------------------------------------------------------------------------
// Colors
// -------------------------------------------------------------------------------------------------------------------

/// `#AARRGGBB` for a color.
String pluginColorHex(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// Preset swatches of the color picker when a node does not set `presets`.
const pluginDefaultColorPresets = <Color>[
  Color(0xFF000000),
  Color(0xFFFFFFFF),
  Color(0xFF9E9E9E),
  Color(0xFFF44336),
  Color(0xFFE91E63),
  Color(0xFF9C27B0),
  Color(0xFF673AB7),
  Color(0xFF3F51B5),
  Color(0xFF2196F3),
  Color(0xFF03A9F4),
  Color(0xFF00BCD4),
  Color(0xFF009688),
  Color(0xFF4CAF50),
  Color(0xFF8BC34A),
  Color(0xFFCDDC39),
  Color(0xFFFFEB3B),
  Color(0xFFFFC107),
  Color(0xFFFF9800),
  Color(0xFFFF5722),
  Color(0xFF795548),
];

/// RGB(A) sliders, a hex field and preset swatches. Used inline (`colorPicker` with `inline: true`) and in the
/// picker dialog.
class PluginColorEditor extends StatefulWidget {
  final Color value;
  final bool alpha;
  final List<Color> presets;
  final ValueChanged<Color> onChanged;

  const PluginColorEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.alpha = false,
    this.presets = pluginDefaultColorPresets,
  });

  @override
  State<PluginColorEditor> createState() => _PluginColorEditorState();
}

class _PluginColorEditorState extends State<PluginColorEditor> {
  late final _hex = TextEditingController(text: pluginColorHex(widget.value));

  @override
  void didUpdateWidget(PluginColorEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hex = pluginColorHex(widget.value);
    if (oldWidget.value != widget.value && _hex.text.toUpperCase() != hex) {
      _hex.text = hex;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(Color color) {
    _hex.text = pluginColorHex(color);
    widget.onChanged(color);
  }

  Widget _channel(String label, int value, Color activeColor, Color Function(int) apply) => Row(
    children: [
      SizedBox(width: 18, child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
      Expanded(
        child: Slider(
          value: value.toDouble(),
          max: 255,
          divisions: 255,
          activeColor: activeColor,
          label: '$value',
          onChanged: (next) => _set(apply(next.round())),
        ),
      ),
      SizedBox(
        width: 32,
        child: Text('$value', textAlign: TextAlign.end, style: Theme.of(context).textTheme.labelSmall),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final color = widget.value;
    final argb = color.toARGB32();
    final a = (argb >> 24) & 0xFF;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final outline = Theme.of(context).colorScheme.outline;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                border: Border.all(color: outline),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(labelText: 'Hex', isDense: true, border: OutlineInputBorder()),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]'))],
                onSubmitted: (text) {
                  final parsed = parsePluginColor(text.startsWith('#') ? text : '#$text');
                  if (parsed != null) {
                    _set(Color(widget.alpha ? parsed : parsed | 0xFF000000));
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _channel('R', r, const Color(0xFFE53935), (value) => Color.fromARGB(a, value, g, b)),
        _channel('G', g, const Color(0xFF43A047), (value) => Color.fromARGB(a, r, value, b)),
        _channel('B', b, const Color(0xFF1E88E5), (value) => Color.fromARGB(a, r, g, value)),
        if (widget.alpha) _channel('A', a, outline, (value) => Color.fromARGB(value, r, g, b)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in widget.presets)
              InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(16)),
                onTap: () => _set(widget.alpha ? preset : preset.withAlpha(0xFF)),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: preset,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: preset.toARGB32() == argb ? Theme.of(context).colorScheme.primary : outline,
                      width: preset.toARGB32() == argb ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Shows the color picker dialog; returns the chosen color or null.
Future<Color?> showPluginColorPicker(
  BuildContext context, {
  required Color initial,
  String? title,
  bool alpha = false,
  List<Color> presets = pluginDefaultColorPresets,
}) {
  var current = initial;
  return showDialog<Color>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title ?? 'Color'),
        content: SingleChildScrollView(
          child: PluginColorEditor(
            value: current,
            alpha: alpha,
            presets: presets,
            onChanged: (color) => setState(() => current = color),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text('OK')),
        ],
      ),
    ),
  );
}

// -------------------------------------------------------------------------------------------------------------------
// Images for editors
// -------------------------------------------------------------------------------------------------------------------

/// An image an editor node draws on.
class PluginLoadedImage {
  final ImageProvider? provider;
  final ui.Image? image;

  /// Width / height; null when unknown.
  final double? aspect;

  const PluginLoadedImage({this.provider, this.image, this.aspect});
}

/// Loads a photo or a video frame for an editor node: `file` (absolute, or relative to the plugin's files), or
/// `assetId` (+ `timeMs` for video frames) through the `image.load` host function, falling back to the app's own image
/// providers for photos when `image.load` is not available.
Future<PluginLoadedImage?> loadPluginEditorImage(
  PluginKernel kernel,
  String plugin, {
  String? file,
  String? assetId,
  int? timeMs,
  int maxSize = 1600,
  String? pluginsRoot,
}) async {
  if (file != null) {
    final path = File(file).isAbsolute || pluginsRoot == null ? file : '$pluginsRoot/$plugin/files/$file';
    return PluginLoadedImage(provider: FileImage(File(path)), aspect: await _aspectOf(FileImage(File(path))));
  }
  if (assetId == null) {
    return null;
  }
  if (kernel.hasHost('image.load')) {
    try {
      final result = await kernel.callHost('image.load', [
        assetId,
        {'maxSize': maxSize, 'timeMs': ?timeMs, 'format': 'png'},
      ], plugin: plugin);
      if (result is Map) {
        final width = result['width'];
        final height = result['height'];
        final double? aspect = width is num && height is num && height > 0 ? width / height : null;
        final path = result['path'];
        if (result['format'] == 'rgba' && path is String && width is int && height is int) {
          final image = await _decodeRgba(await File(path).readAsBytes(), width, height);
          return PluginLoadedImage(image: image, aspect: aspect);
        }
        if (path is String) {
          final provider = FileImage(File(path));
          return PluginLoadedImage(provider: provider, aspect: aspect ?? await _aspectOf(provider));
        }
      }
    } catch (_) {
      // fall back below
    }
  }
  final asset = await kernel.findAsset(assetId);
  if (asset == null) {
    return null;
  }
  final aspect = _assetAspect(asset);
  if (asset.isVideo && timeMs != null && timeMs > 0) {
    // without image.load there is no frame at a time; the poster (thumbnail) stands in
    final thumb = getThumbnailImageProvider(asset, size: Size(maxSize.toDouble(), maxSize.toDouble()));
    return PluginLoadedImage(provider: thumb, aspect: aspect);
  }
  final provider = asset.isVideo
      ? getThumbnailImageProvider(asset, size: Size(maxSize.toDouble(), maxSize.toDouble()))
      : getFullImageProvider(asset, size: Size(maxSize.toDouble(), maxSize.toDouble()));
  return PluginLoadedImage(provider: provider, aspect: provider == null ? aspect : await _aspectOf(provider) ?? aspect);
}

double? _assetAspect(BaseAsset asset) {
  final width = asset.width;
  final height = asset.height;
  return width != null && height != null && width > 0 && height > 0 ? width / height : null;
}

Future<ui.Image> _decodeRgba(Uint8List bytes, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

Future<double?> _aspectOf(ImageProvider provider) {
  final completer = Completer<double?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) {
        completer.complete(info.image.height == 0 ? null : info.image.width / info.image.height);
      }
      stream.removeListener(listener);
    },
    onError: (_, _) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future.timeout(const Duration(seconds: 20), onTimeout: () => null);
}

/// Draws a [PluginLoadedImage] filling its box (the box has the image's aspect ratio).
class PluginEditorImage extends StatelessWidget {
  final PluginLoadedImage? image;

  const PluginEditorImage({super.key, this.image});

  @override
  Widget build(BuildContext context) {
    final loaded = image;
    if (loaded?.image != null) {
      return RawImage(image: loaded!.image, fit: BoxFit.fill);
    }
    if (loaded?.provider != null) {
      return Image(
        image: loaded!.provider!,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const _NoImage(),
      );
    }
    return const _NoImage();
  }
}

class _NoImage extends StatelessWidget {
  const _NoImage();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(child: Icon(Icons.image_not_supported_outlined, color: Theme.of(context).colorScheme.outline)),
  );
}

/// Single-pointer drag that claims the gesture at once (so editors inside scroll views draw instead of scrolling).
class _EditorDrag implements Drag {
  final void Function(Offset global) onUpdate;
  final void Function() onEnd;

  _EditorDrag({required this.onUpdate, required this.onEnd});

  @override
  void update(DragUpdateDetails details) => onUpdate(details.globalPosition);

  @override
  void end(DragEndDetails details) => onEnd();

  @override
  void cancel() => onEnd();
}

Widget _immediateDrag({required Drag? Function(Offset position) onStart, required Widget child}) => RawGestureDetector(
  behavior: HitTestBehavior.opaque,
  gestures: {
    ImmediateMultiDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
      ImmediateMultiDragGestureRecognizer.new,
      (recognizer) => recognizer.onStart = onStart,
    ),
  },
  child: child,
);

// -------------------------------------------------------------------------------------------------------------------
// Region editor
// -------------------------------------------------------------------------------------------------------------------

/// One normalized region: `{ "shape": "rect" | "ellipse", "x", "y", "width", "height", ...extra }` (0..1).
typedef PluginRegion = Map<String, dynamic>;

/// `regionEditor` node: draw, move, resize and delete boxes or ellipses over a photo or a video frame.
class PluginRegionEditor extends StatefulWidget {
  final PluginKernel kernel;
  final String plugin;
  final String? pluginsRoot;
  final String? assetId;
  final String? file;
  final int? timeMs;
  final int? durationMs;
  final bool scrubber;
  final List<PluginRegion> value;
  final List<String> shapes;
  final int? maxShapes;
  final Color? color;
  final double? aspectRatio;
  final ValueChanged<List<PluginRegion>> onChanged;
  final ValueChanged<int>? onSeek;

  const PluginRegionEditor({
    super.key,
    required this.kernel,
    required this.plugin,
    required this.value,
    required this.onChanged,
    this.pluginsRoot,
    this.assetId,
    this.file,
    this.timeMs,
    this.durationMs,
    this.scrubber = true,
    this.shapes = const ['rect', 'ellipse'],
    this.maxShapes,
    this.color,
    this.aspectRatio,
    this.onSeek,
  });

  @override
  State<PluginRegionEditor> createState() => _PluginRegionEditorState();
}

enum _RegionMode { create, move, resize }

class _PluginRegionEditorState extends State<PluginRegionEditor> {
  final _box = GlobalKey();
  late List<PluginRegion> _regions = _copy(widget.value);
  int? _selected;
  late String _shape = widget.shapes.isEmpty ? 'rect' : widget.shapes.first;
  PluginLoadedImage? _image;
  var _loading = true;
  late int _timeMs = widget.timeMs ?? 0;
  int? _durationMs;

  _RegionMode? _mode;
  Offset? _start;
  PluginRegion? _origin;
  int _corner = 0;
  var _moved = false;

  static List<PluginRegion> _copy(List<PluginRegion> regions) => [for (final region in regions) Map.of(region)];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PluginRegionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_mode == null && !_sameRegions(oldWidget.value, widget.value) && !_sameRegions(widget.value, _regions)) {
      _regions = _copy(widget.value);
      _selected = null;
    }
    if (oldWidget.assetId != widget.assetId || oldWidget.file != widget.file) {
      _timeMs = widget.timeMs ?? 0;
      unawaited(_load());
    } else if (oldWidget.timeMs != widget.timeMs && widget.timeMs != null && widget.timeMs != _timeMs) {
      _timeMs = widget.timeMs!;
      unawaited(_load());
    }
  }

  static bool _sameRegions(List<PluginRegion> a, List<PluginRegion> b) => jsonHash(a) == jsonHash(b);

  Future<void> _load() async {
    setState(() => _loading = true);
    final assetId = widget.assetId;
    PluginLoadedImage? image;
    int? duration = widget.durationMs;
    try {
      image = await loadPluginEditorImage(
        widget.kernel,
        widget.plugin,
        file: widget.file,
        assetId: assetId,
        timeMs: _timeMs > 0 ? _timeMs : null,
        pluginsRoot: widget.pluginsRoot,
      );
      if (duration == null && assetId != null) {
        final asset = await widget.kernel.findAsset(assetId);
        duration = asset != null && asset.isVideo ? asset.durationMs : null;
      }
    } catch (_) {
      image = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _image = image;
      _durationMs = duration;
      _loading = false;
    });
  }

  Rect _rectOf(PluginRegion region, Size size) {
    double read(String key) => (region[key] as num?)?.toDouble() ?? 0;
    return Rect.fromLTWH(
      read('x') * size.width,
      read('y') * size.height,
      read('width') * size.width,
      read('height') * size.height,
    );
  }

  PluginRegion _withRect(PluginRegion base, Rect rect, Size size) {
    final normalized = Rect.fromLTRB(
      (rect.left / size.width).clamp(0.0, 1.0),
      (rect.top / size.height).clamp(0.0, 1.0),
      (rect.right / size.width).clamp(0.0, 1.0),
      (rect.bottom / size.height).clamp(0.0, 1.0),
    );
    double round(double value) => (value * 10000).roundToDouble() / 10000;
    return {
      ...base,
      'x': round(normalized.left),
      'y': round(normalized.top),
      'width': round(normalized.width),
      'height': round(normalized.height),
    };
  }

  Size? get _size => (_box.currentContext?.findRenderObject() as RenderBox?)?.size;

  Offset? _local(Offset global) {
    final box = _box.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  int? _hit(Offset point, Size size) {
    for (var index = _regions.length - 1; index >= 0; index--) {
      if (_rectOf(_regions[index], size).inflate(8).contains(point)) {
        return index;
      }
    }
    return null;
  }

  int? _handleAt(Offset point, Size size) {
    final selected = _selected;
    if (selected == null || selected >= _regions.length) {
      return null;
    }
    final rect = _rectOf(_regions[selected], size);
    final corners = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight];
    for (var index = 0; index < corners.length; index++) {
      if ((corners[index] - point).distance < 24) {
        return index;
      }
    }
    return null;
  }

  Drag? _onStart(Offset global) {
    final size = _size;
    final point = _local(global);
    if (_mode != null || size == null || point == null || size.isEmpty) {
      return null;
    }
    _start = point;
    _moved = false;
    final handle = _handleAt(point, size);
    if (handle != null) {
      _mode = _RegionMode.resize;
      _corner = handle;
      _origin = Map.of(_regions[_selected!]);
    } else {
      final hit = _hit(point, size);
      if (hit != null) {
        _mode = _RegionMode.move;
        setState(() => _selected = hit);
        _origin = Map.of(_regions[hit]);
      } else {
        _mode = _RegionMode.create;
        _origin = null;
      }
    }
    return _EditorDrag(onUpdate: _onUpdate, onEnd: _onEnd);
  }

  void _onUpdate(Offset global) {
    final size = _size;
    final point = _local(global);
    final start = _start;
    if (size == null || point == null || start == null) {
      return;
    }
    if (!_moved && (point - start).distance < 6) {
      return;
    }
    _moved = true;
    final bounds = Offset.zero & size;
    final clamped = Offset(point.dx.clamp(0, size.width), point.dy.clamp(0, size.height));
    setState(() {
      switch (_mode) {
        case _RegionMode.create:
          final rect = Rect.fromPoints(Offset(start.dx.clamp(0, size.width), start.dy.clamp(0, size.height)), clamped);
          if (_origin == null) {
            if (widget.maxShapes != null && _regions.length >= widget.maxShapes!) {
              return;
            }
            _origin = {'shape': _shape};
            _regions.add(_withRect(_origin!, rect, size));
            _selected = _regions.length - 1;
          } else {
            _regions[_selected!] = _withRect(_origin!, rect, size);
          }
        case _RegionMode.move:
          final rect = _rectOf(_origin!, size).shift(point - start);
          final dx = rect.left < 0 ? -rect.left : (rect.right > bounds.right ? bounds.right - rect.right : 0.0);
          final dy = rect.top < 0 ? -rect.top : (rect.bottom > bounds.bottom ? bounds.bottom - rect.bottom : 0.0);
          _regions[_selected!] = _withRect(_origin!, rect.shift(Offset(dx, dy)), size);
        case _RegionMode.resize:
          final rect = _rectOf(_origin!, size);
          final fixed = switch (_corner) {
            0 => rect.bottomRight,
            1 => rect.bottomLeft,
            2 => rect.topRight,
            _ => rect.topLeft,
          };
          _regions[_selected!] = _withRect(_origin!, Rect.fromPoints(fixed, clamped), size);
        case null:
          break;
      }
    });
  }

  void _onEnd() {
    final size = _size;
    final start = _start;
    final mode = _mode;
    _mode = null;
    _start = null;
    if (!_moved) {
      if (mode == _RegionMode.create && size != null && start != null) {
        setState(() => _selected = _hit(start, size));
      }
      return;
    }
    final selected = _selected;
    if (mode == _RegionMode.create && selected != null && size != null) {
      final rect = _rectOf(_regions[selected], size);
      if (rect.width < 8 || rect.height < 8) {
        setState(() {
          _regions.removeAt(selected);
          _selected = null;
        });
        return;
      }
    }
    widget.onChanged(_copy(_regions));
  }

  void _delete() {
    final selected = _selected;
    if (selected == null || selected >= _regions.length) {
      return;
    }
    setState(() {
      _regions.removeAt(selected);
      _selected = null;
    });
    widget.onChanged(_copy(_regions));
  }

  void _clear() {
    setState(() {
      _regions = [];
      _selected = null;
    });
    widget.onChanged(const []);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final aspect = widget.aspectRatio ?? _image?.aspect ?? 4 / 3;
    final duration = _durationMs;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (widget.shapes.length > 1)
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final shape in widget.shapes)
                    ButtonSegment(
                      value: shape,
                      icon: Icon(shape == 'ellipse' ? Icons.circle_outlined : Icons.crop_square),
                      tooltip: shape,
                    ),
                ],
                selected: {_shape},
                onSelectionChanged: (selection) => setState(() => _shape = selection.first),
              ),
            const Spacer(),
            Text('${_regions.length}', style: Theme.of(context).textTheme.labelMedium),
            IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected == null ? null : _delete,
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.layers_clear_outlined),
              onPressed: _regions.isEmpty ? null : _clear,
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
            var width = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
            if (width / aspect > maxHeight) {
              width = maxHeight * aspect;
            }
            return Center(
              child: SizedBox(
                key: _box,
                width: width,
                height: width / aspect,
                child: _immediateDrag(
                  onStart: _onStart,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PluginEditorImage(image: _image),
                      if (_loading) const Center(child: CircularProgressIndicator()),
                      CustomPaint(
                        painter: _RegionPainter(
                          regions: _regions,
                          selected: _selected,
                          color: widget.color ?? scheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.scrubber && duration != null && duration > 0)
          Row(
            children: [
              Text(_formatMs(_timeMs), style: Theme.of(context).textTheme.labelSmall),
              Expanded(
                child: Slider(
                  value: _timeMs.clamp(0, duration).toDouble(),
                  max: duration.toDouble(),
                  onChanged: (value) => setState(() => _timeMs = value.round()),
                  onChangeEnd: (value) {
                    _timeMs = value.round();
                    widget.onSeek?.call(_timeMs);
                    unawaited(_load());
                  },
                ),
              ),
              Text(_formatMs(duration), style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
      ],
    );
  }
}

String _formatMs(int ms) {
  final seconds = ms ~/ 1000;
  final tenths = (ms % 1000) ~/ 100;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.$tenths';
}

class _RegionPainter extends CustomPainter {
  final List<PluginRegion> regions;
  final int? selected;
  final Color color;

  const _RegionPainter({required this.regions, required this.selected, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = color;
    final fill = Paint()..color = color.withValues(alpha: 0.18);
    final handle = Paint()..color = color;
    for (final (index, region) in regions.indexed) {
      double read(String key) => (region[key] as num?)?.toDouble() ?? 0;
      final rect = Rect.fromLTWH(
        read('x') * size.width,
        read('y') * size.height,
        read('width') * size.width,
        read('height') * size.height,
      );
      if (region['shape'] == 'ellipse') {
        canvas
          ..drawOval(rect, fill)
          ..drawOval(rect, stroke);
      } else {
        canvas
          ..drawRect(rect, fill)
          ..drawRect(rect, stroke);
      }
      if (index == selected) {
        for (final corner in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
          canvas.drawCircle(corner, 7, handle);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RegionPainter oldDelegate) => true;
}

// -------------------------------------------------------------------------------------------------------------------
// Canvas
// -------------------------------------------------------------------------------------------------------------------

/// `canvas` node value: `{ "strokes": [{ "points": [x0, y0, x1, y1, ...], "color": "#AARRGGBB", "width": fraction }],
/// "points": [{ "x", "y", "color"? }] }` (coordinates and widths relative to the canvas size).
class PluginCanvasEditor extends StatefulWidget {
  final PluginKernel kernel;
  final String plugin;
  final String? pluginsRoot;
  final Map<String, dynamic> value;
  final String mode;
  final List<String> modes;
  final Color color;
  final double strokeWidth;
  final double? aspectRatio;
  final Color? background;
  final String? assetId;
  final String? file;
  final int? timeMs;
  final ValueChanged<Map<String, dynamic>> onChanged;

  const PluginCanvasEditor({
    super.key,
    required this.kernel,
    required this.plugin,
    required this.value,
    required this.onChanged,
    required this.color,
    this.pluginsRoot,
    this.mode = 'stroke',
    this.modes = const ['stroke'],
    this.strokeWidth = 4,
    this.aspectRatio,
    this.background,
    this.assetId,
    this.file,
    this.timeMs,
  });

  @override
  State<PluginCanvasEditor> createState() => _PluginCanvasEditorState();
}

class _PluginCanvasEditorState extends State<PluginCanvasEditor> {
  final _box = GlobalKey();
  late List<Map<String, dynamic>> _strokes = _strokesOf(widget.value);
  late List<Map<String, dynamic>> _points = _pointsOf(widget.value);
  late String _mode = widget.mode;
  final List<String> _history = [];
  List<double>? _current;
  PluginLoadedImage? _image;

  static List<Map<String, dynamic>> _strokesOf(Map<String, dynamic> value) => [
    for (final stroke in (value['strokes'] is List ? value['strokes'] as List : const []).whereType<Map>())
      Map<String, dynamic>.from(stroke),
  ];

  static List<Map<String, dynamic>> _pointsOf(Map<String, dynamic> value) => [
    for (final point in (value['points'] is List ? value['points'] as List : const []).whereType<Map>())
      Map<String, dynamic>.from(point),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.assetId != null || widget.file != null) {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(PluginCanvasEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_current == null && jsonHash(oldWidget.value) != jsonHash(widget.value) && jsonHash(widget.value) != jsonHash(_json)) {
      _strokes = _strokesOf(widget.value);
      _points = _pointsOf(widget.value);
    }
    if (oldWidget.assetId != widget.assetId || oldWidget.file != widget.file || oldWidget.timeMs != widget.timeMs) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final image = await loadPluginEditorImage(
      widget.kernel,
      widget.plugin,
      file: widget.file,
      assetId: widget.assetId,
      timeMs: widget.timeMs,
      pluginsRoot: widget.pluginsRoot,
    );
    if (mounted) {
      setState(() => _image = image);
    }
  }

  Map<String, dynamic> get _json => {'strokes': _strokes, 'points': _points};

  Size? get _size => (_box.currentContext?.findRenderObject() as RenderBox?)?.size;

  Offset? _normalized(Offset global) {
    final box = _box.currentContext?.findRenderObject() as RenderBox?;
    final size = box?.size;
    if (box == null || size == null || size.isEmpty) {
      return null;
    }
    final local = box.globalToLocal(global);
    return Offset((local.dx / size.width).clamp(0.0, 1.0), (local.dy / size.height).clamp(0.0, 1.0));
  }

  double _round(double value) => (value * 10000).roundToDouble() / 10000;

  Drag? _onStart(Offset global) {
    final point = _normalized(global);
    if (point == null || _current != null) {
      return null;
    }
    _history.add(jsonEncodeSafe(_json));
    if (_mode == 'point') {
      setState(() => _points.add({'x': _round(point.dx), 'y': _round(point.dy), 'color': pluginColorHex(widget.color)}));
      widget.onChanged(_json);
      return null;
    }
    final size = _size!;
    setState(() {
      _current = [_round(point.dx), _round(point.dy)];
      _strokes.add({
        'points': _current,
        'color': pluginColorHex(widget.color),
        'width': _round(widget.strokeWidth / size.width),
      });
    });
    return _EditorDrag(
      onUpdate: (global) {
        final next = _normalized(global);
        final current = _current;
        if (next == null || current == null) {
          return;
        }
        setState(() => current.addAll([_round(next.dx), _round(next.dy)]));
      },
      onEnd: () {
        _current = null;
        widget.onChanged(_json);
      },
    );
  }

  void _undo() {
    if (_history.isEmpty) {
      return;
    }
    final previous = decodeJsonSafe(_history.removeLast());
    setState(() {
      _strokes = _strokesOf(previous);
      _points = _pointsOf(previous);
    });
    widget.onChanged(_json);
  }

  void _clear() {
    _history.add(jsonEncodeSafe(_json));
    setState(() {
      _strokes = [];
      _points = [];
    });
    widget.onChanged(_json);
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.aspectRatio ?? _image?.aspect ?? 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (widget.modes.length > 1)
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  for (final mode in widget.modes)
                    ButtonSegment(
                      value: mode,
                      icon: Icon(mode == 'point' ? Icons.add_location_alt_outlined : Icons.gesture),
                      tooltip: mode,
                    ),
                ],
                selected: {_mode},
                onSelectionChanged: (selection) => setState(() => _mode = selection.first),
              ),
            const Spacer(),
            IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo), onPressed: _history.isEmpty ? null : _undo),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.layers_clear_outlined),
              onPressed: _strokes.isEmpty && _points.isEmpty ? null : _clear,
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
            var width = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
            if (width / aspect > maxHeight) {
              width = maxHeight * aspect;
            }
            return Center(
              child: SizedBox(
                key: _box,
                width: width,
                height: width / aspect,
                child: _immediateDrag(
                  onStart: _onStart,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.assetId != null || widget.file != null)
                        PluginEditorImage(image: _image)
                      else
                        ColoredBox(color: widget.background ?? Theme.of(context).colorScheme.surfaceContainerHighest),
                      CustomPaint(painter: _CanvasPainter(strokes: _strokes, points: _points)),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final List<Map<String, dynamic>> strokes;
  final List<Map<String, dynamic>> points;

  const _CanvasPainter({required this.strokes, required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      final coords = (stroke['points'] is List ? stroke['points'] as List : const []).whereType<num>().toList();
      if (coords.length < 2) {
        continue;
      }
      final paint = Paint()
        ..color = Color(parsePluginColor(stroke['color']) ?? 0xFFFF0000)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(1, ((stroke['width'] as num?)?.toDouble() ?? 0.01) * size.width);
      final path = Path()..moveTo(coords[0] * size.width, coords[1] * size.height);
      for (var index = 2; index + 1 < coords.length; index += 2) {
        path.lineTo(coords[index] * size.width, coords[index + 1] * size.height);
      }
      if (coords.length == 2) {
        canvas.drawCircle(Offset(coords[0] * size.width, coords[1] * size.height), paint.strokeWidth / 2, paint);
      } else {
        canvas.drawPath(path, paint);
      }
    }
    for (final point in points) {
      final x = (point['x'] as num?)?.toDouble() ?? 0;
      final y = (point['y'] as num?)?.toDouble() ?? 0;
      final color = Color(parsePluginColor(point['color']) ?? 0xFFFF0000);
      canvas
        ..drawCircle(Offset(x * size.width, y * size.height), 7, Paint()..color = color)
        ..drawCircle(
          Offset(x * size.width, y * size.height),
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFFFFFFFF),
        );
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter oldDelegate) => true;
}

/// JSON encode that never throws (non-JSON values become strings).
String jsonEncodeSafe(Object? value) => jsonEncode(value, toEncodable: (value) => '$value');

/// Decodes a JSON object, or returns an empty map.
Map<String, dynamic> decodeJsonSafe(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}
