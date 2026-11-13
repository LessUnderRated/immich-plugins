/// Ids of everything the library area (albums, people, places, map, search, folders, partners, shared links,
/// locked folder and private gallery) exposes to plugins: pages, slots, built-in item ids, hooks, events and host
/// functions. Argument and payload shapes are documented in `docs/plugins/library.md`.
///
/// Pure Dart: no Flutter imports, so pages, providers, host functions and tests can all use it.
library;

/// Page keys: the route name in lower camel case without `Route`. Every page has the generic slots of
/// [LibrarySlots.generic].
abstract final class LibraryPages {
  static const activities = 'activities';
  static const albumOptions = 'albumOptions';
  static const albums = 'albums';
  static const appAlbum = 'appAlbum';
  static const createAlbum = 'createAlbum';
  static const downloadInfo = 'downloadInfo';
  static const folder = 'folder';
  static const library = 'library';
  static const localAlbums = 'localAlbums';
  static const lockedFolder = 'lockedFolder';
  static const map = 'map';
  static const mapLocationPicker = 'mapLocationPicker';
  static const partner = 'partner';
  static const partnerDetail = 'partnerDetail';
  static const peopleCollection = 'peopleCollection';
  static const person = 'person';
  static const pinAuth = 'pinAuth';
  static const place = 'place';
  static const placeDetail = 'placeDetail';
  static const privateFileViewer = 'privateFileViewer';
  static const privateGallery = 'privateGallery';
  static const privateLegacy = 'privateLegacy';
  static const privateViewer = 'privateViewer';
  static const remoteAlbum = 'remoteAlbum';
  static const search = 'search';
  static const sharedLink = 'sharedLink';
  static const sharedLinkEdit = 'sharedLinkEdit';
  static const userSelection = 'userSelection';

  static const all = [
    activities,
    albumOptions,
    albums,
    appAlbum,
    createAlbum,
    downloadInfo,
    folder,
    library,
    localAlbums,
    lockedFolder,
    map,
    mapLocationPicker,
    partner,
    partnerDetail,
    peopleCollection,
    person,
    pinAuth,
    place,
    placeDetail,
    privateFileViewer,
    privateGallery,
    privateLegacy,
    privateViewer,
    remoteAlbum,
    search,
    sharedLink,
    sharedLinkEdit,
    userSelection,
  ];
}

/// Slot ids. Generic page slots are built with the helpers; page-specific slots are constants.
abstract final class LibrarySlots {
  /// Buttons (and toggles) in the page's app bar.
  static String appBarActions(String page) => '$page.appBar.actions';

  /// Items of the page's overflow (⋮) menu. Pages without a built-in menu show one when plugins add items.
  static String appBarMenu(String page) => '$page.appBar.menu';

  /// Sections above the page content.
  static String header(String page) => '$page.header';

  /// Sections below the page content.
  static String footer(String page) => '$page.footer';

  /// Replaces or adds to the page's empty state.
  static String empty(String page) => '$page.empty';

  /// `replace` / `wrap` the whole page body.
  static String body(String page) => '$page.body';

  /// Floating action buttons.
  static String fab(String page) => '$page.fab';

  /// The generic slots of [page].
  static List<String> generic(String page) => [
    appBarActions(page),
    appBarMenu(page),
    header(page),
    footer(page),
    empty(page),
    body(page),
    fab(page),
  ];

  // Album list and album pickers (AlbumSelector is also used by "add to album" sheets; context `scope`).
  static const albumSelectorHeader = 'albumSelector.header';
  static const albumSelectorSections = 'albumSelector.sections';
  static const albumSelectorFilters = 'albumSelector.filters';
  static const albumSelectorToolbar = 'albumSelector.toolbar';
  static const albumSelectorSort = 'albumSelector.sort';
  static const albumSelectorTile = 'albumSelector.tile';
  static const albumSelectorTileActions = 'albumSelector.tile.actions';
  static const albumSelectorTileMenu = 'albumSelector.tile.menu';
  static const albumSelectorEmpty = 'albumSelector.empty';
  static const albumSelectorFooter = 'albumSelector.footer';

