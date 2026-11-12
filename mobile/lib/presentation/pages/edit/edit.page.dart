import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:crop_image/crop_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/censor_styles.dart';
import 'package:immich_mobile/presentation/pages/edit/editor.provider.dart';
import 'package:immich_mobile/presentation/pages/plugins/schema_form.widget.dart';
import 'package:immich_mobile/providers/device_plugins.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:immich_mobile/utils/error_handler.dart';
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
  final ValueNotifier<int> _pinches = ValueNotifier(0);
  Rect? _cropBeforeGesture;

  @override
  void dispose() {
    _pinches.dispose();
    super.dispose();
  }

  void _onFirstPointer() {
    _cropBeforeGesture = ref.read(editorStateProvider).crop;
  }

  void _restoreCropBeforeGesture() {
    final crop = _cropBeforeGesture;
    if (crop != null && ref.read(editorStateProvider).crop != crop) {
      ref.read(editorStateProvider.notifier).setCrop(crop);
    }
  }

  void _onPinchStart() {
    _pinches.value++;
    _restoreCropBeforeGesture();
  }

  void _onPinchEnd() => _restoreCropBeforeGesture();

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
            toolbarHeight: 44,
            titleSpacing: 0,
            title: Text(context.t.edit, style: const TextStyle(fontSize: 16)),
            leading: ImmichCloseButton(onPressed: () => Navigator.of(context).maybePop()),
            actions: [_SaveEditsButton(onSave: _saveEditedImage)],
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: _ZoomableEditorArea(
                    key: ValueKey(mode),
                    onPointerStart: _onFirstPointer,
                    onPinchStart: _onPinchStart,
                    onPinchEnd: _onPinchEnd,
                    child: switch (mode) {
                      EditorMode.transform => _EditorPreview(image: widget.image),
                      EditorMode.mosaic => _MosaicCanvas(image: widget.image, pinches: _pinches),
                    },
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  child: ColoredBox(
                    color: ref.watch(immichThemeProvider).dark.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          switch (mode) {
                            EditorMode.transform => const _TransformControls(),
                            EditorMode.mosaic => const _MosaicControls(),
                          },
                          const Row(children: [_EditorModeSelector(), Spacer(), _ResetEditsButton()]),
                        ],
                      ),
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

class _AspectRatioChip extends StatelessWidget {
  final CropAspectRatio ratio;
  final bool isSelected;
  final VoidCallback onPressed;

  const _AspectRatioChip({required this.ratio, required this.isSelected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? context.primaryColor : Colors.white70;
    final label = switch (ratio) {
      CropAspectRatio.free => context.t.crop_aspect_ratio_free,
      CropAspectRatio.original => context.t.crop_aspect_ratio_original,
      _ => '${ratio.numerator}:${ratio.denominator}',
    };

    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? context.primaryColor.withValues(alpha: 0.15) : null,
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ratio.ratio != null)
              _AspectRatioRect(ratio: ratio.ratio!, color: color)
            else
              Icon(ratio.icon, color: color, size: 16),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
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
      width: 16,
      height: 16,
      child: Center(
        child: AspectRatio(
          aspectRatio: ratio,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: color ?? Colors.transparent, width: 1.5),
              borderRadius: const BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool selected;
  final int quarterTurns;

  const _CompactIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.selected = false,
    this.quarterTurns = 0,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: const EdgeInsets.all(6),
      iconSize: 20,
      style: selected ? IconButton.styleFrom(backgroundColor: context.primaryColor.withValues(alpha: 0.15)) : null,
      icon: RotatedBox(quarterTurns: quarterTurns, child: Icon(icon)),
      color: selected ? context.primaryColor : Colors.white,
      onPressed: onPressed,
    );
  }
}

class _TransformControls extends ConsumerWidget {
  const _TransformControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final aspectRatio = ref.watch(editorStateProvider.select((state) => state.aspectRatio));
    final editorNotifier = ref.watch(editorStateProvider.notifier);

