/// Every id the viewer area exposes to plugins: slots, built-in items, hooks, events and host functions.
///
/// `mobile/docs/plugins/viewer.md` documents each of them. Pure Dart, no Flutter imports.
library;

/// Slot ids of the viewer, video player, slideshow and memories.
abstract final class ViewerSlotIds {
  /// Buttons in the viewer's top bar (also `assetViewer.appBar.actions`).
  static const topBar = 'viewer.topBar';

  /// Items of the viewer's ⋮ menu (also `assetViewer.appBar.menu`).
  static const menu = 'viewer.menu';

  /// Buttons of the action row at the bottom of the viewer.
  static const bottomBar = 'viewer.bottomBar';

  /// Rows of the bottom area above the action row (OCR toggle, video controls, carousel).
  static const bottomPanels = 'viewer.bottomPanels';

  /// Sections of the info / details sheet.
  static const infoSections = 'viewer.info.sections';

  /// The date and time title in the middle of the top bar (`replace` / `wrap`).
  static const title = 'viewer.title';

  /// Overlays over the photo or video (Flutter JSON UI or native views).
  static const overlay = 'viewer.overlay';

  /// Legacy name of [overlay] (`contributes.overlays` with `"slot": "viewer"`).
  static const legacyOverlay = 'viewer';

  /// Native views placed inside the video player container, exactly over the video frame.
  static const videoOverlay = 'videoPlayer.overlay';

  /// Buttons next to the play button and the scrubber of the video controls.
  static const videoControls = 'videoPlayer.controls';

  static const slideshowActions = 'slideshow.appBar.actions';
  static const slideshowMenu = 'slideshow.appBar.menu';
  static const slideshowOverlay = 'slideshow.overlay';

  static const memoryActions = 'memory.appBar.actions';
  static const memoryOverlay = 'memory.overlay';
  static const memoryFooter = 'memory.footer';

  static const memoryListActions = 'memoryList.appBar.actions';
  static const memoryListMenu = 'memoryList.appBar.menu';
  static const memoryListTile = 'memoryList.tile';
  static const memoryListEmpty = 'memoryList.empty';

  /// Route-convention names (section 4 of the plan) that mean the same slot.
  static const aliases = <String, String>{
    'assetViewer.appBar.actions': topBar,
    'assetViewer.appBar.menu': menu,
    'assetViewer.footer': bottomBar,
    'assetViewer.overlay': overlay,
  };

  static const all = [
    topBar,
    menu,
    bottomBar,
    bottomPanels,
    infoSections,
    title,
    overlay,
    videoOverlay,
    videoControls,
    slideshowActions,
    slideshowMenu,
    slideshowOverlay,
    memoryActions,
    memoryOverlay,
    memoryFooter,
    memoryListActions,
    memoryListMenu,
    memoryListTile,
    memoryListEmpty,
  ];
}

/// Built-in item ids per slot, in the order the app shows them.
abstract final class ViewerBuiltinIds {
  static const topBar = ['motionPhoto', 'activity', 'favorite', 'deviceFavorite', 'pluginActions', 'censor', 'menu'];

  /// The ⋮ menu uses the action button type names; which of them appear depends on the asset and the context.
  static const menu = [
    'openInfo',
    'likeActivity',
    'shareLink',
    'cast',
    'setAlbumCover',
    'similarPhotos',
    'setProfilePicture',
    'viewInTimeline',
    'slideshow',
    'download',
    'openInBrowser',
    'unstack',
    'removeFromLockFolder',
    'removeFromAlbum',
    'deleteLocal',
    'advancedInfo',
  ];

  static const bottomBar = ['restore', 'share', 'edit', 'moveToPrivate', 'add', 'delete'];

  static const bottomPanels = ['ocr', 'videoControls', 'carousel', 'actions'];

  static const infoSections = [
    'dateTime',
    'owner',
    'description',
    'people',
    'location',
    'technical',
    'rating',
    'appearsIn',
    'tags',
  ];

  static const videoControls = ['playPause', 'scrubber', 'time'];

  static const slideshowActions = ['playPause', 'settings'];

  static const memoryActions = ['close'];

  static const memoryListActions = ['favorites'];

  static const bySlot = <String, List<String>>{
    ViewerSlotIds.topBar: topBar,
    ViewerSlotIds.menu: menu,
    ViewerSlotIds.bottomBar: bottomBar,
    ViewerSlotIds.bottomPanels: bottomPanels,
    ViewerSlotIds.infoSections: infoSections,
    ViewerSlotIds.videoControls: videoControls,
    ViewerSlotIds.slideshowActions: slideshowActions,
    ViewerSlotIds.memoryActions: memoryActions,
    ViewerSlotIds.memoryListActions: memoryListActions,
  };
}

