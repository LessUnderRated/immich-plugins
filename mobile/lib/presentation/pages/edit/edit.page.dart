import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:immich_mobile/utils/mosaic.utils.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:openapi/api.dart' show MirrorAxis, MirrorParameters, RotateParameters;

@RoutePage()
class EditImagePage extends ConsumerStatefulWidget {
  final Image image;
  final Future<void> Function(List<AssetEdit> edits) applyEdits;

  const EditImagePage({super.key, required this.image, required this.applyEdits});

  @override
  ConsumerState<EditImagePage> createState() => _EditImagePageState();
}

class _EditImagePageState extends ConsumerState<EditImagePage> with TickerProviderStateMixin {
  Future<void> _saveEditedImage() async {
    ref.read(editorStateProvider.notifier).setIsEditing(true);

    final editorState = ref.read(editorStateProvider);
    final cropParameters = convertRectToCropParameters(
      editorState.crop,
      editorState.originalWidth,
      editorState.originalHeight,
    );
    final edits = <AssetEdit>[];

    if (cropParameters.width != editorState.originalWidth || cropParameters.height != editorState.originalHeight) {
      edits.add(CropEdit(cropParameters));
    }

    if (editorState.flipHorizontal) {
      edits.add(MirrorEdit(MirrorParameters(axis: MirrorAxis.horizontal)));
    }

    if (editorState.flipVertical) {
      edits.add(MirrorEdit(MirrorParameters(axis: MirrorAxis.vertical)));
    }

    final normalizedRotation = (editorState.rotationAngle % 360 + 360) % 360;
    if (normalizedRotation != 0) {
      edits.add(RotateEdit(RotateParameters(angle: normalizedRotation)));
    }

    final mosaicParameters = mosaicToParameters(
      editorState.mosaicStrokes,
      editorState.mosaicBlockSize,
      editorState.originalWidth,
      editorState.originalHeight,
    );
    if (mosaicParameters != null) {
      edits.add(MosaicEdit(mosaicParameters));
    }

    try {
      await widget.applyEdits(edits);
      if (!mounted) {
        return;
      }

      ImmichToast.show(context: context, msg: context.t.success, toastType: ToastType.success);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) {
        return;
      }

      ImmichToast.show(context: context, msg: context.t.error_title, toastType: ToastType.error);
    } finally {
      ref.read(editorStateProvider.notifier).setIsEditing(false);
    }
  }

  Future<bool?> _showDiscardChangesDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.editor_discard_edits_title),
        content: Text(context.t.editor_discard_edits_prompt),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.all(context.themeData.colorScheme.onSurfaceVariant),
            ),
            child: Text(context.t.cancel),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t.confirm)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));
    final mode = ref.watch(editorStateProvider.select((state) => state.mode));

    return PopScope(
      canPop: !hasUnsavedEdits,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        final shouldDiscard = await _showDiscardChangesDialog() ?? false;
        if (shouldDiscard && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Theme(
        data: getThemeData(colorScheme: ref.watch(immichThemeProvider).dark, locale: context.locale),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(context.t.edit),
            leading: ImmichCloseButton(onPressed: () => Navigator.of(context).maybePop()),
            actions: [_SaveEditsButton(onSave: _saveEditedImage)],
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(
                  child: switch (mode) {
                    EditorMode.transform => _EditorPreview(image: widget.image),
                    EditorMode.mosaic => _MosaicCanvas(image: widget.image),
                  },
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: ref.watch(immichThemeProvider).dark.surface,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _EditorModeSelector(),
                        switch (mode) {
                          EditorMode.transform => const _TransformControls(),
                          EditorMode.mosaic => const _MosaicControls(),
                        },
                        const Padding(
                          padding: EdgeInsets.only(bottom: 36, left: 24, right: 24),
                          child: Row(children: [Spacer(), _ResetEditsButton()]),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AspectRatioButton extends StatelessWidget {
  final CropAspectRatio ratio;
  final bool isSelected;
  final VoidCallback onPressed;

  const _AspectRatioButton({required this.ratio, required this.isSelected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? context.primaryColor : context.themeData.iconTheme.color;

    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        IconButton(
          iconSize: 36,
          icon: ratio.ratio != null
              ? _AspectRatioRect(ratio: ratio.ratio!, color: color)
              : Icon(ratio.icon, color: color),
          onPressed: onPressed,
        ),
        Text(switch (ratio) {
          CropAspectRatio.free => context.t.crop_aspect_ratio_free,
          CropAspectRatio.original => context.t.crop_aspect_ratio_original,
          _ => '${ratio.numerator}:${ratio.denominator}',
        }, style: context.textTheme.displayMedium),
      ],
    );
  }
}

class _AspectRatioRect extends StatelessWidget {
  final double ratio;
  final Color? color;

  const _AspectRatioRect({required this.ratio, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: AspectRatio(
          aspectRatio: ratio,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: color ?? Colors.transparent, width: 3),
              borderRadius: const BorderRadius.all(Radius.circular(4)),
            ),
          ),
        ),
      ),
    );
  }
}

