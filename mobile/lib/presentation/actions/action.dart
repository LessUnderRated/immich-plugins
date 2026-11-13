import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/actions/action_hooks.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/utils/asset_filter.dart';

class ActionItem {
  final IconData icon;
  final String label;
  final FutureOr<void> Function() onAction;
  final FutureOr<void> Function()? onSecondaryAction;

  /// Stable id of the action (`ActionIds`, or `plugin:<plugin>/<id>` for plugin items). Set by
  /// [ActionBuilder.resolve]; null for items that are not part of any plugin-visible list.
  final String? id;

  const ActionItem({required this.icon, required this.label, required this.onAction, this.onSecondaryAction, this.id});

  ActionItem copyWith({
    IconData? icon,
    String? label,
    FutureOr<void> Function()? onAction,
    FutureOr<void> Function()? onSecondaryAction,
    String? id,
  }) => ActionItem(
    icon: icon ?? this.icon,
    label: label ?? this.label,
    onAction: onAction ?? this.onAction,
    onSecondaryAction: onSecondaryAction ?? this.onSecondaryAction,
    id: id ?? this.id,
  );
}

abstract class ActionBuilder {
  const ActionBuilder();

  /// Stable id of the action (see `ActionIds`): the key plugins use to hide, reorder or rename it in any bar or menu,
  /// and its hook `action.<id>`. Null for actions plugins cannot address.
  String? get id => null;

  // null when the action is not applicable for the current context
  ActionItem? create(BuildContext context, WidgetRef ref);

  /// The assets the action runs on, for its hook arguments. Read when the action runs.
  List<BaseAsset> hookAssets(WidgetRef ref) => const [];

  /// Action-specific hook arguments (`albumId`, `tagId`, ...).
  Map<String, dynamic> get hookArgs => const {};

  /// [create] as every bar and menu should use it: the item carries [id] and its [ActionItem.onAction] runs through
  /// the `action.<id>` hook (free when no plugin hooks it).
  ActionItem? resolve(BuildContext context, WidgetRef ref) {
    final item = create(context, ref);
    final id = this.id;
    if (item == null || id == null) {
      return item;
    }
    return item.copyWith(
      id: id,
      onAction: ActionHooks.wrap(
        id,
        item.onAction,
        () => ActionHookCall(actionId: id, source: hookSource, assets: hookAssets(ref), args: hookArgs),
      ),
    );
  }

  /// Where the action runs, for its hook arguments.
  ActionSource? get hookSource => null;
}

final assetsActionProvider = Provider.family.autoDispose<AssetFilter<BaseAsset>, ActionSource>(
  (ref, source) => AssetFilter(switch (source) {
    .timeline => ref.watch(multiSelectProvider.select((s) => s.selectedAssets)),
    .viewer => switch (ref.watch(assetViewerProvider.select((s) => s.currentAsset))) {
      final BaseAsset asset => {asset},
      null => const <BaseAsset>{},
    },
  }),
  dependencies: [multiSelectProvider],
);

final clearSelectionProvider = Provider.family.autoDispose<VoidCallback, ActionSource>((ref, source) {
  if (source == .timeline) {
    return ref.read(multiSelectProvider.notifier).reset;
  }

  return () {};
}, dependencies: [multiSelectProvider]);

final ownedAssetsActionProvider = Provider.family.autoDispose<AssetFilter<RemoteAsset>, ActionSource>(
  (ref, source) => ref.watch(assetsActionProvider(source)).owned(ref.watch(authUserProvider).id),
  dependencies: [assetsActionProvider],
);

abstract class AssetActionBuilder extends ActionBuilder {
  final ActionSource source;

  const AssetActionBuilder({required this.source});

  @override
  ActionSource get hookSource => source;

  @override
  List<BaseAsset> hookAssets(WidgetRef ref) => ref.read(assetsActionProvider(source)).toList(growable: false);
}
