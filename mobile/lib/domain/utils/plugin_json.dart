import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:openapi/api.dart' show CropParameters, MirrorParameters, MosaicParameters, RotateParameters;

/// JSON shapes of domain models as plugins see them in hook arguments, hook results and host function results.
///
/// These are synchronous, cheap encodings ("AssetLite"); the kernel's `assetJson` (AssetV1) adds file paths, tags
/// and EXIF for a single asset.
abstract final class PluginJson {
  static String? iso(DateTime? value) => value?.toUtc().toIso8601String();

  static String assetType(AssetType type) => switch (type) {
    AssetType.image => 'IMAGE',
    AssetType.video => 'VIDEO',
    AssetType.audio => 'AUDIO',
    AssetType.other => 'OTHER',
  };

  static AssetType? parseAssetType(Object? value) => switch ('$value'.toUpperCase()) {
    'IMAGE' => AssetType.image,
    'VIDEO' => AssetType.video,
    'AUDIO' => AssetType.audio,
    'OTHER' => AssetType.other,
    _ => null,
  };

  static AssetVisibility? parseVisibility(Object? value) =>
      AssetVisibility.values.where((visibility) => visibility.name == '$value').firstOrNull;

  /// Any asset, local or remote.
  static Map<String, dynamic> asset(BaseAsset asset) => {
    'id': asset.id,
    'localId': asset.localId,
    'remoteId': asset.remoteId,
    'storage': asset.storage.name,
    'type': assetType(asset.type),
    'name': asset.name,
    'checksum': asset.checksum,
    'createdAt': iso(asset.createdAt),
    'updatedAt': iso(asset.updatedAt),
    'width': asset.width,
    'height': asset.height,
    'durationMs': asset.durationMs,
    'isFavorite': asset.isFavorite,
    'isEdited': asset.isEdited,
    'playbackStyle': asset.playbackStyle.name,
    ...switch (asset) {
      LocalAsset() => {
        'orientation': asset.orientation,
        'latitude': asset.latitude,
        'longitude': asset.longitude,
        'cloudId': asset.cloudId,
        'adjustmentTime': iso(asset.adjustmentTime),
      },
      RemoteAsset() => {
        'ownerId': asset.ownerId,
        'visibility': asset.visibility.name,
        'stackId': asset.stackId,
        'livePhotoVideoId': asset.livePhotoVideoId,
        'thumbHash': asset.thumbHash,
        'uploadedAt': iso(asset.uploadedAt),
        'deletedAt': iso(asset.deletedAt),
      },
    },
  };

  /// Builds an asset from the [asset] JSON (as returned by `assets.query` or a hook), so plugins can answer query
  /// hooks with assets the app did not load itself. `storage: "local"` (or a `localId` without `remoteId`) builds a
  /// device asset, anything else a server asset. Returns null when required fields are missing.
  static BaseAsset? parseAsset(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = PluginArgs.string(json['id']);
    final name = PluginArgs.string(json['name']);
    final type = parseAssetType(json['type']);
    final createdAt = PluginArgs.date(json['createdAt']);
    if (id == null || name == null || type == null || createdAt == null) {
      return null;
    }
    final updatedAt = PluginArgs.date(json['updatedAt']) ?? createdAt;
    final remoteId = PluginArgs.string(json['remoteId']);
    final isLocal = json['storage'] == 'local' || (json['localId'] != null && remoteId == null);
    if (isLocal) {
      return LocalAsset(
        id: id,
        remoteId: remoteId,
        cloudId: PluginArgs.string(json['cloudId']),
        name: name,
        checksum: PluginArgs.string(json['checksum']),
        type: type,
        createdAt: createdAt,
        updatedAt: updatedAt,
        width: PluginArgs.integer(json['width']),
        height: PluginArgs.integer(json['height']),
        durationMs: PluginArgs.integer(json['durationMs']),
        isFavorite: PluginArgs.boolean(json['isFavorite']) ?? false,
        orientation: PluginArgs.integer(json['orientation']) ?? 0,
        playbackStyle:
            AssetPlaybackStyle.values.where((style) => style.name == json['playbackStyle']).firstOrNull ??
            (type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image),
        latitude: PluginArgs.real(json['latitude']),
        longitude: PluginArgs.real(json['longitude']),
        isEdited: PluginArgs.boolean(json['isEdited']) ?? false,
      );
    }
    return RemoteAsset(
      id: remoteId ?? id,
      localId: PluginArgs.string(json['localId']),
      name: name,
      ownerId: PluginArgs.string(json['ownerId']) ?? '',
      checksum: PluginArgs.string(json['checksum']),
      type: type,
      createdAt: createdAt,
      updatedAt: updatedAt,
      uploadedAt: PluginArgs.date(json['uploadedAt']),
      width: PluginArgs.integer(json['width']),
      height: PluginArgs.integer(json['height']),
      durationMs: PluginArgs.integer(json['durationMs']),
      isFavorite: PluginArgs.boolean(json['isFavorite']) ?? false,
      thumbHash: PluginArgs.string(json['thumbHash']),
      visibility: parseVisibility(json['visibility']) ?? AssetVisibility.timeline,
      livePhotoVideoId: PluginArgs.string(json['livePhotoVideoId']),
      stackId: PluginArgs.string(json['stackId']),
      isEdited: PluginArgs.boolean(json['isEdited']) ?? false,
      deletedAt: PluginArgs.date(json['deletedAt']),
    );
  }