class _AspectRatioSelector extends ConsumerWidget {
  const _AspectRatioSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: CropAspectRatio.values.map((entry) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _AspectRatioButton(
              ratio: entry,
              isSelected: editorState.aspectRatio == entry,
              onPressed: () => editorNotifier.setAspectRatio(entry),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TransformControls extends ConsumerWidget {
  const _TransformControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  ImmichIconButton(
                    icon: Icons.rotate_left,
                    variant: ImmichVariant.ghost,
                    color: ImmichColor.secondary,
                    onPressed: editorNotifier.rotateCCW,
                  ),
                  const SizedBox(width: 8),
                  ImmichIconButton(
                    icon: Icons.rotate_right,
                    variant: ImmichVariant.ghost,
                    color: ImmichColor.secondary,
                    onPressed: editorNotifier.rotateCW,
                  ),
                ],
              ),
              Row(
                children: [
                  ImmichIconButton(
                    icon: Icons.flip,
                    variant: ImmichVariant.ghost,
                    color: ImmichColor.secondary,
                    onPressed: editorNotifier.flipHorizontally,
                  ),
                  const SizedBox(width: 8),
                  Transform.rotate(
                    angle: pi / 2,
                    child: ImmichIconButton(
                      icon: Icons.flip,
                      variant: ImmichVariant.ghost,
                      color: ImmichColor.secondary,
                      onPressed: editorNotifier.flipVertically,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const _AspectRatioSelector(),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _SaveEditsButton extends ConsumerWidget {
  final VoidCallback onSave;

  const _SaveEditsButton({required this.onSave});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isApplyingEdits = ref.watch(editorStateProvider.select((state) => state.isApplyingEdits));
    final hasUnsavedEdits = ref.watch(editorStateProvider.select((state) => state.hasUnsavedEdits));

    return isApplyingEdits
        ? const Padding(
            padding: EdgeInsets.all(8.0),
            child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          )
        : ImmichIconButton(
            icon: Icons.done_rounded,
            color: ImmichColor.primary,
            variant: ImmichVariant.ghost,
            disabled: !hasUnsavedEdits,
            onPressed: onSave,
          );
  }
}

class _ResetEditsButton extends ConsumerWidget {
  const _ResetEditsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return ImmichTextButton(
      labelText: context.t.reset,
      onPressed: editorNotifier.resetEdits,
      variant: ImmichVariant.ghost,
      expanded: false,
      disabled: !editorState.hasEdits || editorState.isApplyingEdits,
    );
  }
}

class _EditorPreview extends ConsumerStatefulWidget {
  final Image image;

  const _EditorPreview({required this.image});

  @override
  ConsumerState<_EditorPreview> createState() => _EditorPreviewState();
}

class _EditorPreviewState extends ConsumerState<_EditorPreview> with TickerProviderStateMixin {
  late final CropController cropController;

  @override
  void initState() {
    super.initState();

    cropController = CropController();
    cropController.crop = ref.read(editorStateProvider.select((state) => state.crop));
    cropController.addListener(onCrop);
  }

  void onCrop() {
    if (!mounted || cropController.crop == ref.read(editorStateProvider).crop) {
      return;
    }

    ref.read(editorStateProvider.notifier).setCrop(cropController.crop);
  }

  @override
  void dispose() {
    cropController.removeListener(onCrop);
    cropController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    ref.listen(editorStateProvider, (previous, current) {
      // Only re-apply the aspect ratio when it changes, otherwise the crop rect will shrink on every rotation
      if (previous?.aspectRatio != current.aspectRatio) {
        double? ratio;

        ratio = switch (current.aspectRatio) {
          CropAspectRatio.original => current.originalWidth / current.originalHeight,
          _ => current.aspectRatio.ratio,
        };

        if (current.rotationAngle % 180 != 0) {
          ratio = ratio != null ? 1 / ratio : null;
        }

        cropController.aspectRatio = ratio;
      }

      if (cropController.crop != current.crop) {
        cropController.crop = current.crop;
      }
    });

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Calculate the bounding box size needed for the rotated container
        final baseWidth = constraints.maxWidth * 0.9;
        final baseHeight = constraints.maxHeight * 0.95;

        return Center(
          child: AnimatedRotation(
            turns: editorState.rotationAngle / 360,
            duration: editorState.animationDuration,
            curve: Curves.easeInOut,
            onEnd: editorNotifier.normalizeRotation,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..scaleByDouble(
                  editorState.flipHorizontal ? -1.0 : 1.0,
                  editorState.flipVertical ? -1.0 : 1.0,
                  1.0,
                  1.0,
                ),
              child: AnimatedContainer(
                duration: editorState.animationDuration,
                curve: Curves.easeInOut,
                padding: const EdgeInsets.all(10),
                width: (editorState.rotationAngle % 180 == 0) ? baseWidth : baseHeight,
                height: (editorState.rotationAngle % 180 == 0) ? baseHeight : baseWidth,
                child: CropImage(controller: cropController, image: widget.image, gridColor: Colors.white),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EditorModeSelector extends ConsumerWidget {
  const _EditorModeSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(editorStateProvider.select((state) => state.mode));

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 16),
      child: SegmentedButton<EditorMode>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: EditorMode.transform, icon: const Icon(Icons.crop_rotate), label: Text(context.t.crop)),
          ButtonSegment(value: EditorMode.mosaic, icon: const Icon(Icons.grid_on), label: Text(context.t.mosaic)),
        ],
        selected: {mode},
        onSelectionChanged: (selection) => ref.read(editorStateProvider.notifier).setMode(selection.first),
      ),
    );
  }
}

class _MosaicControls extends ConsumerWidget {
  const _MosaicControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editorState = ref.watch(editorStateProvider);
    final editorNotifier = ref.watch(editorStateProvider.notifier);
    final isBrush = editorState.mosaicTool == MosaicTool.brush;

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, top: 12, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _MosaicToolButton(
                icon: Icons.brush,
                label: context.t.mosaic_brush,
                isSelected: isBrush,
                onPressed: () => editorNotifier.setMosaicTool(MosaicTool.brush),
              ),
              const SizedBox(width: 8),
              _MosaicToolButton(
                icon: Icons.auto_fix_normal,
                label: context.t.mosaic_eraser,
                isSelected: !isBrush,
                onPressed: () => editorNotifier.setMosaicTool(MosaicTool.eraser),
              ),
              const Spacer(),
              ImmichIconButton(
                icon: Icons.undo,
                variant: ImmichVariant.ghost,
                color: ImmichColor.secondary,
                disabled: editorState.mosaicStrokes.isEmpty,
                onPressed: editorNotifier.undoMosaicStroke,
              ),
            ],
          ),
          _MosaicSlider(
            label: context.t.mosaic_brush_size,
            value: editorState.mosaicBrushSize,
            min: minMosaicBrushSize,
            max: maxMosaicBrushSize,
            onChanged: editorNotifier.setMosaicBrushSize,
          ),
          _MosaicSlider(
            label: context.t.mosaic_block_size,
            value: editorState.mosaicBlockSize,
            min: minMosaicBlockSize,
            max: maxMosaicBlockSize,
            onChanged: editorNotifier.setMosaicBlockSize,
          ),
        ],
      ),
    );
  }
}

