import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/utils/plugin_data_ids.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/repositories/partner.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/user.repository.dart';
import 'package:immich_mobile/repositories/partner_api.repository.dart';
import 'package:stream_transform/stream_transform.dart';

class PartnerService {
  final UserRepository _userRepository;
  final PartnerRepository _partnerRepository;
  final PartnerApiRepository _partnerApiRepository;

  const PartnerService(this._userRepository, this._partnerRepository, this._partnerApiRepository);

  Stream<Iterable<User>> getCandidates(String userId) {
    final userStream = _userRepository.getAll();
    final partnerStream = _partnerRepository.search(userId, .sharedBy);

    return userStream.combineLatest(partnerStream, (users, partners) {
      final partnersSet = partners.map((partner) => partner.id).toSet();
      return users.where((user) => user.id != userId && !partnersSet.contains(user.id));
    });
  }

  /// Partners as the UI shows them; plugins can filter or sort them through `partner.query`.
  Stream<Iterable<Partner>> search(String userId, PartnerDirection direction) => PluginHooks.filterListStream<Partner>(
    _partnerRepository.search(userId, direction).map((partners) => partners.toList()),
    DataHooks.partnerQuery,
    () => {'userId': userId, 'direction': direction.name},
    () => PluginListCodec<Partner>(id: (partner) => partner.id, toJson: _partnerJson),
  );

  static Map<String, dynamic> _partnerJson(Partner partner) => {
    'id': partner.id,
    'name': partner.name,
    'email': partner.email,
    'inTimeline': partner.inTimeline,
    'hasProfileImage': partner.hasProfileImage,
    'profileChangedAt': PluginJson.iso(partner.profileChangedAt),
  };

  Future<void> update({required String sharedById, required String sharedWithId, required bool inTimeline}) =>
      PluginHooks.run<void>(
        DataHooks.partnerUpdate,
        () => {'sharedById': sharedById, 'sharedWithId': sharedWithId, 'inTimeline': inTimeline},
        () => _update(sharedById: sharedById, sharedWithId: sharedWithId, inTimeline: inTimeline),
        withArgs: (args) => _update(
          sharedById: sharedById,
          sharedWithId: sharedWithId,
          inTimeline: PluginArgs.boolean(args['inTimeline']) ?? inTimeline,
        ),
        event: DataEvents.partnerUpdated,
      );

  Future<void> _update({required String sharedById, required String sharedWithId, required bool inTimeline}) async {
    await _partnerApiRepository.update(sharedById, inTimeline: inTimeline);
    await _partnerRepository.updatePartner(sharedById: sharedById, sharedWithId: sharedWithId, inTimeline: inTimeline);
  }

  Future<void> create({required String sharedById, required String sharedWithId, bool inTimeline = false}) =>
      PluginHooks.run<void>(
        DataHooks.partnerAdd,
        () => {'sharedById': sharedById, 'sharedWithId': sharedWithId, 'inTimeline': inTimeline},
        () => _create(sharedById: sharedById, sharedWithId: sharedWithId, inTimeline: inTimeline),
        event: DataEvents.partnerAdded,
      );

  Future<void> _create({required String sharedById, required String sharedWithId, bool inTimeline = false}) async {
    await _partnerApiRepository.create(sharedWithId);
    await _partnerRepository.create(sharedById: sharedById, sharedWithId: sharedWithId, inTimeline: inTimeline);
  }

  Future<void> delete({required String sharedById, required String sharedWithId}) => PluginHooks.run<void>(
    DataHooks.partnerRemove,
    () => {'sharedById': sharedById, 'sharedWithId': sharedWithId},
    () => _delete(sharedById: sharedById, sharedWithId: sharedWithId),
    event: DataEvents.partnerRemoved,
  );

  Future<void> _delete({required String sharedById, required String sharedWithId}) async {
    await _partnerApiRepository.delete(sharedWithId);
    await _partnerRepository.deletePartner(sharedById: sharedById, sharedWithId: sharedWithId);
  }
}