  static const albumOptionsSections = 'albumOptions.sections';
  static const albumOptionsPeopleActions = 'albumOptions.people.actions';
  static const albumOptionsUser = 'albumOptions.user';
  static const albumOptionsUserMenu = 'albumOptions.user.menu';

  static const createAlbumFields = 'createAlbum.fields';
  static const createAlbumActions = 'createAlbum.actions';

  static const libraryActions = 'library.actions';
  static const libraryCollections = 'library.collections';
  static const libraryQuickAccess = 'library.quickAccess';
  static const librarySections = 'library.sections';

  static const localAlbumsSections = 'localAlbums.sections';
  static const localAlbumsAppAlbum = 'localAlbums.appAlbum';
  static const localAlbumsAppAlbumsEmpty = 'localAlbums.appAlbums.empty';
  static const localAlbumsDeviceAlbum = 'localAlbums.deviceAlbum';
  static const localAlbumsDeviceAlbumsEmpty = 'localAlbums.deviceAlbums.empty';

  static const remoteAlbumPendingUploads = 'remoteAlbum.pendingUploads';
  static const remoteAlbumPendingUploadsActions = 'remoteAlbum.pendingUploads.actions';
  static const remoteAlbumEditDialog = 'remoteAlbum.editDialog';

  static const peopleCollectionTile = 'peopleCollection.tile';
  static const peopleCollectionTileActions = 'peopleCollection.tile.actions';
  static const peopleCollectionTileMenu = 'peopleCollection.tile.menu';

  static const personOptions = 'person.options';

  static const placeSections = 'place.sections';
  static const placeTile = 'place.tile';
  static const placeTileMenu = 'place.tile.menu';

  static const mapControls = 'map.controls';
  static const mapOverlay = 'map.overlay';
  static const mapSettings = 'map.settings';
  static const mapLocationPickerActions = 'mapLocationPicker.actions';

  static const partnerTile = 'partner.tile';
  static const partnerTileActions = 'partner.tile.actions';

  static const userSelectionSelected = 'userSelection.selected';
  static const userSelectionUser = 'userSelection.user';

  static const activitiesItem = 'activities.item';
  static const activitiesInput = 'activities.input';

  static const downloadInfoTask = 'downloadInfo.task';

  static const pinAuthActions = 'pinAuth.actions';

  static const privateGalleryLocked = 'privateGallery.locked';
  static const privateGallerySelectionActions = 'privateGallery.selection.actions';
  static const privateGallerySelectionAppBarActions = 'privateGallery.selection.appBar.actions';
  static const privateGalleryTimelineActions = 'privateGallery.timeline.actions';
  static const privateGalleryTile = 'privateGallery.tile';

  static const searchFilters = 'search.filters';
  static const searchFilterSheet = 'search.filterSheet';
  static const searchSuggestions = 'search.suggestions';
  static const searchQuickLinks = 'search.quickLinks';
  static const searchResultsHeader = 'search.results.header';
  static const searchResultsFooter = 'search.results.footer';

  static const folderSubfolder = 'folder.subfolder';
  static const folderAsset = 'folder.asset';

  static const sharedLinkTile = 'sharedLink.tile';
  static const sharedLinkTileActions = 'sharedLink.tile.actions';
  static const sharedLinkEditFields = 'sharedLinkEdit.fields';
  static const sharedLinkEditActions = 'sharedLinkEdit.actions';
  static const sharedLinkEditCreated = 'sharedLinkEdit.created';
}