  static Map<String, dynamic> exif(ExifInfo exif) => {
    'fileSize': exif.fileSize,
    'description': exif.description,
    'orientation': exif.orientation,
    'timeZone': exif.timeZone,
    'dateTimeOriginal': iso(exif.dateTimeOriginal),
    'rating': exif.rating,
    'width': exif.width,
    'height': exif.height,
    'latitude': exif.latitude,
    'longitude': exif.longitude,
    'city': exif.city,
    'state': exif.state,
    'country': exif.country,
    'make': exif.make,
    'model': exif.model,
    'lens': exif.lens,
    'fNumber': exif.f,
    'focalLength': exif.mm,
    'iso': exif.iso,
    'exposureSeconds': exif.exposureSeconds,
  };

  static Map<String, dynamic> remoteAlbum(RemoteAlbum album) => {
    'id': album.id,
    'kind': 'remote',
    'name': album.name,
    'description': album.description,
    'ownerId': album.ownerId,
    'ownerName': album.ownerName,
    'createdAt': iso(album.createdAt),
    'updatedAt': iso(album.updatedAt),
    'coverAssetId': album.thumbnailAssetId,
    'isActivityEnabled': album.isActivityEnabled,
    'order': album.order.name,
    'assetCount': album.assetCount,
    'isShared': album.isShared,
  };

  static Map<String, dynamic> localAlbum(LocalAlbum album) => {
    'id': album.id,
    'kind': 'device',
    'name': album.name,
    'updatedAt': iso(album.updatedAt),
    'assetCount': album.assetCount,
    'backupSelection': album.backupSelection.name,
    'isIosSharedAlbum': album.isIosSharedAlbum,
    'linkedRemoteAlbumId': album.linkedRemoteAlbumId,
  };

  static Map<String, dynamic> user(UserDto user) => {
    'id': user.id,
    'email': user.email,
    'name': user.name,
    'isAdmin': user.isAdmin,
    'updatedAt': iso(user.updatedAt),
    'profileChangedAt': iso(user.profileChangedAt),
    'avatarColor': user.avatarColor.name,
    'memoryEnabled': user.memoryEnabled,
    'inTimeline': user.inTimeline,
    'isPartnerSharedBy': user.isPartnerSharedBy,
    'isPartnerSharedWith': user.isPartnerSharedWith,
    'hasProfileImage': user.hasProfileImage,
    'quotaUsageInBytes': user.quotaUsageInBytes,
    'quotaSizeInBytes': user.quotaSizeInBytes,
  };

  static Map<String, dynamic> person(Person person) => {
    'id': person.id,
    'name': person.name,
    'updatedAt': iso(person.updatedAt),
    'birthDate': iso(person.birthDate),
  };

  static Map<String, dynamic> tag(Tag tag) => {'id': tag.id, 'value': tag.value, 'name': tag.value.split('/').last};

