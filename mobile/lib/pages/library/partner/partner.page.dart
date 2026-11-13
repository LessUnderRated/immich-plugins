import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_json.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/partner.action.dart';
import 'package:immich_mobile/presentation/widgets/library/library_plugins.widget.dart';
import 'package:immich_mobile/presentation/widgets/people/partner_user_avatar.widget.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

@visibleForTesting
final partnersStateProvider = StreamProvider.autoDispose<Iterable<Partner>>((ref) {
  final currentUser = ref.watch(currentUserProvider);
  // TODO: Refactor with a route guard to avoid this check in every provider
  if (currentUser == null) {
    return const Stream.empty();
  }

  return ref.watch(partnerServiceProvider).search(currentUser.id, .sharedBy);
});

@RoutePage()
class PartnerPage extends ConsumerWidget {
  const PartnerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sharedByAsync = ref.watch(partnersStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.partners),
        elevation: 0,
        centerTitle: false,
        actions: LibraryPluginHooks.arrange(LibrarySlots.appBarActions(LibraryPages.partner), const [
          (id: 'add', item: ActionIconButton(action: PartnerAddAction())),
        ]),
      ),
      body: sharedByAsync.when(
        data: (partners) => PartnerSharedByList(partners: partners.toList(growable: false)),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(context.t.error_loading_partners(error: error))),
      ),
    );
  }
}

class _EmptyPartners extends StatelessWidget {
  const _EmptyPartners();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const .symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: .start,
        children: LibraryPluginHooks.arrange(LibrarySlots.empty(LibraryPages.partner), [
          (
            id: 'message',
            item: Padding(
              padding: const .symmetric(vertical: 8),
              child: Text(context.t.partner_page_empty_message, style: const TextStyle(fontSize: 14)),
            ),
          ),
          (
            id: 'add',
            item: const Align(
              alignment: .center,
              child: ActionButton(action: PartnerAddAction()),
            ),
          ),
        ]),
      ),
    );
  }
}

@visibleForTesting
class PartnerSharedByList extends StatelessWidget {
  const PartnerSharedByList({super.key, required this.partners});

  final List<Partner> partners;

  @override
  Widget build(BuildContext context) {
    if (partners.isEmpty) {
      return const _EmptyPartners();
    }

    return LibraryQueryBuilder<Partner>(
      hook: LibraryHooks.partnersQuery,
      items: partners,
      id: (partner) => partner.id,
      toJson: LibraryJson.partner,
      args: () => {'direction': 'sharedBy'},
      builder: (context, partners) => ListView.builder(
        itemCount: partners.length,
        itemBuilder: (_, index) {
          final partner = partners[index];
          final actions = LibraryPluginHooks.arrange(LibrarySlots.partnerTileActions, [
            (
              id: 'remove',
              item: ActionIconButton(
                action: PartnerRemoveAction(sharedWithId: partner.id, partnerName: partner.name),
              ),
            ),
          ]);
          return ListTile(
            leading: PartnerUserAvatar(userId: partner.id, name: partner.name),
            title: Text(partner.name),
            subtitle: Text(partner.email),
            trailing: actions.length == 1 ? actions.first : Row(mainAxisSize: MainAxisSize.min, children: actions),
          );
        },
      ),
    );
  }
}
