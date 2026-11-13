/// Hook and event ids of the data layer (services, repositories, network, settings, sync, uploads).
///
/// Ids follow the plugin platform conventions: hooks are `<domain>.<verb>`, queries are `<domain>.query` (only the
/// `after` phase is meaningful: it filters, sorts or extends the result), events are `<domain>.<pastTense>`.
/// Arguments and results are documented in `docs/plugins/data.md`.
library;

/// Hooks run by data-layer call sites through `PluginHooks.run` / `PluginHooks.filter`.
abstract final class DataHooks {
  // ---- assets ------------------------------------------------------------------------------------------------
  static const assetFavorite = 'asset.favorite';
  static const assetVisibility = 'asset.visibility';
  static const assetSetDate = 'asset.setDate';
  static const assetSetLocation = 'asset.setLocation';
  static const assetSetDescription = 'asset.setDescription';
  static const assetSetRating = 'asset.setRating';
  static const assetUpdate = 'asset.update';
  static const assetTrash = 'asset.trash';
  static const assetRestore = 'asset.restore';
  static const assetDelete = 'asset.delete';
  static const assetStack = 'asset.stack';
  static const assetUnstack = 'asset.unstack';
  static const assetEdit = 'asset.edit';
  static const assetMove = 'asset.move';
  static const assetPrivate = 'asset.private';
  static const trashEmpty = 'trash.empty';
  static const trashRestoreAll = 'trash.restoreAll';

  // ---- albums ------------------------------------------------------------------------------------------------
  static const albumCreate = 'album.create';
  static const albumRename = 'album.rename';
  static const albumUpdate = 'album.update';
  static const albumDelete = 'album.delete';
  static const albumAddAssets = 'album.addAssets';
  static const albumRemoveAssets = 'album.removeAssets';
  static const albumShare = 'album.share';
  static const albumUnshare = 'album.unshare';
  static const albumSetBackup = 'album.setBackup';

  // ---- tags, people, partners, shared links, users -----------------------------------------------------------
  static const tagCreate = 'tag.create';
  static const tagDelete = 'tag.delete';
  static const tagAssign = 'tag.assign';
  static const tagUnassign = 'tag.unassign';
  static const personUpdate = 'person.update';
  static const partnerAdd = 'partner.add';
  static const partnerRemove = 'partner.remove';
  static const partnerUpdate = 'partner.update';
  static const sharedLinkCreate = 'sharedLink.create';
  static const sharedLinkUpdate = 'sharedLink.update';
  static const sharedLinkDelete = 'sharedLink.delete';
  static const userUpdate = 'user.update';
  static const activityAdd = 'activity.add';
  static const activityRemove = 'activity.remove';

  // ---- private folder, downloads, media writes ----------------------------------------------------------------
  static const privateHide = 'private.hide';
  static const privateUnhide = 'private.unhide';
  static const privateDelete = 'private.delete';
  static const downloadAssets = 'download.assets';
  static const downloadsRuleSet = 'downloadsRule.set';
  static const downloadsOrganize = 'downloads.organize';
  static const fileDownload = 'files.download';
  static const mediaSave = 'media.save';
  static const mediaReplace = 'media.replace';

  // ---- uploads, backup, sync ---------------------------------------------------------------------------------
  static const uploadAsset = 'upload.asset';
  static const backupStart = 'backup.start';
  static const backupStop = 'backup.stop';
  static const syncRun = 'sync.run';

  // ---- settings, network, database ---------------------------------------------------------------------------
  static const settingsSet = 'settings.set';
  static const netRequest = 'net.request';
  static const dbExecute = 'db.execute';

  // ---- queries (after phase changes the result) --------------------------------------------------------------
  static const albumQuery = 'album.query';
  static const albumAssetsQuery = 'album.assets.query';
  static const searchQuery = 'search.query';
  static const personQuery = 'person.query';
  static const placeQuery = 'place.query';
  static const mapQuery = 'map.query';
  static const memoryQuery = 'memory.query';
  static const partnerQuery = 'partner.query';
  static const tagQuery = 'tag.query';
  static const sharedLinkQuery = 'sharedLink.query';
  static const folderQuery = 'folder.query';
  static const trashQuery = 'trash.query';
  static const privateQuery = 'private.query';

  static const all = [
    assetFavorite,
    assetVisibility,
    assetSetDate,
    assetSetLocation,
    assetSetDescription,
    assetSetRating,
    assetUpdate,
    assetTrash,
    assetRestore,
    assetDelete,
    assetStack,
    assetUnstack,
    assetEdit,
    assetMove,
    assetPrivate,
    trashEmpty,
    trashRestoreAll,
    albumCreate,
    albumRename,
    albumUpdate,
    albumDelete,
    albumAddAssets,
    albumRemoveAssets,
    albumShare,
    albumUnshare,
    albumSetBackup,
    tagCreate,
    tagDelete,
    tagAssign,
    tagUnassign,
    personUpdate,
    partnerAdd,
    partnerRemove,
    partnerUpdate,
    sharedLinkCreate,
    sharedLinkUpdate,
    sharedLinkDelete,
    userUpdate,
    activityAdd,
    activityRemove,
    privateHide,
    privateUnhide,
    privateDelete,
    downloadAssets,
    downloadsRuleSet,
    downloadsOrganize,
    fileDownload,
    mediaSave,
    mediaReplace,
    uploadAsset,
    backupStart,
    backupStop,
    syncRun,
    settingsSet,
    netRequest,
    dbExecute,
    albumQuery,
    albumAssetsQuery,
    searchQuery,
    personQuery,
    placeQuery,
    mapQuery,
    memoryQuery,
    partnerQuery,
    tagQuery,
    sharedLinkQuery,
    folderQuery,
    trashQuery,
    privateQuery,
  ];
}

