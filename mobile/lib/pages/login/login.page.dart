import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/presentation/widgets/shell/shell_list.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:package_info_plus/package_info_plus.dart';

@RoutePage()
class LoginPage extends HookWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appVersion = useState('0.0.0');

    Future<void> getAppInfo() async {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      appVersion.value = packageInfo.version;
    }

    useEffect(() {
      unawaited(getAppInfo());
      return null;
    });

    return Scaffold(
      body: LoginForm(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ShellList(
                  slot: ShellSlots.loginFooter,
                  builder: (context, items) => Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final (index, item) in items.indexed) ...[if (index > 0) const Text(' '), item],
                    ],
                  ),
                  items: [
                    ShellItem(
                      LoginIds.version,
                      Text(
                        'v${appVersion.value}',
                        style: TextStyle(
                          color: context.colorScheme.onSurfaceSecondary,
                          fontWeight: FontWeight.bold,
                          fontFamily: "GoogleSansCode",
                        ),
                      ),
                    ),
                    ShellItem(
                      LoginIds.logs,
                      GestureDetector(
                        child: Text(
                          'Logs',
                          style: TextStyle(
                            color: context.primaryColor,
                            fontWeight: FontWeight.bold,
                            fontFamily: "GoogleSansCode",
                          ),
                        ),
                        onTap: () {
                          unawaited(context.pushRoute(const AppLogRoute()));
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