    return SizedBox(
      height: 40,
      child: Row(
        children: [
          _CompactIconButton(icon: Icons.rotate_left, tooltip: 'Rotate left', onPressed: editorNotifier.rotateCCW),
          _CompactIconButton(icon: Icons.rotate_right, tooltip: 'Rotate right', onPressed: editorNotifier.rotateCW),
          _CompactIconButton(icon: Icons.flip, tooltip: 'Flip', onPressed: editorNotifier.flipHorizontally),
          _CompactIconButton(
            icon: Icons.flip,
            tooltip: 'Flip vertically',
            quarterTurns: 1,
            onPressed: editorNotifier.flipVertically,
          ),
          const VerticalDivider(width: 12, indent: 8, endIndent: 8),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final ratio in CropAspectRatio.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                    child: _AspectRatioChip(
                      ratio: ratio,
                      isSelected: aspectRatio == ratio,
                      onPressed: () => editorNotifier.setAspectRatio(ratio),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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

    return SegmentedButton<EditorMode>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 12),
      ),
      segments: [
        ButtonSegment(
          value: EditorMode.transform,
          icon: const Icon(Icons.crop_rotate, size: 16),
          label: Text(context.t.crop),
        ),
        ButtonSegment(
          value: EditorMode.mosaic,
          icon: const Icon(Icons.grid_on, size: 16),
          label: Text(context.t.mosaic),
        ),
      ],
      selected: {mode},
      onSelectionChanged: (selection) => ref.read(editorStateProvider.notifier).setMode(selection.first),
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
    final width = editorState.originalWidth;
    final height = editorState.originalHeight;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              _CompactIconButton(
                icon: Icons.brush,
                tooltip: context.t.mosaic_brush,
                selected: isBrush,
                onPressed: () => editorNotifier.setMosaicTool(MosaicTool.brush),
              ),
              _CompactIconButton(
                icon: Icons.auto_fix_normal,
                tooltip: context.t.mosaic_eraser,
                selected: !isBrush,
                onPressed: () => editorNotifier.setMosaicTool(MosaicTool.eraser),
              ),
              const VerticalDivider(width: 12, indent: 8, endIndent: 8),
              _CompactIconButton(
                icon: Icons.undo,
                tooltip: context.t.undo,
                onPressed: editorState.mosaicStrokes.isEmpty ? null : editorNotifier.undoMosaicStroke,
              ),
              _CompactIconButton(
                icon: Icons.redo,
                tooltip: 'Redo',
                onPressed: editorState.mosaicRedoStrokes.isEmpty ? null : editorNotifier.redoMosaicStroke,
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _BrushPreview(
                  brushSize: editorState.mosaicBrushSize,
                  blockSize: editorState.mosaicBlockSize,
                  erase: !isBrush,
                ),
              ),
            ],
          ),
        ),
        const _CensorStylePicker(),
        _SizeControl(
          icon: Icons.circle_outlined,
          tooltip: context.t.mosaic_brush_size,
          value: editorState.mosaicBrushSize,
          min: minMosaicBrushSize,
          max: maxMosaicBrushSize,
          step: mosaicBrushStep,
          presets: const {'S': 0.02, 'M': 0.05, 'L': 0.1, 'XL': 0.2},
          valueLabel: '${mosaicBrushPixels(editorState.mosaicBrushSize, width, height)} px',
          onChanged: editorNotifier.setMosaicBrushSize,
        ),
        _SizeControl(
          icon: Icons.grid_view,
          tooltip: context.t.mosaic_block_size,
          value: editorState.mosaicBlockSize,
          min: minMosaicBlockSize,
          max: maxMosaicBlockSize,
          step: mosaicBlockStep,
          presets: const {'Fine': 0.01, 'Med': 0.025, 'Coarse': 0.05, 'Max': 0.1},
          valueLabel: '${mosaicBlockPixels(editorState.mosaicBlockSize, width, height)} px',
          onChanged: editorNotifier.setMosaicBlockSize,
        ),
      ],
    );
  }
}

class _CensorStylePicker extends ConsumerWidget {
  const _CensorStylePicker();