/// Built-in item ids per slot, in their built-in order. Plugins hide, reorder and rename them with
/// `contributes.builtins.<slot>`, and place their own items among them by `order` (built-in `i` has `(i + 1) * 100`).
/// `*` in an id stands for a dynamic part (`partner:<userId>`).
const Map<String, List<String>> libraryBuiltins = {
  'albums.appBar.actions': ['create'],
  LibrarySlots.albumSelectorSections: ['search', 'filters', 'toolbar', 'list'],
  LibrarySlots.albumSelectorFilters: ['all', 'sharedWithMe', 'myAlbums'],
  LibrarySlots.albumSelectorToolbar: ['sort', 'viewMode'],
  LibrarySlots.albumSelectorSort: ['title', 'assetCount', 'lastModified', 'created', 'mostRecent', 'mostOldest'],
  LibrarySlots.albumSelectorTileActions: ['open', 'delete'],
  LibrarySlots.albumOptionsSections: ['activity', 'people'],
  LibrarySlots.albumOptionsPeopleActions: ['invite'],
  LibrarySlots.albumOptionsUserMenu: ['leave', 'remove'],
  'appAlbum.appBar.actions': ['galleryView', 'menu'],
  'appAlbum.appBar.menu': ['rename', 'delete'],
  'createAlbum.appBar.actions': ['create'],
  LibrarySlots.createAlbumFields: ['title', 'description'],
  LibrarySlots.createAlbumActions: ['addPhotos'],
  'createAlbum.empty': ['hint', 'selectPhotos'],
  LibrarySlots.librarySections: ['actions', 'collections', 'quickAccess'],
  LibrarySlots.libraryActions: ['favorites', 'archived', 'sharedLinks', 'trash'],
  LibrarySlots.libraryCollections: ['people', 'places', 'onThisDevice', 'memories'],
  LibrarySlots.libraryQuickAccess: ['folders', 'lockedFolder', 'partners', 'partner:*'],
  'localAlbums.appBar.actions': ['trash', 'downloads', 'findDuplicates', 'newAlbum', 'settings'],
  LibrarySlots.localAlbumsSections: ['appAlbums', 'deviceTitle', 'deviceAlbums'],
  'remoteAlbum.appBar.actions': ['slideshow', 'activity', 'menu'],
  'remoteAlbum.appBar.menu': [
    'editAlbum',
    'addPhotos',
    'addUsers',
    'leaveAlbum',
    'toggleOrder',
    'createSharedLink',
    'options',
    'deleteAlbum',
  ],
  'remoteAlbum.header': ['pendingUploads'],
  LibrarySlots.remoteAlbumPendingUploadsActions: ['cancelUploads', 'clearFailed'],
  LibrarySlots.remoteAlbumEditDialog: ['name', 'description'],
  'peopleCollection.appBar.actions': ['search'],
  LibrarySlots.peopleCollectionTileActions: ['open', 'editName'],
  'person.appBar.actions': ['options'],
  LibrarySlots.personOptions: ['editName', 'editBirthday'],
  'place.appBar.actions': ['search'],
  LibrarySlots.placeSections: ['map', 'list'],
  'map.appBar.actions': ['back', 'settings'],
  LibrarySlots.mapControls: ['myLocation'],
  LibrarySlots.mapSettings: [
    'systemTheme',
    'darkMode',
    'divider',
    'favoritesOnly',
    'includeArchived',
    'withPartners',
    'timeRange',
  ],
  'mapLocationPicker.appBar.actions': ['back'],
  LibrarySlots.mapLocationPickerActions: ['useLocation', 'currentLocation'],
  'partnerDetail.header': ['inTimeline'],
  'partner.appBar.actions': ['add'],
  LibrarySlots.partnerTileActions: ['remove'],
  'partner.empty': ['message', 'add'],
  'userSelection.appBar.actions': ['add'],
  'activities.appBar.actions': ['like'],
  'activities.footer': ['input'],
  'downloadInfo.footer': ['clearAll'],
  LibrarySlots.pinAuthActions: ['biometric'],
  'privateGallery.appBar.actions': ['olderItems', 'lock', 'settings'],
  LibrarySlots.privateGallerySelectionAppBarActions: ['close', 'selectAll'],
  LibrarySlots.privateGallerySelectionActions: ['share', 'unhide', 'delete'],
  LibrarySlots.privateGalleryTimelineActions: ['share', 'moveToPrivate', 'delete'],
  'privateGallery.header': ['fullHiding'],
  LibrarySlots.privateGalleryLocked: ['unlock'],
  'privateFileViewer.appBar.actions': ['share', 'unhide', 'delete'],
  'privateViewer.appBar.actions': ['restore', 'delete'],
  'search.appBar.actions': ['searchType'],
  'search.appBar.menu': ['context', 'filename', 'description', 'ocr'],
  LibrarySlots.searchFilters: ['people', 'location', 'tags', 'camera', 'date', 'mediaType', 'rating', 'display'],
  LibrarySlots.searchSuggestions: ['illustration', 'quickLinks'],
  LibrarySlots.searchQuickLinks: ['recentlyTaken', 'recentlyAdded', 'videos', 'favorites'],
  LibrarySlots.searchResultsFooter: ['noMoreResults'],
  'search.empty': ['noResults'],
  'folder.appBar.actions': ['sort'],
  'folder.header': ['path'],
  LibrarySlots.sharedLinkTileActions: ['edit', 'copy', 'delete'],
  LibrarySlots.sharedLinkEditFields: [
    'title',
    'link',
    'description',
    'password',
    'slug',
    'showMetadata',
    'allowDownload',
    'allowUpload',
    'expiry',
  ],
  LibrarySlots.sharedLinkEditActions: ['delete', 'submit'],
  LibrarySlots.sharedLinkEditCreated: ['link', 'done'],
};

