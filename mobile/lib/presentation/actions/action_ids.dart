/// Stable ids of the built-in actions (`ActionBuilder.id`) and of the slots that list them.
///
/// An action keeps its id wherever it is shown, so `action.<id>` is the plugin hook for it and the id plugins use to
/// hide, reorder or rename it in any bar or menu (`contributes.builtins.<slot>`).
library;

abstract final class ActionIds {
  static const addToAppAlbum = 'addToAppAlbum';
  static const advancedInfo = 'advancedInfo';
  static const archive = 'archive';
  static const cast = 'cast';
  static const delete = 'delete';
  static const deleteLocal = 'deleteLocal';
  static const deviceFavorite = 'deviceFavorite';
  static const download = 'download';
  static const edit = 'edit';
  static const editDateTime = 'editDateTime';
  static const editLocation = 'editLocation';
  static const favorite = 'favorite';
  static const lock = 'lock';
  static const moveToPrivate = 'moveToPrivate';
  static const openInBrowser = 'openInBrowser';
  static const partnerAdd = 'partnerAdd';
  static const partnerRemove = 'partnerRemove';
  static const passkeyCreate = 'passkeyCreate';
  static const passkeyDelete = 'passkeyDelete';
  static const passkeyRename = 'passkeyRename';
  static const plugins = 'plugins';
  static const removeFromAlbum = 'removeFromAlbum';
  static const removeFromAppAlbum = 'removeFromAppAlbum';
  static const restoreTrash = 'restoreTrash';
  static const setAlbumCover = 'setAlbumCover';
  static const setProfilePicture = 'setProfilePicture';
  static const share = 'share';
  static const shareLink = 'shareLink';
  static const similarPhotos = 'similarPhotos';
  static const slideshow = 'slideshow';
  static const stack = 'stack';
  static const tag = 'tag';
  static const untag = 'untag';
  static const upload = 'upload';

  /// Every built-in action id.
  static const all = [
    addToAppAlbum,
    advancedInfo,
    archive,
    cast,
    delete,
    deleteLocal,
    deviceFavorite,
    download,
    edit,
    editDateTime,
    editLocation,
    favorite,
    lock,
    moveToPrivate,
    openInBrowser,
    partnerAdd,
    partnerRemove,
    passkeyCreate,
    passkeyDelete,
    passkeyRename,
    plugins,
    removeFromAlbum,
    removeFromAppAlbum,
    restoreTrash,
    setAlbumCover,
    setProfilePicture,
    share,
    shareLink,
    similarPhotos,
    slideshow,
    stack,
    tag,
    untag,
    upload,
  ];

  /// Ids of the viewer bar and menu entries that are not `ActionBuilder`s.
  static const openInfo = 'openInfo';
  static const viewInTimeline = 'viewInTimeline';
  static const likeActivity = 'likeActivity';
  static const motionPhoto = 'motionPhoto';
  static const addTo = 'addTo';

  /// The item id of each `ActionButtonType` (by enum name) in the viewer ⋮ menu: the action id of the builder it
  /// builds, so a rule for `archive` covers both "Archive" and "Unarchive".
  static const byActionButtonType = <String, String>{
    'openInfo': openInfo,
    'likeActivity': likeActivity,
    'share': share,
    'shareLink': shareLink,
    'cast': cast,
    'setAlbumCover': setAlbumCover,
    'similarPhotos': similarPhotos,
    'setProfilePicture': setProfilePicture,
    'viewInTimeline': viewInTimeline,
    'slideshow': slideshow,
    'download': download,
    'upload': upload,
    'openInBrowser': openInBrowser,
    'unstack': stack,
    'archive': archive,
    'unarchive': archive,
    'moveToLockFolder': lock,
    'removeFromLockFolder': lock,
    'removeFromAlbum': removeFromAlbum,
    'restoreTrash': restoreTrash,
    'deleteLocal': deleteLocal,
    'delete': delete,
    'advancedInfo': advancedInfo,
  };

  /// Item id for an `ActionButtonType` enum name; unknown names map to themselves.
  static String forActionButtonType(String name) => byActionButtonType[name] ?? name;
}

/// Slot ids of the bars and menus that list actions.
abstract final class ActionSlots {
  /// Every multi-select sheet; rules here apply to all of them, before the per-sheet slot.
  static const selection = 'selection.actions';

  /// Per-sheet slots: `selection.<sheet>.actions`.
  static String selectionSheet(String sheet) => 'selection.$sheet.actions';

  /// The slots one selection sheet reads, generic first.
  static List<String> selectionSlots(String sheet) => [selection, selectionSheet(sheet)];

  /// Sections below the action row of every selection sheet (built-in: `addToAlbum`).
  static const selectionSections = 'selection.sections';

  /// Buttons next to the selection count at the top of the timeline (built-ins: `clear`, `selectAll`).
  static const selectionStatus = 'selection.status';

  /// The "Add to" menu of the viewer bottom bar (built-ins: `album`, `archive`, `lock`). The viewer's own bars and
  /// menus are named by the viewer area.
  static const viewerAddMenu = 'viewer.addMenu';

  /// `<page>.appBar.actions` and `<page>.appBar.menu`.
  static String appBarActions(String page) => '$page.appBar.actions';
  static String appBarMenu(String page) => '$page.appBar.menu';
}

/// Names of the selection sheets (`sheet` in the slot context, `<sheet>` in `selection.<sheet>.actions`).
abstract final class SelectionSheets {
  static const general = 'general';
  static const deviceLibrary = 'deviceLibrary';
  static const archive = 'archive';
  static const favorite = 'favorite';
  static const localAlbum = 'localAlbum';
  static const partner = 'partner';
  static const remoteAlbum = 'remoteAlbum';
  static const lockedFolder = 'lockedFolder';
  static const trash = 'trash';
  static const private = 'private';
}
