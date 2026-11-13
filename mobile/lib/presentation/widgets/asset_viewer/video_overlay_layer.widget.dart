import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_overlay_model.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/viewer/video_sessions.dart';

/// The rect a video of [videoSize] occupies when aspect-fitted (centered, `contain`) into [box].
Rect videoFrameRect(Size box, Size? videoSize) {
  if (videoSize == null || videoSize.isEmpty || box.isEmpty) {
    return Offset.zero & box;
  }
  final fitted = applyBoxFit(BoxFit.contain, videoSize, box);
  return Alignment.center.inscribe(fitted.destination, Offset.zero & box);
}

/// Reports where the video frame of [session] is on screen whenever its child is painted (zoom, layout and
/// page moves included). Cheap: a transform and a comparison per paint; nothing without a session.
class VideoFrameReporter extends SingleChildRenderObjectWidget {
  final VideoSession? session;

  const VideoFrameReporter({super.key, required this.session, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderVideoFrameReporter(session);

  @override
  void updateRenderObject(BuildContext context, RenderVideoFrameReporter renderObject) {
    renderObject.session = session;
  }
}

class RenderVideoFrameReporter extends RenderProxyBox {
  VideoSession? session;

  RenderVideoFrameReporter(this.session);

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final session = this.session;
    if (session == null || !attached || !hasSize) {
      return;
    }
    final local = videoFrameRect(size, session.videoSize);
    final global = MatrixUtils.transformRect(getTransformTo(null), local);
    VideoSessions.instance.reportFrame(session, global, size);
  }
}

/// The declarative overlay layer of a video session: shapes, images and text placed exactly over the video frame,
/// evaluated every frame against the session's playback clock (keyframes eased, velocities extrapolated).
///
/// Renders nothing (and runs no ticker) while no plugin has items for the session.
class VideoOverlayLayer extends StatefulWidget {
  final VideoSession session;

  const VideoOverlayLayer({super.key, required this.session});

  @override
  State<VideoOverlayLayer> createState() => _VideoOverlayLayerState();
}

class _VideoOverlayLayerState extends State<VideoOverlayLayer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));
  final _images = <String, ui.Image>{};
  final _loading = <String>{};
  List<VideoOverlayItem> _items = const [];

  VideoOverlayStore get _store => VideoSessions.instance.overlays;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onItems);
    widget.session.addListener(_onSession);
    _readItems();
  }

  @override
  void didUpdateWidget(VideoOverlayLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _readItems();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onItems);
    widget.session.removeListener(_onSession);
    _ticker.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  void _onItems() {
    if (mounted) {
      setState(_readItems);
    }
  }

  void _readItems() {
    _items = _store.itemsFor(widget.session.id, widget.session.asset.id);
    for (final item in _items) {
      final path = item.imagePath;
      if (path != null && !_images.containsKey(path) && _loading.add(path)) {
        unawaited(_loadImage(path));
      }
    }
    _updateTicker();
  }

  /// The session's playback state changed: redraw at the new position and start or stop ticking.
  void _onSession() {
    if (mounted) {
      setState(_updateTicker);
    }
  }

  /// Ticks only while there is something to move: items exist and the video plays. A paused video is drawn once
  /// at its position.
  void _updateTicker() {
    final run = _items.isNotEmpty && widget.session.isPlaying;
    if (run && !_ticker.isActive) {
      unawaited(_ticker.start());
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  Future<void> _loadImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _images[path] = frame.image);
    } catch (_) {
      // A missing or broken image is simply not drawn.
    } finally {
      _loading.remove(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return const SizedBox.shrink();
    }
    final t = widget.session.positionMs();
    return LayoutBuilder(
      builder: (context, constraints) {
        final frame = videoFrameRect(constraints.biggest, widget.session.videoSize);
        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (final item in _items)
                if (item.visibleAt(t)) ?_buildItem(item, t, frame),
            ],
          ),
        );
      },
    );
  }

  Widget? _buildItem(VideoOverlayItem item, int t, Rect frame) {
    final opacity = item.opacityAt(t);
    if (opacity <= 0) {
      return null;
    }
    final normalized = item.shape == VideoOverlayShape.path ? _pathBounds(item.pointsAt(t)) : item.rectAt(t);
    final rect = Rect.fromLTWH(
      frame.left + normalized.left * frame.width,
      frame.top + normalized.top * frame.height,
      normalized.width * frame.width,
      normalized.height * frame.height,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      return null;
    }

    Widget child;
    if (item.shape == VideoOverlayShape.image) {
      final image = _images[item.imagePath];
      if (image == null) {
        return null;
      }
      child = RawImage(image: image, fit: _fit(item.fit), width: rect.width, height: rect.height);
    } else if (item.shape == VideoOverlayShape.text) {
      child = CustomPaint(painter: _TextPainter(item, frame.height));
    } else {
      final clipper = _ShapeClipper(item, t, frame, rect);
      final blur = item.blur;
      child = CustomPaint(painter: _ShapePainter(item, clipper));
      if (blur != null && blur > 0) {
        child = ClipPath(
          clipper: clipper,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: SizedBox.expand(child: child),
          ),
        );
      }
    }
    if (opacity < 1) {
      child = Opacity(opacity: opacity, child: child);
    }
    return Positioned.fromRect(key: ValueKey(item.id), rect: rect, child: child);
  }

  static Rect _pathBounds(List<Offset> points) {
    if (points.isEmpty) {
      return Rect.zero;
    }
    var bounds = Rect.fromPoints(points.first, points.first);
    for (final point in points.skip(1)) {
      bounds = bounds.expandToInclude(Rect.fromPoints(point, point));
    }
    return bounds;
  }

  static BoxFit _fit(String fit) => switch (fit) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    'none' => BoxFit.none,
    'fitWidth' => BoxFit.fitWidth,
    'fitHeight' => BoxFit.fitHeight,
    _ => BoxFit.contain,
  };
}

