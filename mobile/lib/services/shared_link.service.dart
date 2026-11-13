import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/models/shared_link/shared_link.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final sharedLinkServiceProvider = Provider((ref) => SharedLinkService(ref.watch(apiServiceProvider)));

class SharedLinkService {
  final ApiService _apiService;
  final Logger _log = Logger("SharedLinkService");

  SharedLinkService(this._apiService);

  /// Plugins can filter or sort the list through `sharedLink.query`.
  Future<AsyncValue<List<SharedLink>>> getAllSharedLinks() async {
    try {
      final list = await _apiService.sharedLinksApi.getAllSharedLinks();
      final links = list?.map(SharedLink.fromDto).toList() ?? <SharedLink>[];
      return AsyncData(
        await PluginHooks.filterList<SharedLink>(
          DataHooks.sharedLinkQuery,
          () => const {},
          links,
          () => PluginListCodec<SharedLink>(id: (link) => link.id, toJson: sharedLinkJson),
        ),
      );
    } catch (e, stack) {
      _log.severe("Failed to fetch shared links", e, stack);
      return AsyncError(e, stack);
    }
  }

  static Map<String, dynamic> sharedLinkJson(SharedLink link) => {
    'id': link.id,
    'title': link.title,
    'type': link.type.name,
    'key': link.key,
    'slug': link.slug,
    'description': link.description,
    'allowDownload': link.allowDownload,
    'allowUpload': link.allowUpload,
    'showMetadata': link.showMetadata,
    'hasPassword': link.password != null,
    'expiresAt': link.expiresAt?.toUtc().toIso8601String(),
    'thumbAssetId': link.thumbAssetId,
  };

  Future<void> deleteSharedLink(String id) => PluginHooks.run<void>(
    DataHooks.sharedLinkDelete,
    () => {'id': id},
    () => _deleteSharedLink(id),
    event: DataEvents.sharedLinkDeleted,
  );

  Future<void> _deleteSharedLink(String id) async {
    try {
      return await _apiService.sharedLinksApi.removeSharedLink(id);
    } catch (e) {
      _log.severe("Failed to delete shared link id - $id", e);
    }
  }

  Future<SharedLink?> createSharedLink({
    required bool showMeta,
    required bool allowDownload,
    required bool allowUpload,
    String? description,
    String? password,
    String? slug,
    String? albumId,
    List<String>? assetIds,
    DateTime? expiresAt,
  }) => PluginHooks.run<SharedLink?>(
    DataHooks.sharedLinkCreate,
    () => {
      'albumId': albumId,
      'assetIds': assetIds,
      'showMetadata': showMeta,
      'allowDownload': allowDownload,
      'allowUpload': allowUpload,
      'description': description,
      'slug': slug,
      'hasPassword': password != null,
      'expiresAt': expiresAt?.toUtc().toIso8601String(),
    },
    () => _createSharedLink(
      showMeta: showMeta,
      allowDownload: allowDownload,
      allowUpload: allowUpload,
      description: description,
      password: password,
      slug: slug,
      albumId: albumId,
      assetIds: assetIds,
      expiresAt: expiresAt,
    ),
    withArgs: (args) => _createSharedLink(
      showMeta: PluginArgs.boolean(args['showMetadata']) ?? showMeta,
      allowDownload: PluginArgs.boolean(args['allowDownload']) ?? allowDownload,
      allowUpload: PluginArgs.boolean(args['allowUpload']) ?? allowUpload,
      description: PluginArgs.string(args['description']),
      password: password,
      slug: PluginArgs.string(args['slug']),
      albumId: PluginArgs.string(args['albumId']),
      assetIds: args['assetIds'] == null ? null : PluginArgs.strings(args['assetIds']),
      expiresAt: PluginArgs.date(args['expiresAt']),
    ),
    encode: (link) => link == null ? null : sharedLinkJson(link),
    event: DataEvents.sharedLinkCreated,
    eventData: (args, link) => link == null ? args : sharedLinkJson(link),
  );