/// Hook ids.
abstract final class LibraryHooks {
  /// The hook of a built-in UI action: `action.<page>.<item>` (item = the built-in id in the catalog).
  static String action(String page, String item) => 'action.$page.$item';

  // Queries: `after` filters, sorts or extends what the page shows.
  static const albumsQuery = 'albums.query';
  static const albumUsersQuery = 'albumUsers.query';
  static const appAlbumsQuery = 'appAlbums.query';
  static const deviceAlbumsQuery = 'deviceAlbums.query';
  static const peopleQuery = 'people.query';
  static const placesQuery = 'places.query';
  static const mapMarkersQuery = 'map.markers.query';
  static const searchQuery = 'search.query';
  static const foldersQuery = 'folders.query';
  static const folderAssetsQuery = 'folderAssets.query';
  static const partnersQuery = 'partners.query';
  static const sharedLinksQuery = 'sharedLinks.query';
  static const activitiesQuery = 'activities.query';
  static const userSelectionQuery = 'userSelection.query';
  static const privateFilesQuery = 'privateFiles.query';

  // UI flows that are not a single built-in item.
  static const searchApply = 'search.apply';
  static const privateUnlock = 'private.unlock';
  static const lockedFolderAutoLock = 'lockedFolder.autoLock';
  static const mapFeatureTap = 'map.featureTap';

  static const queries = [
    albumsQuery,
    albumUsersQuery,
    appAlbumsQuery,
    deviceAlbumsQuery,
    peopleQuery,
    placesQuery,
    mapMarkersQuery,
    searchQuery,
    foldersQuery,
    folderAssetsQuery,
    partnersQuery,
    sharedLinksQuery,
    activitiesQuery,
    userSelectionQuery,
    privateFilesQuery,
  ];
}

/// Event names.
abstract final class LibraryEvents {
  static const albumOpened = 'album.opened';
  static const albumsFilterChanged = 'albums.filterChanged';
  static const albumsSortChanged = 'albums.sortChanged';
  static const albumsViewModeChanged = 'albums.viewModeChanged';
  static const personOpened = 'person.opened';
  static const placeOpened = 'place.opened';
  static const partnerOpened = 'partner.opened';
  static const mapOpened = 'map.opened';
  static const mapMoved = 'map.moved';
  static const mapSettingsChanged = 'map.settingsChanged';
  static const mapFeatureTapped = 'map.featureTapped';
  static const mapMarkerTapped = 'map.markerTapped';
  static const searchPerformed = 'search.performed';
  static const searchCleared = 'search.cleared';
  static const searchTypeChanged = 'search.typeChanged';
  static const folderOpened = 'folder.opened';
  static const lockedFolderLocked = 'lockedFolder.locked';
  static const lockedFolderUnlocked = 'lockedFolder.unlocked';
  static const privateLocked = 'private.locked';
  static const privateUnlocked = 'private.unlocked';

  static const all = [
    albumOpened,
    albumsFilterChanged,
    albumsSortChanged,
    albumsViewModeChanged,
    personOpened,
    placeOpened,
    partnerOpened,
    mapOpened,
    mapMoved,
    mapSettingsChanged,
    mapFeatureTapped,
    mapMarkerTapped,
    searchPerformed,
    searchCleared,
    searchTypeChanged,
    folderOpened,
    lockedFolderLocked,
    lockedFolderUnlocked,
    privateLocked,
    privateUnlocked,
  ];
}