  Future<void> _editOptions(BuildContext context, WidgetRef ref, CensorStyleOption style) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final options = ref.watch(editorStateProvider.select((state) => state.mosaicStyleOptions));
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(style.title, style: Theme.of(context).textTheme.titleMedium),
                  if (style.description.isNotEmpty)
                    Text(style.description, style: Theme.of(context).textTheme.bodySmall),
                  SchemaForm(
                    schema: style.schema,
                    config: Map<String, dynamic>.from(options),
                    onChanged: ref.read(editorStateProvider.notifier).setMosaicStyleOptions,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = ref.watch(censorStyleOptionsProvider).valueOrNull ?? const <CensorStyleOption>[];
    final current = ref.watch(editorStateProvider.select((state) => state.mosaicStyle));
    if (styles.isEmpty) {
      return const SizedBox(
        height: 36,
        child: Center(
          child: Text('Install a censor style plugin to use mosaic', style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final selected = styles.where((style) => style.key == current).firstOrNull ?? styles.first;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.auto_awesome_mosaic_outlined, size: 16, color: Colors.white70),
          ),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final style in styles)
                  SizedBox(
                    width: 84,
                    child: _PresetButton(
                      label: style.title,
                      selected: style.key == selected.key,
                      onPressed: () => ref.read(editorStateProvider.notifier).setMosaicStyle(style.key),
                    ),
                  ),
              ],
            ),
          ),
          _CompactIconButton(
            icon: Icons.tune,
            tooltip: 'Style settings',
            onPressed: selected.hasOptions ? () => _editOptions(context, ref, selected) : null,
          ),
        ],
      ),
    );
  }
}

class _SizeControl extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double value;
  final double min;
  final double max;
  final double step;
  final Map<String, double> presets;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  const _SizeControl({
    required this.icon,
    required this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.presets,
    required this.valueLabel,
    required this.onChanged,
  });

  void _change(double next) => onChanged(double.parse(next.clamp(min, max).toStringAsFixed(4)));

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Tooltip(
            message: tooltip,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(icon, size: 16, color: Colors.white70),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(valueLabel, style: context.textTheme.labelMedium?.copyWith(color: Colors.white)),
          ),
          _CompactIconButton(icon: Icons.remove, onPressed: value <= min ? null : () => _change(value - step)),
          Expanded(
            child: Row(
              children: [
                for (final MapEntry(key: label, value: preset) in presets.entries)
                  Expanded(
                    child: _PresetButton(
                      label: label,
                      selected: (value - preset).abs() < step / 2,
                      onPressed: () => _change(preset),
                    ),
                  ),
              ],
            ),
          ),
          _CompactIconButton(icon: Icons.add, onPressed: value >= max ? null : () => _change(value + step)),
        ],
      ),
    );
  }
}