/// The outline of a shape item in the coordinates of its own box.
class _ShapeClipper extends CustomClipper<Path> {
  final VideoOverlayItem item;
  final int t;
  final Rect frame;
  final Rect box;

  _ShapeClipper(this.item, this.t, this.frame, this.box);

  @override
  Path getClip(Size size) {
    final bounds = Offset.zero & size;
    switch (item.shape) {
      case VideoOverlayShape.ellipse:
        return Path()..addOval(bounds);
      case VideoOverlayShape.roundRect:
        final radius = math.min(size.width, size.height) * item.radius;
        return Path()..addRRect(RRect.fromRectAndRadius(bounds, Radius.circular(radius)));
      case VideoOverlayShape.path:
        final points = item.pointsAt(t);
        if (points.length < 3) {
          return Path()..addRect(bounds);
        }
        Offset local(Offset p) =>
            Offset(frame.left + p.dx * frame.width - box.left, frame.top + p.dy * frame.height - box.top);
        return Path()..addPolygon([for (final point in points) local(point)], true);
      default:
        return Path()..addRect(bounds);
    }
  }

  @override
  bool shouldReclip(_ShapeClipper oldClipper) => true;
}

class _ShapePainter extends CustomPainter {
  final VideoOverlayItem item;
  final _ShapeClipper clipper;

  _ShapePainter(this.item, this.clipper);

  @override
  void paint(Canvas canvas, Size size) {
    final path = clipper.getClip(size);
    final color = item.color;
    if (color != null) {
      canvas.drawPath(path, Paint()..color = color);
    }
    final stroke = item.strokeColor;
    if (stroke != null && item.strokeWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = item.strokeWidth,
      );
    }
  }

  @override
  bool shouldRepaint(_ShapePainter oldDelegate) => true;
}

class _TextPainter extends CustomPainter {
  final VideoOverlayItem item;
  final double frameHeight;

  _TextPainter(this.item, this.frameHeight);

  @override
  void paint(Canvas canvas, Size size) {
    final text = item.text;
    if (text == null || text.isEmpty) {
      return;
    }
    final fontSize = item.fontSize != null ? item.fontSize! * frameHeight : size.height * 0.8;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: item.color ?? const Color(0xFFFFFFFF),
          fontWeight: item.fontWeight == 'bold' ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    painter.paint(canvas, Offset((size.width - painter.width) / 2, (size.height - painter.height) / 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(_TextPainter oldDelegate) => true;
}
