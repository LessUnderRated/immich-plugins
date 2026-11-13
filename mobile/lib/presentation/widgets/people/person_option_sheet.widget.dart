import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';

class PersonOptionSheet extends StatelessWidget {
  const PersonOptionSheet({super.key, this.onEditName, this.onEditBirthday, this.birthdayExists = false});

  final VoidCallback? onEditName;
  final VoidCallback? onEditBirthday;
  final bool birthdayExists;

  @override
  Widget build(BuildContext context) {
    final TextStyle textStyle = Theme.of(context).textTheme.bodyLarge!.copyWith(fontWeight: FontWeight.w600);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24.0),
        child: ListView(
          shrinkWrap: true,
          children: LibraryPluginHooks.arrange(LibrarySlots.personOptions, [
            (
              id: 'editName',
              item: ListTile(
                leading: const Icon(Icons.edit),
                title: Text(context.t.edit_name, style: textStyle),
                onTap: onEditName,
              ),
            ),
            (
              id: 'editBirthday',
              item: ListTile(
                leading: const Icon(Icons.cake),
                title: Text(birthdayExists ? context.t.edit_birthday : context.t.add_birthday, style: textStyle),
                onTap: onEditBirthday,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
