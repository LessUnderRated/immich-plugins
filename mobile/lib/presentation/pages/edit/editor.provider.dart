import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/aspect_ratios.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:immich_mobile/utils/mosaic.utils.dart';

part 'editor.provider.freezed.dart';

final editorStateProvider = NotifierProvider<EditorProvider, EditorState>(EditorProvider.new);

class EditorProvider extends Notifier<EditorState> {
  @override
  EditorState build() {
    return const EditorState();
  }

  void clear() {
    state = const EditorState();
  }

  void init(List<AssetEdit> edits, ExifInfo exifInfo) {
    clear();

    final existingCrop = edits.whereType<CropEdit>().firstOrNull;

    final originalWidth = exifInfo.isFlipped ? exifInfo.height : exifInfo.width;
    final originalHeight = exifInfo.isFlipped ? exifInfo.width : exifInfo.height;

    final Rect crop = existingCrop != null && originalWidth != null && originalHeight != null
        ? convertCropParametersToRect(existingCrop.parameters, originalWidth, originalHeight)
        : const Rect.fromLTRB(0, 0, 1, 1);

    final transform = normalizeTransformEdits(edits.where((edit) => edit is! MosaicEdit).toList());
    final existingMosaic = edits.whereType<MosaicEdit>().firstOrNull;
    final mosaic = existingMosaic != null && originalWidth != null && originalHeight != null
        ? mosaicFromParameters(existingMosaic.parameters, originalWidth, originalHeight)
        : null;

    state = state.copyWith(
      originalWidth: originalWidth ?? state.originalWidth,
      originalHeight: originalHeight ?? state.originalHeight,
      crop: crop,
      flipHorizontal: transform.mirrorHorizontal,
      flipVertical: transform.mirrorVertical,
      mosaicStrokes: mosaic?.strokes ?? const [],
      mosaicBlockSize: mosaic?.blockSize ?? state.mosaicBlockSize,
    );

    _animateRotation(transform.rotation, duration: Duration.zero);
  }

  void _animateRotation(int angle, {Duration duration = const Duration(milliseconds: 300)}) {
    state = state.copyWith(rotationAngle: angle, animationDuration: duration);
  }

  void normalizeRotation() {
    final normalizedAngle = ((state.rotationAngle % 360) + 360) % 360;
    if (normalizedAngle != state.rotationAngle) {
      state = state.copyWith(rotationAngle: normalizedAngle, animationDuration: Duration.zero);
    }
  }

  void setIsEditing(bool isApplyingEdits) {
    state = state.copyWith(isApplyingEdits: isApplyingEdits);
  }

  /// The working image was replaced by a [width] x [height] tool result that already contains every pending edit:
  /// start over on it with no crop, rotation, mirroring or mosaic.
  void rebase(int width, int height) {
    state = state.copyWith(
      originalWidth: width,
      originalHeight: height,
      rotationAngle: 0,
      animationDuration: Duration.zero,
      flipHorizontal: false,
      flipVertical: false,
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      aspectRatio: CropAspectRatio.free,
      mosaicStrokes: const [],
      mosaicRedoStrokes: const [],
      hasUnsavedEdits: true,
    );
  }

  /// Restores the edits of [snapshot] (taken before a tool result replaced the working image), keeping the current
  /// mode and brush settings.
  void restore(EditorState snapshot) {
    state = state.copyWith(
      originalWidth: snapshot.originalWidth,
      originalHeight: snapshot.originalHeight,
      rotationAngle: snapshot.rotationAngle,
      animationDuration: Duration.zero,
      flipHorizontal: snapshot.flipHorizontal,
      flipVertical: snapshot.flipVertical,
      crop: snapshot.crop,
      aspectRatio: snapshot.aspectRatio,
      mosaicStrokes: snapshot.mosaicStrokes,
      mosaicRedoStrokes: snapshot.mosaicRedoStrokes,
      hasUnsavedEdits: snapshot.hasUnsavedEdits,
    );
  }

  void setCrop(Rect crop) {
    state = state.copyWith(crop: crop, hasUnsavedEdits: true);
  }

  /// Returns the required shift that has to be done to fit a segment in a given
  /// constraint
  double _shiftIntoBounds(double start, double end, {double min = 0.0, double max = 1.0}) {
    if (start < min) {
      return min - start;
    }
    if (end > max) {
      return max - end;
    }
    return 0.0;
  }

  void setAspectRatio(CropAspectRatio preset) {
    // Expand the initial selection into a square. We have to keep the longest
    // side the same as before when the user changes the aspect ratio. Otherwise
    // the selection might shrink
    Rect startingSquare = Rect.fromCenter(
      center: state.crop.center,
      width: state.crop.longestSide,
      height: state.crop.longestSide,
    );
    // If one side of the square is outside of the image border after the
    // expansion, move it towards the center of the required amount
    final dx = _shiftIntoBounds(startingSquare.left, startingSquare.right);
    final dy = _shiftIntoBounds(startingSquare.top, startingSquare.bottom);
    startingSquare = startingSquare.shift(Offset(dx, dy));
    state = state.copyWith(aspectRatio: preset, hasUnsavedEdits: true, crop: startingSquare);
  }

