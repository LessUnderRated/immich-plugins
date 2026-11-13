import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';

/// Plugin API of the **viewer** area (viewer, video, images, memories, slideshow: viewer bars and menus, info sections, overlays, gestures, image pipeline hooks (`image.full`, `image.preview`, `image.thumbnail`), video sessions, `image.load`, the censor shield toggle).
///
/// Called once when the kernel is created (`registerAllPluginApis`). Register host functions with
/// `kernel.registerHost`, declare slots / hooks / events for `kernel.slots` / `kernel.hooks` / `kernel.events`, add
/// legacy slot aliases with `kernel.aliasSlot` and app toggles with `kernel.toggles.define`. Keep it cheap: no I/O here.
void registerViewerPluginApi(PluginKernel kernel, Ref ref) {}
