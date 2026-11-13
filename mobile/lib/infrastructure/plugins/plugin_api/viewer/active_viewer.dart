import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// What an open viewer (asset viewer, slideshow, memory) lets plugins do. Implemented by the page while it is open.
abstract interface class ViewerHandle {
  /// `viewer`, `slideshow` or `memory`.
  String get surface;

  BaseAsset? get currentAsset;

  int get index;

  int get total;

  bool get controlsVisible;

  bool get detailsVisible;

  bool get zoomed;

  /// Goes to the page at [index]; false when it does not exist.
  bool jumpTo(int index);

  void showControls(bool show);

  void showDetails(bool show);

  Future<void> close();
}

/// Commands for the pages of an open viewer (the page widgets own the scroll and zoom state they act on).
enum ViewerPageCommand { showDetails, hideDetails, resetZoom }

/// The open viewers, innermost last (a viewer can open over another one, e.g. from an album's activity).
abstract final class ActiveViewers {
  static final _open = <ViewerHandle>[];

  static final _pageListeners = <void Function(ViewerPageCommand command)>{};

  /// Listens to commands for the pages of the open viewers; returns the function that stops listening.
  static void Function() onPageCommand(void Function(ViewerPageCommand command) listener) {
    _pageListeners.add(listener);
    return () => _pageListeners.remove(listener);
  }

  /// Sends [command] to the pages of the open viewers (the page on screen acts on it).
  static void sendPageCommand(ViewerPageCommand command) {
    for (final listener in List.of(_pageListeners)) {
      listener(command);
    }
  }

  static ViewerHandle? get current => _open.isEmpty ? null : _open.last;

  static List<ViewerHandle> get all => List.unmodifiable(_open);

  static void opened(ViewerHandle handle) {
    _open
      ..remove(handle)
      ..add(handle);
  }

  static void closed(ViewerHandle handle) => _open.remove(handle);

  static Map<String, dynamic> describe(ViewerHandle handle, Map<String, dynamic>? asset) => {
    'surface': handle.surface,
    'asset': asset,
    'index': handle.index,
    'total': handle.total,
    'controlsVisible': handle.controlsVisible,
    'detailsVisible': handle.detailsVisible,
    'zoomed': handle.zoomed,
  };
}