/// Events emitted by the data layer after an operation succeeded.
abstract final class DataEvents {
  static const assetFavorited = 'asset.favorited';
  static const assetVisibilityChanged = 'asset.visibilityChanged';
  static const assetDateChanged = 'asset.dateChanged';
  static const assetLocationChanged = 'asset.locationChanged';
  static const assetDescriptionChanged = 'asset.descriptionChanged';
  static const assetRatingChanged = 'asset.ratingChanged';
  static const assetUpdated = 'asset.updated';
  static const assetTrashed = 'asset.trashed';
  static const assetRestored = 'asset.restored';
  static const assetDeleted = 'asset.deleted';
  static const assetStacked = 'asset.stacked';
  static const assetUnstacked = 'asset.unstacked';
  static const assetEdited = 'asset.edited';
  static const assetMoved = 'asset.moved';
  static const assetPrivateChanged = 'asset.privateChanged';
  static const assetCreated = 'asset.created';
  static const assetUploaded = 'asset.uploaded';
  static const assetDownloaded = 'asset.downloaded';
  static const trashEmptied = 'trash.emptied';

  static const albumCreated = 'album.created';
  static const albumRenamed = 'album.renamed';
  static const albumUpdated = 'album.updated';
  static const albumDeleted = 'album.deleted';
  static const albumAssetsAdded = 'album.assetsAdded';
  static const albumAssetsRemoved = 'album.assetsRemoved';
  static const albumShared = 'album.shared';
  static const albumUnshared = 'album.unshared';
  static const albumBackupChanged = 'album.backupChanged';

  static const tagCreated = 'tag.created';
  static const tagDeleted = 'tag.deleted';
  static const tagAssigned = 'tag.assigned';
  static const tagUnassigned = 'tag.unassigned';
  static const personUpdated = 'person.updated';
  static const partnerAdded = 'partner.added';
  static const partnerRemoved = 'partner.removed';
  static const partnerUpdated = 'partner.updated';
  static const sharedLinkCreated = 'sharedLink.created';
  static const sharedLinkUpdated = 'sharedLink.updated';
  static const sharedLinkDeleted = 'sharedLink.deleted';
  static const userUpdated = 'user.updated';
  static const activityAdded = 'activity.added';
  static const activityRemoved = 'activity.removed';

  static const privateHidden = 'private.hidden';
  static const privateUnhidden = 'private.unhidden';
  static const privateDeleted = 'private.deleted';
  static const downloadsRuleChanged = 'downloadsRule.changed';
  static const downloadsOrganized = 'downloads.organized';
  static const downloadStarted = 'download.started';
  static const downloadProgress = 'download.progress';
  static const downloadCompleted = 'download.completed';
  static const downloadFailed = 'download.failed';
  static const downloadCancelled = 'download.cancelled';
  static const mediaSaved = 'media.saved';
  static const mediaReplaced = 'media.replaced';
  static const mediaRestored = 'media.restored';

  static const uploadStarted = 'upload.started';
  static const uploadProgress = 'upload.progress';
  static const uploadCompleted = 'upload.completed';
  static const uploadFailed = 'upload.failed';
  static const uploadSkipped = 'upload.skipped';
  static const backupStarted = 'backup.started';
  static const backupStopped = 'backup.stopped';
  static const syncStarted = 'sync.started';
  static const syncCompleted = 'sync.completed';
  static const syncFailed = 'sync.failed';

  static const settingsChanged = 'settings.changed';
  static const netCompleted = 'net.completed';
  static const dbChanged = 'db.changed';

  /// Events delivered at most this often per key (download and upload ids, table sets).
  static const throttled = {downloadProgress, uploadProgress, dbChanged};

  static const all = [
    assetFavorited,
    assetVisibilityChanged,
    assetDateChanged,
    assetLocationChanged,
    assetDescriptionChanged,
    assetRatingChanged,
    assetUpdated,
    assetTrashed,
    assetRestored,
    assetDeleted,
    assetStacked,
    assetUnstacked,
    assetEdited,
    assetMoved,
    assetPrivateChanged,
    assetCreated,
    assetUploaded,
    assetDownloaded,
    trashEmptied,
    albumCreated,
    albumRenamed,
    albumUpdated,
    albumDeleted,
    albumAssetsAdded,
    albumAssetsRemoved,
    albumShared,
    albumUnshared,
    albumBackupChanged,
    tagCreated,
    tagDeleted,
    tagAssigned,
    tagUnassigned,
    personUpdated,
    partnerAdded,
    partnerRemoved,
    partnerUpdated,
    sharedLinkCreated,
    sharedLinkUpdated,
    sharedLinkDeleted,
    userUpdated,
    activityAdded,
    activityRemoved,
    privateHidden,
    privateUnhidden,
    privateDeleted,
    downloadsRuleChanged,
    downloadsOrganized,
    downloadStarted,
    downloadProgress,
    downloadCompleted,
    downloadFailed,
    downloadCancelled,
    mediaSaved,
    mediaReplaced,
    mediaRestored,
    uploadStarted,
    uploadProgress,
    uploadCompleted,
    uploadFailed,
    uploadSkipped,
    backupStarted,
    backupStopped,
    syncStarted,
    syncCompleted,
    syncFailed,
    settingsChanged,
    netCompleted,
    dbChanged,
  ];
}