class _MosaicToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onPressed;

  const _MosaicToolButton({required this.icon, required this.label, required this.isSelected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? context.primaryColor : context.themeData.iconTheme.color;

    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: color),
      label: Text(label, style: TextStyle(color: color)),
      style: TextButton.styleFrom(backgroundColor: isSelected ? context.primaryColor.withValues(alpha: 0.15) : null),
    );
  }
}

class _MosaicSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _MosaicSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label, style: context.textTheme.bodyMedium)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }
}

class _MosaicCanvas extends ConsumerStatefulWidget {
  final Image image;

  const _MosaicCanvas({required this.image});

  @override
  ConsumerState<_MosaicCanvas> createState() => _MosaicCanvasState();
}

class _MosaicCanvasState extends ConsumerState<_MosaicCanvas> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ui.Image? _source;
  ui.Image? _pixelated;
  int _pixelatedBlockPixels = 0;
  int _pixelationRequest = 0;

  final List<Offset> _activePoints = [];
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  int? _activePointer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  void _resolveImage() {
    final stream = widget.image.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _imageStream?.key) {
      return;
    }

    _stopListening();
    final listener = ImageStreamListener((info, _) {
      if (!mounted) {
        info.image.dispose();
        return;
      }

      _source?.dispose();
      setState(() {
        _source = info.image;
        _pixelatedBlockPixels = 0;
      });
      _schedulePixelation();
    });
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  void _stopListening() {
    final listener = _imageListener;
    if (listener != null) {
      _imageStream?.removeListener(listener);
    }
  }

  void _schedulePixelation() {
    final source = _source;
    final editorState = ref.read(editorStateProvider);
    final width = editorState.originalWidth;
    final height = editorState.originalHeight;
    if (source == null || width <= 0 || height <= 0) {
      return;
    }

    final blockPixels = mosaicBlockPixels(editorState.mosaicBlockSize, width, height);
    if (blockPixels == _pixelatedBlockPixels && _pixelated != null) {
      return;
    }

    final request = ++_pixelationRequest;
    unawaited(
      _pixelate(source, blockPixels, width, height).then((image) {
        if (!mounted || request != _pixelationRequest) {
          image.dispose();
          return;
        }

        _pixelated?.dispose();
        setState(() {
          _pixelated = image;
          _pixelatedBlockPixels = blockPixels;
        });
      }),
    );
  }

  Future<ui.Image> _pixelate(ui.Image source, int blockPixels, int width, int height) async {
    final blocksWide = (width / blockPixels).ceil();
    final blocksHigh = (height / blockPixels).ceil();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, blocksWide.toDouble(), blocksHigh.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(blocksWide, blocksHigh);
    } finally {
      picture.dispose();
    }
  }

  Offset _normalize(Offset position, Size size) {
    return Offset((position.dx / size.width).clamp(0.0, 1.0), (position.dy / size.height).clamp(0.0, 1.0));
  }

  void _onPointerDown(PointerDownEvent event, Size size) {
    if (_activePointer != null) {
      return;
    }

    _activePointer = event.pointer;
    _activePoints
      ..clear()
      ..add(_normalize(event.localPosition, size));
    _repaint.value++;
  }

  void _onPointerMove(PointerMoveEvent event, Size size) {
    if (event.pointer != _activePointer || _activePoints.length >= maxMosaicStrokePoints) {
      return;
    }

    final point = _normalize(event.localPosition, size);
    if ((point - _activePoints.last).distance < minMosaicPointDistance) {
      return;
    }

    _activePoints.add(point);
    _repaint.value++;
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer != _activePointer) {
      return;
    }

    _activePointer = null;
    if (event is PointerUpEvent) {
      ref.read(editorStateProvider.notifier).addMosaicStroke(List.of(_activePoints));
    }
    _activePoints.clear();
    _repaint.value++;
  }

  @override
  void dispose() {
    _stopListening();
    _source?.dispose();
    _pixelated?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);
    ref.listen(editorStateProvider.select((state) => state.mosaicBlockSize), (_, _) => _schedulePixelation());

    final source = _source;
    final width = editorState.originalWidth;
    final height = editorState.originalHeight;
    if (source == null || width <= 0 || height <= 0) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(constraints.maxWidth * 0.9, constraints.maxHeight * 0.95);
        final scale = min(available.width / width, available.height / height);
        final size = Size(width * scale, height * scale);

        return Center(
          child: SizedBox.fromSize(
            size: size,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _onPointerDown(event, size),
              onPointerMove: (event) => _onPointerMove(event, size),
              onPointerUp: _onPointerEnd,
              onPointerCancel: _onPointerEnd,
              child: CustomPaint(
                size: size,
                painter: _MosaicPainter(
                  source: source,
                  pixelated: _pixelated,
                  blockPixels: _pixelatedBlockPixels,
                  originalSize: Size(width.toDouble(), height.toDouble()),
                  strokes: editorState.mosaicStrokes,
                  activePoints: _activePoints,
                  activeBrushSize: editorState.mosaicBrushSize,
                  activeErase: editorState.mosaicTool == MosaicTool.eraser,
                  repaint: _repaint,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MosaicPainter extends CustomPainter {
  final ui.Image source;
  final ui.Image? pixelated;
  final int blockPixels;
  final Size originalSize;
  final List<MosaicStrokeDraft> strokes;
  final List<Offset> activePoints;
  final double activeBrushSize;
  final bool activeErase;

  const _MosaicPainter({
    required this.source,
    required this.pixelated,
    required this.blockPixels,
    required this.originalSize,
    required this.strokes,
    required this.activePoints,
    required this.activeBrushSize,
    required this.activeErase,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final pixelated = this.pixelated;
    if (pixelated == null) {
      return;
    }

    canvas.saveLayer(bounds, Paint());
    for (final stroke in strokes) {
      _drawStroke(canvas, size, stroke.points, stroke.brushSize, stroke.erase);
    }
    if (activePoints.isNotEmpty) {
      _drawStroke(canvas, size, activePoints, activeBrushSize, activeErase);
    }

    final scale = size.width / originalSize.width;
    canvas.drawImageRect(
      pixelated,
      Rect.fromLTWH(0, 0, pixelated.width.toDouble(), pixelated.height.toDouble()),
      Rect.fromLTWH(0, 0, pixelated.width * blockPixels * scale, pixelated.height * blockPixels * scale),
      Paint()
        ..filterQuality = FilterQuality.none
        ..blendMode = BlendMode.srcIn,
    );
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Size size, List<Offset> points, double brushSize, bool erase) {
    final width = brushSize * min(size.width, size.height);
    final paint = Paint()
      ..color = Colors.white
      ..blendMode = erase ? BlendMode.clear : BlendMode.srcOver
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width;

    final scaled = points.map((point) => Offset(point.dx * size.width, point.dy * size.height)).toList();
    if (scaled.length == 1) {
      canvas.drawCircle(scaled.first, width / 2, paint..style = PaintingStyle.fill);
      return;
    }

    final path = Path()..moveTo(scaled.first.dx, scaled.first.dy);
    for (final point in scaled.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_MosaicPainter oldDelegate) {
    return oldDelegate.source != source ||
        oldDelegate.pixelated != pixelated ||
        oldDelegate.blockPixels != blockPixels ||
        oldDelegate.strokes != strokes ||
        oldDelegate.activeBrushSize != activeBrushSize ||
        oldDelegate.activeErase != activeErase;
  }
}
