import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/log_json.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/presentation/widgets/shell/shell_list.widget.dart';

@RoutePage()
class AppLogDetailPage extends HookWidget {
  const AppLogDetailPage({super.key, required this.logMessage});

  final LogMessage logMessage;

  @override
  Widget build(BuildContext context) {
    Padding buildTextWithCopyButton(String header, String text) {
      return Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    header,
                    style: TextStyle(fontSize: 12.0, color: context.primaryColor, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    unawaited(
                      Clipboard.setData(ClipboardData(text: text)).then((_) {
                        if (!context.mounted) {
                          return;
                        }

                        context.scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              context.t.copied_to_clipboard,
                              style: context.textTheme.bodyLarge?.copyWith(color: context.primaryColor),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                  icon: Icon(Icons.copy, size: 16.0, color: context.primaryColor),
                ),
              ],
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.all(Radius.circular(15.0)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontSize: 12.0, fontWeight: FontWeight.bold, fontFamily: "GoogleSansCode"),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Padding buildLogContext(String logger) {
      return Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                "FROM",
                style: TextStyle(fontSize: 12.0, color: context.primaryColor, fontWeight: FontWeight.bold),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.all(Radius.circular(15.0)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SelectableText(
                  logger,
                  style: const TextStyle(fontSize: 12.0, fontWeight: FontWeight.bold, fontFamily: "GoogleSansCode"),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t.log_detail_title)),
      body: SafeArea(
        child: ShellList(
          slot: ShellSlots.appLogDetailSections,
          slotContext: {'log': logMessageToJson(logMessage)},
          items: [
            ShellItem(AppLogIds.message, buildTextWithCopyButton("MESSAGE", logMessage.message)),
            if (logMessage.error != null)
              ShellItem(AppLogIds.details, buildTextWithCopyButton("DETAILS", logMessage.error.toString())),
            if (logMessage.logger != null) ShellItem(AppLogIds.logger, buildLogContext(logMessage.logger.toString())),
            if (logMessage.stack != null)
              ShellItem(AppLogIds.stack, buildTextWithCopyButton("STACK TRACE", logMessage.stack.toString())),
          ],
          builder: (context, children) => ListView(children: children),
        ),
      ),
    );
  }
}