  void resetEdits() {
    _animateRotation(0);

    state = state.copyWith(
      flipHorizontal: false,
      flipVertical: false,
      crop: const Rect.fromLTRB(0, 0, 1, 1),
      aspectRatio: CropAspectRatio.free,
      mosaicStrokes: const [],
      mosaicRedoStrokes: const [],
      hasUnsavedEdits: true,
    );
  }

  void setMode(EditorMode mode) {
    state = state.copyWith(mode: mode);
  }

  void setMosaicTool(MosaicTool tool) {
    state = state.copyWith(mosaicTool: tool);
  }

  void setMosaicBrushSize(double brushSize) {
    state = state.copyWith(mosaicBrushSize: brushSize);
  }

  void setMosaicBlockSize(double blockSize) {
    state = state.copyWith(mosaicBlockSize: blockSize);
  }

  void setMosaicStyle(String style) {
    if (style != state.mosaicStyle) {
      state = state.copyWith(mosaicStyle: style, mosaicStyleOptions: const {});
    }
  }

  void setMosaicStyleOptions(Map<String, Object?> options) {
    state = state.copyWith(mosaicStyleOptions: options);
  }

  void addMosaicStroke(List<Offset> points) {
    if (points.isEmpty || state.mosaicStrokes.length >= maxMosaicStrokes) {
      return;
    }

    final stroke = MosaicStrokeDraft(
      points: List.unmodifiable(points),
      brushSize: state.mosaicBrushSize,
      blockSize: state.mosaicBlockSize,
      erase: state.mosaicTool == MosaicTool.eraser,
      style: state.mosaicStyle,
      styleOptions: state.mosaicStyleOptions,
    );
    state = state.copyWith(
      mosaicStrokes: [...state.mosaicStrokes, stroke],
      mosaicRedoStrokes: const [],
      hasUnsavedEdits: true,
    );
  }

  void undoMosaicStroke() {
    if (state.mosaicStrokes.isEmpty) {
      return;
    }

    state = state.copyWith(
      mosaicStrokes: state.mosaicStrokes.sublist(0, state.mosaicStrokes.length - 1),
      mosaicRedoStrokes: [...state.mosaicRedoStrokes, state.mosaicStrokes.last],
      hasUnsavedEdits: true,
    );
  }

  void redoMosaicStroke() {
    if (state.mosaicRedoStrokes.isEmpty) {
      return;
    }

    state = state.copyWith(
      mosaicStrokes: [...state.mosaicStrokes, state.mosaicRedoStrokes.last],
      mosaicRedoStrokes: state.mosaicRedoStrokes.sublist(0, state.mosaicRedoStrokes.length - 1),
      hasUnsavedEdits: true,
    );
  }

  void rotateCCW() {
    _animateRotation(state.rotationAngle - 90);
    state = state.copyWith(aspectRatio: state.aspectRatio.flipped, hasUnsavedEdits: true);
  }

  void rotateCW() {
    _animateRotation(state.rotationAngle + 90);
    state = state.copyWith(aspectRatio: state.aspectRatio.flipped, hasUnsavedEdits: true);
  }

  void flipHorizontally() {
    if (state.rotationAngle % 180 != 0) {
      // When rotated 90 or 270 degrees, flipping horizontally is equivalent to flipping vertically
      state = state.copyWith(flipVertical: !state.flipVertical, hasUnsavedEdits: true);
    } else {
      state = state.copyWith(flipHorizontal: !state.flipHorizontal, hasUnsavedEdits: true);
    }
  }

  void flipVertically() {
    if (state.rotationAngle % 180 != 0) {
      // When rotated 90 or 270 degrees, flipping vertically is equivalent to flipping horizontally
      state = state.copyWith(flipHorizontal: !state.flipHorizontal, hasUnsavedEdits: true);
    } else {
      state = state.copyWith(flipVertical: !state.flipVertical, hasUnsavedEdits: true);
    }
  }
}

@freezed
abstract class EditorState with _$EditorState {
  const EditorState._();

  const factory EditorState({
    @Default(false) bool isApplyingEdits,
    @Default(0) int rotationAngle,
    @Default(false) bool flipHorizontal,
    @Default(false) bool flipVertical,
    @Default(Rect.fromLTRB(0, 0, 1, 1)) Rect crop,
    @Default(CropAspectRatio.free) CropAspectRatio aspectRatio,
    @Default(0) int originalWidth,
    @Default(0) int originalHeight,
    @Default(Duration.zero) Duration animationDuration,
    @Default(false) bool hasUnsavedEdits,
    @Default(EditorMode.transform) EditorMode mode,
    @Default(MosaicTool.brush) MosaicTool mosaicTool,
    @Default(defaultMosaicBrushSize) double mosaicBrushSize,
    @Default(defaultMosaicBlockSize) double mosaicBlockSize,
    @Default(<MosaicStrokeDraft>[]) List<MosaicStrokeDraft> mosaicStrokes,
    @Default(<MosaicStrokeDraft>[]) List<MosaicStrokeDraft> mosaicRedoStrokes,
    String? mosaicStyle,
    @Default(<String, Object?>{}) Map<String, Object?> mosaicStyleOptions,
  }) = _EditorState;

  bool get hasEdits {
    return rotationAngle != 0 ||
        flipHorizontal ||
        flipVertical ||
        crop != const Rect.fromLTRB(0, 0, 1, 1) ||
        mosaicStrokes.isNotEmpty;
  }
}
