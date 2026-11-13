import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/infrastructure/repositories/app_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';
import 'package:immich_mobile/models/activities/activity.model.dart';
import 'package:immich_mobile/models/folder/recursive_folder.model.dart';
import 'package:immich_mobile/models/folder/root_folder.model.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/models/shared_link/shared_link.model.dart';
import 'package:immich_mobile/utils/option.dart';

/// JSON shapes of the library area's objects, as plugins see them in slot contexts, hook arguments and results,
/// events and host function results (`docs/plugins/library.md`, "Objects").
abstract final class LibraryJson {
  static String? _date(DateTime? value) => value?.toUtc().toIso8601String();

  static DateTime? _parseDate(Object? value) => switch (value) {
    final String s => DateTime.tryParse(s),
    final num n => DateTime.fromMillisecondsSinceEpoch(n.toInt()),
    _ => null,
  };

  static String? _string(Object? value) => value == null ? null : '$value';

  static String assetType(AssetType type) => switch (type) {
    AssetType.image => 'IMAGE',
    AssetType.video => 'VIDEO',
    AssetType.audio => 'AUDIO',
    AssetType.other => 'OTHER',
  };

  /// A server album (`kind: "remote"`).
  static Map<String, dynamic> remoteAlbum(RemoteAlbum album) => {
    'id': album.id,
    'kind': 'remote',
    'name': album.name,
    'description': album.description,
    'ownerId': album.ownerId,
    'ownerName': album.ownerName,
    'createdAt': _date(album.createdAt),
    'updatedAt': _date(album.updatedAt),
    'thumbnailAssetId': album.thumbnailAssetId,
    'assetCount': album.assetCount,
    'isShared': album.isShared,
    'isActivityEnabled': album.isActivityEnabled,
    'order': album.order.name,
  };

  /// An album of the phone's gallery (`kind: "device"`).
  static Map<String, dynamic> deviceAlbum(LocalAlbum album) => {
    'id': album.id,
    'kind': 'device',
    'name': album.name,
    'updatedAt': _date(album.updatedAt),
    'assetCount': album.assetCount,
    'backupSelection': album.backupSelection.name,
    'isIosSharedAlbum': album.isIosSharedAlbum,
    'linkedRemoteAlbumId': album.linkedRemoteAlbumId,
  };

  /// An album kept by this app on the phone (`kind: "app"`).
  static Map<String, dynamic> appAlbum(AppAlbum album) => {
    'id': album.id,
    'kind': 'app',
    'name': album.name,
    'createdAt': _date(album.createdAt),
    'assetCount': album.assetIds.length,
    'assetIds': album.assetIds,
  };

  static Map<String, dynamic> person(Person person) => {
    'id': person.id,
    'name': person.name,
    'birthDate': _date(person.birthDate),
    'updatedAt': _date(person.updatedAt),
  };