/// Hook ids.
abstract final class ViewerHookIds {
  /// Tap, double tap, long press, swipe up / down and pinch on the photo or video.
  static const gesture = 'viewer.gesture';

  /// Thumbnails (timeline grid, carousel, memories lane, placeholders).
  static const imageThumbnail = 'image.thumbnail';

  /// Screen-sized previews (viewer, memories, slideshow).
  static const imagePreview = 'image.preview';

  /// Originals (viewer with "load original", animated images).
  static const imageFull = 'image.full';

  /// The file or URL a video plays from.
  static const videoSource = 'video.source';

  /// Play, pause, restart and seek from the video controls.
  static const videoControl = 'video.control';

  static const all = [gesture, imageThumbnail, imagePreview, imageFull, videoSource, videoControl];
}

/// Event names.
abstract final class ViewerEventNames {
  /// Legacy event, local assets only: `{ "asset" }`.
  static const legacyOpen = 'viewer.open';

  static const opened = 'viewer.opened';
  static const assetChanged = 'viewer.assetChanged';
  static const closed = 'viewer.closed';
  static const controlsChanged = 'viewer.controlsChanged';
  static const detailsChanged = 'viewer.detailsChanged';
  static const zoomChanged = 'viewer.zoomChanged';

  static const videoSessionStarted = 'video.sessionStarted';
  static const videoSessionEnded = 'video.sessionEnded';
  static const videoState = 'video.state';
  static const videoPosition = 'video.position';
  static const videoFrameRect = 'video.frameRect';

  static const slideshowStarted = 'slideshow.started';
  static const slideshowSlideChanged = 'slideshow.slideChanged';
  static const slideshowPaused = 'slideshow.paused';
  static const slideshowResumed = 'slideshow.resumed';
  static const slideshowEnded = 'slideshow.ended';

  static const memoryOpened = 'memory.opened';
  static const memoryAssetChanged = 'memory.assetChanged';
  static const memoryClosed = 'memory.closed';

  static const imageInvalidated = 'image.invalidated';

  /// Events delivered at most this often (per session for video events).
  static const throttled = <String, Duration>{
    videoPosition: Duration(milliseconds: 250),
    videoFrameRect: Duration(milliseconds: 100),
  };

  static const all = [
    legacyOpen,
    opened,
    assetChanged,
    closed,
    controlsChanged,
    detailsChanged,
    zoomChanged,
    videoSessionStarted,
    videoSessionEnded,
    videoState,
    videoPosition,
    videoFrameRect,
    slideshowStarted,
    slideshowSlideChanged,
    slideshowPaused,
    slideshowResumed,
    slideshowEnded,
    memoryOpened,
    memoryAssetChanged,
    memoryClosed,
    imageInvalidated,
  ];
}

/// Host function names.
abstract final class ViewerHostNames {
  static const viewerOpen = 'viewer.open';
  static const viewerClose = 'viewer.close';
  static const viewerNext = 'viewer.next';
  static const viewerPrevious = 'viewer.previous';
  static const viewerCurrent = 'viewer.current';
  static const viewerShowControls = 'viewer.showControls';
  static const viewerShowDetails = 'viewer.showDetails';

  static const videoSessions = 'video.sessions';
  static const videoSession = 'video.session';
  static const videoPlay = 'video.play';
  static const videoPause = 'video.pause';
  static const videoSeek = 'video.seek';
  static const videoSetSpeed = 'video.setSpeed';
  static const videoSetVolume = 'video.setVolume';
  static const videoPosition = 'video.position';
  static const videoCapture = 'video.capture';
  static const videoOverlaySet = 'video.overlay.set';
  static const videoOverlayPatch = 'video.overlay.patch';
  static const videoOverlayClear = 'video.overlay.clear';
  static const videoNativeOverlayAttach = 'video.nativeOverlay.attach';
  static const videoNativeOverlayDetach = 'video.nativeOverlay.detach';

  static const imageLoad = 'image.load';
  static const imageInvalidate = 'image.invalidate';

  static const all = [
    viewerOpen,
    viewerClose,
    viewerNext,
    viewerPrevious,
    viewerCurrent,
    viewerShowControls,
    viewerShowDetails,
    videoSessions,
    videoSession,
    videoPlay,
    videoPause,
    videoSeek,
    videoSetSpeed,
    videoSetVolume,
    videoPosition,
    videoCapture,
    videoOverlaySet,
    videoOverlayPatch,
    videoOverlayClear,
    videoNativeOverlayAttach,
    videoNativeOverlayDetach,
    imageLoad,
    imageInvalidate,
  ];
}

/// The built-in toggle of the viewer censor shield (kernel `toggle` mechanism, phase B).
abstract final class ViewerToggleIds {
  static const censor = 'viewer.censor';
}