class _PresetButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _PresetButton({required this.label, required this.selected, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.primaryColor : Colors.white70;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: selected ? context.primaryColor.withValues(alpha: 0.15) : Colors.white10,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: onPressed,
          child: SizedBox(
            height: 28,
            child: Center(
              child: Text(label, style: context.textTheme.labelSmall?.copyWith(color: color)),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrushPreview extends StatelessWidget {
  final double brushSize;
  final double blockSize;
  final bool erase;

  const _BrushPreview({required this.brushSize, required this.blockSize, required this.erase});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 32,
      child: CustomPaint(
        painter: _BrushPreviewPainter(
          brushSize: brushSize,
          blockSize: blockSize,
          erase: erase,
          color: context.primaryColor,
        ),
      ),
    );
  }
}

class _BrushPreviewPainter extends CustomPainter {
  final double brushSize;
  final double blockSize;
  final bool erase;
  final Color color;

  const _BrushPreviewPainter({
    required this.brushSize,
    required this.blockSize,
    required this.erase,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    final radius = max(3.0, maxRadius * (brushSize / maxMosaicBrushSize));
    final circle = Rect.fromCircle(center: center, radius: radius);

    canvas.save();
    canvas.clipPath(Path()..addOval(circle));
    if (erase) {
      canvas.drawRect(circle, Paint()..color = Colors.white24);
    } else {
      final cell = max(2.0, radius * 2 * blockSize / brushSize);
      for (var y = circle.top; y < circle.bottom; y += cell) {
        for (var x = circle.left; x < circle.right; x += cell) {
          final even = (((x - circle.left) / cell).round() + ((y - circle.top) / cell).round()).isEven;
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), Paint()..color = even ? Colors.white70 : Colors.white30);
        }
      }
    }
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_BrushPreviewPainter oldDelegate) =>
      oldDelegate.brushSize != brushSize ||
      oldDelegate.blockSize != blockSize ||
      oldDelegate.erase != erase ||
      oldDelegate.color != color;
}

class _ZoomableEditorArea extends StatefulWidget {
  final Widget child;
  final VoidCallback onPointerStart;
  final VoidCallback onPinchStart;
  final VoidCallback onPinchEnd;

  const _ZoomableEditorArea({
    super.key,
    required this.child,
    required this.onPointerStart,
    required this.onPinchStart,
    required this.onPinchEnd,
  });

  @override
  State<_ZoomableEditorArea> createState() => _ZoomableEditorAreaState();
}

class _ZoomableEditorAreaState extends State<_ZoomableEditorArea> {
  static const double _maxScale = 8;

  final Map<int, Offset> _pointers = {};
  Matrix4 _matrix = Matrix4.identity();
  Matrix4 _startMatrix = Matrix4.identity();
  Offset _startFocal = Offset.zero;
  double _startDistance = 1;
  bool _pinching = false;
  Size _size = Size.zero;

  double get _scale => _matrix.getMaxScaleOnAxis();

  (Offset, double) _focalAndDistance() {
    final points = _pointers.values.take(2).toList();
    return ((points[0] + points[1]) / 2, max((points[0] - points[1]).distance, 1));
  }

  void _onDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      widget.onPointerStart();
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      final (focal, distance) = _focalAndDistance();
      _startFocal = focal;
      _startDistance = distance;
      _startMatrix = _matrix.clone();
      if (!_pinching) {
        setState(() => _pinching = true);
        widget.onPinchStart();
      }
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (!_pinching || _pointers.length < 2) {
      return;
    }

    final (focal, distance) = _focalAndDistance();
    final startScale = _startMatrix.getMaxScaleOnAxis();
    final targetScale = (startScale * distance / _startDistance).clamp(1.0, _maxScale);
    final factor = targetScale / startScale;

    final next = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(factor, factor, 1, 1)
      ..translateByDouble(-_startFocal.dx, -_startFocal.dy, 0, 1)
      ..multiply(_startMatrix);
    setState(() => _matrix = _clamp(next));
  }

  void _onUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length == 1 && _pinching) {
      _startMatrix = _matrix.clone();
    }
    if (_pointers.isEmpty && _pinching) {
      setState(() {
        _pinching = false;
        if (_scale <= 1.02) {
          _matrix = Matrix4.identity();
        }
      });
      widget.onPinchEnd();
    }
  }

  Matrix4 _clamp(Matrix4 matrix) {
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    final minX = _size.width - _size.width * scale;
    final minY = _size.height - _size.height * scale;
    final x = translation.x.clamp(min(minX, 0.0), 0.0).toDouble();
    final y = translation.y.clamp(min(minY, 0.0), 0.0).toDouble();
    return Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onUp,
          child: ClipRect(
            child: AbsorbPointer(
              absorbing: _pinching,
              child: Transform(transform: _matrix, child: widget.child),
            ),
          ),
        );
      },
    );
  }
}

class _MosaicCanvas extends ConsumerStatefulWidget {
  final Image image;
  final ValueListenable<int> pinches;

  const _MosaicCanvas({required this.image, required this.pinches});

  @override
  ConsumerState<_MosaicCanvas> createState() => _MosaicCanvasState();
}

