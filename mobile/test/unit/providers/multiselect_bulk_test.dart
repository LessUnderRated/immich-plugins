import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

import '../../fixtures/asset.stub.dart';

void main() {
  test('replaceSelection swaps a drag range in one state update', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(multiSelectProvider.notifier);
    var updates = 0;
    container.listen(multiSelectProvider, (_, _) => updates++);

    notifier.replaceSelection(remove: const [], add: [LocalAssetStub.image1, LocalAssetStub.image2]);
    expect(container.read(multiSelectProvider).selectedAssets, {LocalAssetStub.image1, LocalAssetStub.image2});

    notifier.replaceSelection(remove: [LocalAssetStub.image1, LocalAssetStub.image2], add: [LocalAssetStub.image2]);
    expect(container.read(multiSelectProvider).selectedAssets, {LocalAssetStub.image2});
    expect(updates, 2);
  });
}