  Future<SharedLink?> _createSharedLink({
    required bool showMeta,
    required bool allowDownload,
    required bool allowUpload,
    String? description,
    String? password,
    String? slug,
    String? albumId,
    List<String>? assetIds,
    DateTime? expiresAt,
  }) async {
    try {
      final type = albumId != null ? SharedLinkType.ALBUM : SharedLinkType.INDIVIDUAL;
      SharedLinkCreateDto? dto;
      if (type == SharedLinkType.ALBUM) {
        dto = SharedLinkCreateDto(
          type: type,
          albumId: albumId == null ? const Optional.absent() : Optional.present(albumId),
          showMetadata: Optional.present(showMeta),
          allowDownload: Optional.present(allowDownload),
          allowUpload: Optional.present(allowUpload),
          expiresAt: expiresAt == null ? const Optional.absent() : Optional.present(expiresAt),
          description: description == null ? const Optional.absent() : Optional.present(description),
          password: password == null ? const Optional.absent() : Optional.present(password),
          slug: slug == null ? const Optional.absent() : Optional.present(slug),
        );
      } else if (assetIds != null) {
        dto = SharedLinkCreateDto(
          type: type,
          showMetadata: Optional.present(showMeta),
          allowDownload: Optional.present(allowDownload),
          allowUpload: Optional.present(allowUpload),
          expiresAt: expiresAt == null ? const Optional.absent() : Optional.present(expiresAt),
          description: description == null ? const Optional.absent() : Optional.present(description),
          password: password == null ? const Optional.absent() : Optional.present(password),
          slug: slug == null ? const Optional.absent() : Optional.present(slug),
          assetIds: Optional.present(assetIds),
        );
      }

      if (dto != null) {
        final responseDto = await _apiService.sharedLinksApi.createSharedLink(dto);
        if (responseDto != null) {
          return SharedLink.fromDto(responseDto);
        }
      }
    } catch (e) {
      _log.severe("Failed to create shared link", e);
    }
    return null;
  }

  Future<SharedLink?> updateSharedLink(
    String id, {
    required bool? showMeta,
    required bool? allowDownload,
    required bool? allowUpload,
    Option<String?> password = const Option.none(),
    Option<String?> description = const Option.none(),
    String? slug,
    Option<DateTime?> expiresAt = const Option.none(),
  }) => PluginHooks.run<SharedLink?>(
    DataHooks.sharedLinkUpdate,
    () => {
      'id': id,
      'showMetadata': ?showMeta,
      'allowDownload': ?allowDownload,
      'allowUpload': ?allowUpload,
      if (description case Some(:final value)) 'description': value,
      'slug': ?slug,
      if (expiresAt case Some(:final value)) 'expiresAt': value?.toUtc().toIso8601String(),
    },
    () => _updateSharedLink(
      id,
      showMeta: showMeta,
      allowDownload: allowDownload,
      allowUpload: allowUpload,
      password: password,
      description: description,
      slug: slug,
      expiresAt: expiresAt,
    ),
    encode: (link) => link == null ? null : sharedLinkJson(link),
    event: DataEvents.sharedLinkUpdated,
  );

  Future<SharedLink?> _updateSharedLink(
    String id, {
    required bool? showMeta,
    required bool? allowDownload,
    required bool? allowUpload,
    Option<String?> password = const Option.none(),
    Option<String?> description = const Option.none(),
    String? slug,
    Option<DateTime?> expiresAt = const Option.none(),
  }) async {
    try {
      final responseDto = await _apiService.sharedLinksApi.updateSharedLink(
        id,
        SharedLinkEditDto(
          showMetadata: showMeta == null ? const Optional.absent() : Optional.present(showMeta),
          allowDownload: allowDownload == null ? const Optional.absent() : Optional.present(allowDownload),
          allowUpload: allowUpload == null ? const Optional.absent() : Optional.present(allowUpload),
          password: password.toOptional(),
          description: description.toOptional(),
          expiresAt: expiresAt.toOptional(),
          slug: slug == null ? const Optional.absent() : Optional.present(slug),
        ),
      );
      if (responseDto != null) {
        return SharedLink.fromDto(responseDto);
      }
    } catch (e) {
      _log.severe("Failed to update shared link id - $id", e);
    }
    return null;
  }
}