class _MosaicCanvasState extends ConsumerState<_MosaicCanvas> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ui.Image? _source;
  final Map<String, ui.Image> _effects = {};
  final Set<String> _pending = {};

  final List<Offset> _activePoints = [];
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  int? _activePointer;

  @override
  void initState() {
    super.initState();
    widget.pinches.addListener(_cancelActiveStroke);
  }

  void _cancelActiveStroke() {
    _activePointer = null;
    _activePoints.clear();
    _repaint.value++;
  }

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
      _clearEffects();
      setState(() => _source = info.image);
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

  void _clearEffects() {
    for (final image in _effects.values) {
      image.dispose();
    }
    _effects.clear();
    _pending.clear();
  }

  void _ensureEffects(Iterable<MosaicStrokeDraft> strokes, int width, int height) {
    final source = _source;
    if (source == null) {
      return;
    }

    for (final stroke in strokes) {
      final key = mosaicEffectKey(stroke, width, height);
      if (stroke.erase || _effects.containsKey(key) || !_pending.add(key)) {
        continue;
      }

      unawaited(
        ref
            .read(censorStylesProvider)
            .render(
              stroke.style,
              stroke.styleOptions,
              source,
              mosaicBlockPixels(stroke.blockSize, width, height),
              width,
              height,
            )
            .then((image) {
              if (!mounted || !identical(source, _source) || !_pending.remove(key) || image == null) {
                image?.dispose();
                return;
              }
              setState(() => _effects[key] = image);
            })
            .catchError((Object error, StackTrace stack) {
              if (mounted) {
                setState(() => _pending.remove(key));
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(SnackBar(content: Text('Censor style failed: $error')));
              }
              handleError(error, stack: stack, description: 'Censor style failed');
            }),
      );
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
    widget.pinches.removeListener(_cancelActiveStroke);
    _stopListening();
    _source?.dispose();
    _clearEffects();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(editorStateProvider);

    final source = _source;
    final width = editorState.originalWidth;
    final height = editorState.originalHeight;
    if (source == null || width <= 0 || height <= 0) {
      return const Center(child: CircularProgressIndicator());
    }

    final activeStroke = MosaicStrokeDraft(
      points: const [],
      brushSize: editorState.mosaicBrushSize,
      blockSize: editorState.mosaicBlockSize,
      erase: editorState.mosaicTool == MosaicTool.eraser,
      style: editorState.mosaicStyle,
      styleOptions: editorState.mosaicStyleOptions,
    );
    _ensureEffects([activeStroke, ...editorState.mosaicStrokes], width, height);

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(constraints.maxWidth * 0.9, constraints.maxHeight * 0.95);
        final scale = min(available.width / width, available.height / height);
        final size = Size(width * scale, height * scale);

        return Center(
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              children: [
                Positioned.fill(child: _buildCanvas(editorState, source, width, height, activeStroke, size)),
                if (_pending.isNotEmpty)
                  const Positioned(
                    top: 8,
                    right: 8,
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCanvas(
    EditorState editorState,
    ui.Image source,
    int width,
    int height,
    MosaicStrokeDraft activeStroke,
    Size size,
  ) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _onPointerDown(event, size),
      onPointerMove: (event) => _onPointerMove(event, size),
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: CustomPaint(
        size: size,
        painter: _MosaicPainter(
          source: source,
          effects: Map.unmodifiable(_effects),
          originalWidth: width,
          originalHeight: height,
          strokes: editorState.mosaicStrokes,
          activePoints: _activePoints,
          activeStroke: activeStroke,
          repaint: _repaint,
        ),
      ),
    );
  }
}

class _MosaicPainter extends CustomPainter {
  final ui.Image source;
  final Map<String, ui.Image> effects;
  final int originalWidth;
  final int originalHeight;
  final List<MosaicStrokeDraft> strokes;
  final List<Offset> activePoints;
  final MosaicStrokeDraft activeStroke;

  const _MosaicPainter({
    required this.source,
    required this.effects,
    required this.originalWidth,
    required this.originalHeight,
    required this.strokes,
    required this.activePoints,
    required this.activeStroke,
    required Listenable repaint,
  }) : super(repaint: repaint);

  String _key(MosaicStrokeDraft stroke) => mosaicEffectKey(stroke, originalWidth, originalHeight);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.medium,
    );

    final drawn = [
      for (final stroke in strokes) (stroke.points, stroke),
      if (activePoints.isNotEmpty) (activePoints, activeStroke),
    ];

    for (final key in {
      for (final (_, stroke) in drawn)
        if (!stroke.erase) _key(stroke),
    }) {
      final image = effects[key];
      if (image == null) {
        continue;
      }

      canvas.saveLayer(bounds, Paint());
      for (final (points, stroke) in drawn) {
        final visible = !stroke.erase && _key(stroke) == key;
        _drawStroke(canvas, size, points, stroke.brushSize, !visible);
      }
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        bounds,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..blendMode = BlendMode.srcIn,
      );
      canvas.restore();
    }
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
        !mapEquals(oldDelegate.effects, effects) ||
        oldDelegate.strokes != strokes ||
        oldDelegate.activeStroke != activeStroke;
  }
}