  static Person? personFromJson(Object? json) {
    if (json is String) {
      return Person(id: json, name: '');
    }
    if (json is! Map || json['id'] == null) {
      return null;
    }
    return Person(
      id: '${json['id']}',
      name: _string(json['name']) ?? '',
      birthDate: _parseDate(json['birthDate']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  /// A place: a city with one of its photos. `id` is the city name.
  static Map<String, dynamic> place((String, String) place) => {'id': place.$1, 'name': place.$1, 'assetId': place.$2};

  static Map<String, dynamic> user(UserDto user) => {
    'id': user.id,
    'name': user.name,
    'email': user.email,
    'isAdmin': user.isAdmin,
    'hasProfileImage': user.hasProfileImage,
    'profileChangedAt': _date(user.profileChangedAt),
    'avatarColor': user.avatarColor.name,
    'isPartnerSharedBy': user.isPartnerSharedBy,
    'isPartnerSharedWith': user.isPartnerSharedWith,
    'inTimeline': user.inTimeline,
  };

  static Map<String, dynamic> partner(Partner partner) => {
    'id': partner.id,
    'name': partner.name,
    'email': partner.email,
    'hasProfileImage': partner.hasProfileImage,
    'profileChangedAt': _date(partner.profileChangedAt),
    'avatarColor': partner.avatarColor.name,
    'inTimeline': partner.inTimeline,
  };

  static Map<String, dynamic> sharedLink(SharedLink link) => {
    'id': link.id,
    'title': link.title,
    'description': link.description,
    'type': link.type.name,
    'key': link.key,
    'slug': link.slug,
    'password': link.password,
    'hasPassword': link.password?.isNotEmpty ?? false,
    'allowDownload': link.allowDownload,
    'allowUpload': link.allowUpload,
    'showMetadata': link.showMetadata,
    'expiresAt': _date(link.expiresAt),
    'thumbAssetId': link.thumbAssetId,
  };

  static Map<String, dynamic> folder(RootFolder folder) => {
    'path': folder.path,
    'name': folder is RecursiveFolder ? folder.name : '',
    'subfolderCount': folder.subfolders.length,
  };

  static Map<String, dynamic> activity(Activity activity) => {
    'id': activity.id,
    'albumId': activity.albumId,
    'assetId': activity.assetId,
    'type': activity.type.name,
    'comment': activity.comment,
    'createdAt': _date(activity.createdAt),
    'user': user(activity.user),
  };

  static Map<String, dynamic> privateFile(PrivateFile file) => {
    'id': file.file,
    'path': file.file,
    'thumbPath': file.thumb,
    'originalPath': file.originalPath,
    'name': file.name,
    'mime': file.mime,
    'takenAt': _date(file.takenAt),
    'width': file.width,
    'height': file.height,
    'durationMs': file.durationMs,
    'isVideo': file.isVideo,
  };

  /// A compact asset (the AssetV1 fields that need no I/O). Full AssetV1 comes from the `assets.get` host function.
  static Map<String, dynamic> asset(BaseAsset asset) => {
    'id': asset.id,
    'remoteId': asset.remoteId,
    'localId': asset.localId,
    'type': assetType(asset.type),
    'originalFileName': asset.name,
    'checksum': asset.checksum,
    'fileCreatedAt': _date(asset.createdAt),
    'fileModifiedAt': _date(asset.updatedAt),
    'isFavorite': asset.isFavorite,
    'isEdited': asset.isEdited,
    'width': asset.width,
    'height': asset.height,
    'durationMs': asset.durationMs,
    'isLocal': asset.hasLocal,
    'isRemote': asset.hasRemote,
    if (asset is RemoteAsset) ...{
      'ownerId': asset.ownerId,
      'visibility': asset.visibility.name,
      'thumbhash': asset.thumbHash,
      'stackId': asset.stackId,
    },
  };

  static String _mediaType(AssetType type) => switch (type) {
    AssetType.image => 'IMAGE',
    AssetType.video => 'VIDEO',
    _ => 'ALL',
  };

  static AssetType _parseMediaType(Object? value) => switch (value) {
    'IMAGE' || 'image' => AssetType.image,
    'VIDEO' || 'video' => AssetType.video,
    _ => AssetType.other,
  };

  /// The search page's filter. `rating`: absent or `null` = no filter, `"unrated"`, or 1 to 5.
  static Map<String, dynamic> searchFilter(SearchFilter filter) => {
    'context': filter.context,
    'filename': filter.filename,
    'description': filter.description,
    'ocr': filter.ocr,
    'language': filter.language,
    'assetId': filter.assetId,
    'people': [for (final person in filter.people) person.id],
    'peopleNames': {for (final person in filter.people) person.id: person.name},
    'tags': [
      for (final tag in filter.tags ?? const <Tag>{}) {'id': tag.id, 'value': tag.value},
    ],
    'location': {'country': filter.location.country, 'state': filter.location.state, 'city': filter.location.city},
    'camera': {'make': filter.camera.make, 'model': filter.camera.model},
    'date': {'takenAfter': _date(filter.date.takenAfter), 'takenBefore': _date(filter.date.takenBefore)},
    'rating': switch (filter.rating.rating) {
      None() => null,
      Some(:final value) => value ?? 'unrated',
    },
    'display': {
      'notInAlbum': filter.display.isNotInAlbum,
      'archive': filter.display.isArchive,
      'favorite': filter.display.isFavorite,
    },
    'mediaType': _mediaType(filter.mediaType),
    'isEmpty': filter.isEmpty,
  };

  /// Reads a filter from plugin JSON. Missing fields keep their value from [base] (default: an empty filter).
  static SearchFilter searchFilterFromJson(Object? json, {SearchFilter? base}) {
    final start =
        base ??
        const SearchFilter(
          people: {},
          location: SearchLocationFilter(),
          camera: SearchCameraFilter(),
          date: SearchDateFilter(),
          display: SearchDisplayFilters(isNotInAlbum: false, isArchive: false, isFavorite: false),
          rating: SearchRatingFilter(),
          mediaType: AssetType.other,
        );
    if (json is! Map) {
      return start;
    }

    String? text(String key, String? current) => json.containsKey(key) ? _string(json[key]) : current;

    var people = start.people;
    if (json['people'] is List) {
      final names = json['peopleNames'] is Map ? json['peopleNames'] as Map : const {};
      people = {
        for (final entry in json['people'] as List)
          if (personFromJson(entry) case final person?)
            person.name.isEmpty && names[person.id] != null ? person.copyWith(name: '${names[person.id]}') : person,
      };
    }

    var tags = start.tags;
    if (json['tags'] is List) {
      tags = {
        for (final entry in json['tags'] as List)
          if (entry is Map && entry['id'] != null)
            Tag(id: '${entry['id']}', value: _string(entry['value']) ?? '')
          else if (entry is String)
            Tag(id: entry, value: entry),
      };
    }

    var location = start.location;
    if (json['location'] is Map) {
      final value = json['location'] as Map;
      location = SearchLocationFilter(
        country: _string(value['country']),
        state: _string(value['state']),
        city: _string(value['city']),
      );
    }

    var camera = start.camera;
    if (json['camera'] is Map) {
      final value = json['camera'] as Map;
      camera = SearchCameraFilter(make: _string(value['make']), model: _string(value['model']));
    }

    var date = start.date;
    if (json['date'] is Map) {
      final value = json['date'] as Map;
      date = SearchDateFilter(
        takenAfter: _parseDate(value['takenAfter']),
        takenBefore: _parseDate(value['takenBefore']),
      );
    }

    var rating = start.rating;
    if (json.containsKey('rating')) {
      rating = switch (json['rating']) {
        null => const SearchRatingFilter(),
        'unrated' => const SearchRatingFilter(rating: Option.some(null)),
        final num n => SearchRatingFilter(rating: Option.some(n.toInt())),
        final String s when int.tryParse(s) != null => SearchRatingFilter(rating: Option.some(int.parse(s))),
        _ => start.rating,
      };
    }

    var display = start.display;
    if (json['display'] is Map) {
      final value = json['display'] as Map;
      display = SearchDisplayFilters(
        isNotInAlbum: value['notInAlbum'] == true,
        isArchive: value['archive'] == true,
        isFavorite: value['favorite'] == true,
      );
    }

    return start.copyWith(
      context: text('context', start.context),
      filename: text('filename', start.filename),
      description: text('description', start.description),
      ocr: text('ocr', start.ocr),
      language: text('language', start.language),
      assetId: text('assetId', start.assetId),
      people: people,
      tags: tags,
      location: location,
      camera: camera,
      date: date,
      rating: rating,
      display: display,
      mediaType: json.containsKey('mediaType') ? _parseMediaType(json['mediaType']) : start.mediaType,
    );
  }
}