  static Map<String, dynamic> marker(Marker marker) => {
    'id': marker.assetId,
    'assetId': marker.assetId,
    'latitude': marker.location.latitude,
    'longitude': marker.location.longitude,
  };

  static Map<String, dynamic> memory(Memory memory) => {
    'id': memory.id,
    'type': memory.type.name,
    'year': memory.data.year,
    'personName': memory.data.personName,
    'createdAt': iso(memory.createdAt),
    'updatedAt': iso(memory.updatedAt),
    'memoryAt': iso(memory.memoryAt),
    'isSaved': memory.isSaved,
    'ownerId': memory.ownerId,
    'assetIds': [for (final asset in memory.assets) asset.id],
  };

  /// A non-destructive edit as `{ "action": "crop" | "rotate" | "mirror" | "mosaic", "parameters": {...} }`.
  static Map<String, dynamic> edit(AssetEdit edit) => switch (edit) {
    CropEdit(:final parameters) => {'action': 'crop', 'parameters': parameters.toJson()},
    RotateEdit(:final parameters) => {'action': 'rotate', 'parameters': parameters.toJson()},
    MirrorEdit(:final parameters) => {'action': 'mirror', 'parameters': parameters.toJson()},
    MosaicEdit(:final parameters) => {'action': 'mosaic', 'parameters': parameters.toJson()},
  };

  static AssetEdit? parseEdit(Object? json) {
    if (json is! Map) {
      return null;
    }
    final parameters = json['parameters'];
    return switch (json['action']) {
      'crop' => switch (CropParameters.fromJson(parameters)) {
        final value? => CropEdit(value),
        null => null,
      },
      'rotate' => switch (RotateParameters.fromJson(parameters)) {
        final value? => RotateEdit(value),
        null => null,
      },
      'mirror' => switch (MirrorParameters.fromJson(parameters)) {
        final value? => MirrorEdit(value),
        null => null,
      },
      'mosaic' => switch (MosaicParameters.fromJson(parameters)) {
        final value? => MosaicEdit(value),
        null => null,
      },
      _ => null,
    };
  }

  static List<AssetEdit> parseEdits(Object? json) =>
      json is List ? json.map(parseEdit).nonNulls.toList() : const <AssetEdit>[];

  /// List codecs for query hooks: plugins answer with a subset, a new order or (where a builder exists) new items.
  static PluginListCodec<T> list<T>(String Function(T item) id, Map<String, dynamic> Function(T item) toJson) =>
      PluginListCodec<T>(id: id, toJson: toJson);

  static PluginListCodec<BaseAsset> assets() =>
      PluginListCodec<BaseAsset>(id: (asset) => asset.id, toJson: asset, fromJson: parseAsset);

  static PluginListCodec<RemoteAlbum> remoteAlbums() =>
      PluginListCodec<RemoteAlbum>(id: (album) => album.id, toJson: remoteAlbum);

  static PluginListCodec<LocalAlbum> localAlbums() =>
      PluginListCodec<LocalAlbum>(id: (album) => album.id, toJson: localAlbum);

  static PluginListCodec<UserDto> users() => PluginListCodec<UserDto>(id: (user) => user.id, toJson: user);

  static PluginListCodec<Person> people() => PluginListCodec<Person>(id: (person) => person.id, toJson: person);

  static PluginListCodec<Tag> tags() => PluginListCodec<Tag>(
    id: (tag) => tag.id,
    toJson: tag,
    fromJson: (json) => json['id'] is String && json['value'] is String
        ? Tag(id: json['id'] as String, value: json['value'] as String)
        : null,
  );

  static PluginListCodec<Marker> markers() => PluginListCodec<Marker>(id: (marker) => marker.assetId, toJson: marker);

  static PluginListCodec<Memory> memories() => PluginListCodec<Memory>(id: (memory) => memory.id, toJson: memory);

  /// Converts settings values and other plain Dart values to JSON: enums by name, dates as ISO strings.
  static Object? value(Object? value) => switch (value) {
    null || bool() || num() || String() => value,
    Enum() => value.name,
    DateTime() => iso(value),
    Iterable() => [for (final item in value) PluginJson.value(item)],
    Map() => {for (final entry in value.entries) '${entry.key}': PluginJson.value(entry.value)},
    _ => value.toString(),
  };
}
