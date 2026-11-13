import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/store/person.dart';
import 'package:immich_mobile/domain/utils/plugin_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/data/data_host.dart';

/// People and faces (`people.*`), as synced from the server. Renames and birthdays go to the server and the local
/// database through the same `person.update` hook as the app's own edits.
class PeopleHostApi implements DataHostModule {
  final Drift _db;
  final PersonMutations _mutations;

  const PeopleHostApi(this._db, this._mutations);

  @override
  Map<String, DataHostFunction> get functions => {
    'people.list': (plugin, args) async => [
      for (final person in await _db.peopleDatabaseRepository.watchAll(
        minFaces: HostArgs(args).map(0).integer('minFaces') ?? 1,
      ).first)
        PluginJson.person(person),
    ],
    'people.get': (plugin, args) async {
      final person = await _db.peopleDatabaseRepository.watchPerson(HostArgs(args).text(0, 'id')).first;
      if (person == null) {
        throw const DataHostException.notFound('Person not found');
      }
      return PluginJson.person(person);
    },
    'people.forAsset': (plugin, args) async => [
      for (final person in await _db.peopleDatabaseRepository.watchPeopleForAsset(HostArgs(args).text(0, 'assetId')).first)
        PluginJson.person(person),
    ],
    'people.faces': (plugin, args) => faces(HostArgs(args).text(0, 'assetId')),
    'people.assets': (plugin, args) => assets(HostArgs(args).text(0, 'id')),
    'people.rename': (plugin, args) async => {
      'updated': await _mutations.updateName(HostArgs(args).text(0, 'id'), HostArgs(args).text(1, 'name')),
    },
    'people.setBirthDate': (plugin, args) async {
      final date = DateTime.tryParse(HostArgs(args).text(1, 'birthDate'));
      if (date == null) {
        throw const DataHostException.badRequest('birthDate must be an ISO date');
      }
      return {'updated': await _mutations.updateBirthday(HostArgs(args).text(0, 'id'), date)};
    },
  };

  @override
  Map<String, String> get docs => const {
    'people.list': '[{ minFaces = 1 }] -> [{ id, name, birthDate, updatedAt }]',
    'people.get': '[id] -> Person',
    'people.forAsset': '[assetId] -> [Person]',
    'people.faces': '[assetId] -> [{ id, personId, imageWidth, imageHeight, x1, y1, x2, y2, sourceType }]',
    'people.assets': '[id] -> [assetId]',
    'people.rename': '[id, name] -> { updated }',
    'people.setBirthDate': '[id, isoDate] -> { updated }',
  };

  Future<List<Map<String, dynamic>>> faces(String assetId) async {
    final faces = _db.assetFaceEntity;
    final rows = await (_db.select(faces)
          ..where((row) => row.assetId.equals(assetId) & row.isVisible.equals(true) & row.deletedAt.isNull()))
        .get();
    return [
      for (final face in rows)
        {
          'id': face.id,
          'personId': face.personId,
          'imageWidth': face.imageWidth,
          'imageHeight': face.imageHeight,
          'x1': face.boundingBoxX1,
          'y1': face.boundingBoxY1,
          'x2': face.boundingBoxX2,
          'y2': face.boundingBoxY2,
          'sourceType': face.sourceType,
        },
    ];
  }

  Future<List<String>> assets(String personId) {
    final faces = _db.assetFaceEntity;
    final query = _db.selectOnly(faces, distinct: true)
      ..addColumns([faces.assetId])
      ..where(faces.personId.equals(personId) & faces.isVisible.equals(true) & faces.deletedAt.isNull());
    return query.map((row) => row.read(faces.assetId)!).get();
  }
}
