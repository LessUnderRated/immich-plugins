import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/infrastructure/repositories/private_album.repository.dart';
import 'package:local_auth/local_auth.dart';
import 'package:photo_manager/photo_manager.dart';

const _channel = MethodChannel('immich/picker');
const _pageSize = 120;

Future<void> runPicker() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _PickerApp());
}

class _PickerApp extends StatelessWidget {
  const _PickerApp();

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4250AF);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const _PickerSheet(),
    );
  }
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet();

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final Map<String, Future<Uint8List?>> _thumbs = {};
  final Map<String, AssetEntity> _selected = {};
  final List<AssetEntity> _photos = [];
  List<AssetEntity> _private = const [];

  RequestType _type = RequestType.common;
  bool _multiple = false;
  bool _privateTab = false;
  bool _privateUnlocked = false;
  bool _loading = false;
  bool _hasMore = true;
  int _page = 0;
  AssetPathEntity? _all;
  Set<String> _privateIds = const {};
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final request = await _channel.invokeMapMethod<String, Object?>('getRequest') ?? const {};
    final mime = request['mimeType'] as String? ?? '*/*';
    _multiple = request['multiple'] == true;
    _type = mime.startsWith('image')
        ? RequestType.image
        : mime.startsWith('video')
        ? RequestType.video
        : RequestType.common;

    _privateIds = await PrivateAlbumRepository().ids();
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      setState(() => _message = 'Allow photo access for Immich Gallery to pick photos.');
      return;
    }
    final paths = await PhotoManager.getAssetPathList(type: _type, onlyAll: true);
    _all = paths.firstOrNull;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final all = _all;
    if (all == null || _loading || !_hasMore) {
      return;
    }
    _loading = true;
    final page = await all.getAssetListPaged(page: _page, size: _pageSize);
    _page++;
    if (!mounted) {
      return;
    }
    setState(() {
      _hasMore = page.length == _pageSize;
      _photos.addAll(page.where((asset) => !_privateIds.contains(asset.id)));
      _loading = false;
    });
  }

  Future<void> _unlockPrivate() async {
    try {
      final auth = LocalAuthentication();
      if (await auth.isDeviceSupported() &&
          !await auth.authenticate(
            localizedReason: 'Show your private photos',
            options: const AuthenticationOptions(stickyAuth: true),
          )) {
        return;
      }
      final entities = <AssetEntity>[];
      for (final id in _privateIds) {
        final entity = await AssetEntity.fromId(id);
        if (entity != null && _matchesType(entity)) {
          entities.add(entity);
        }
      }
      entities.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      if (mounted) {
        setState(() {
          _private = entities;
          _privateUnlocked = true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = 'Unable to unlock: $error');
      }
    }
  }

  bool _matchesType(AssetEntity entity) => switch (_type) {
    RequestType.image => entity.type == AssetType.image,
    RequestType.video => entity.type == AssetType.video,
    _ => entity.type == AssetType.image || entity.type == AssetType.video,
  };

  Future<void> _cancel() => _channel.invokeMethod('cancel');

  Future<void> _finish(List<AssetEntity> assets) => _channel.invokeMethod('finish', {
    'items': [
      for (final asset in assets) {'id': asset.id, 'video': asset.type == AssetType.video},
    ],
  });

  void _onTap(AssetEntity asset) {
    if (!_multiple) {
      unawaited(_finish([asset]));
      return;
    }
    setState(() {
      _selected.containsKey(asset.id) ? _selected.remove(asset.id) : _selected[asset.id] = asset;
    });
  }

  Future<Uint8List?> _thumb(AssetEntity asset) =>
      _thumbs.putIfAbsent(asset.id, () => asset.thumbnailDataWithSize(const ThumbnailSize.square(240), quality: 80));

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_cancel());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => unawaited(_cancel())),
            ),
            Container(
              height: height * 0.5,
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          SegmentedButton<bool>(
                            showSelectedIcon: false,
                            style: SegmentedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            segments: const [
                              ButtonSegment(
                                value: false,
                                icon: Icon(Icons.photo_library_outlined),
                                label: Text('Photos'),
                              ),
                              ButtonSegment(value: true, icon: Icon(Icons.lock_outline), label: Text('Private')),
                            ],
                            selected: {_privateTab},
                            onSelectionChanged: (selection) => setState(() => _privateTab = selection.first),
                          ),
                          const Spacer(),
                          if (_multiple)
                            FilledButton(
                              onPressed: _selected.isEmpty ? null : () => _finish(_selected.values.toList()),
                              child: Text(_selected.isEmpty ? 'Add' : 'Add (${_selected.length})'),
                            )
                          else
                            IconButton(icon: const Icon(Icons.close), onPressed: () => unawaited(_cancel())),
                        ],
                      ),
                    ),
                    Expanded(child: _content()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final message = _message;
    if (message != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
    }
    if (_privateTab && !_privateUnlocked) {
      return Center(
        child: FilledButton.tonalIcon(
          icon: const Icon(Icons.fingerprint),
          label: const Text('Unlock private photos'),
          onPressed: _unlockPrivate,
        ),
      );
    }

    final assets = _privateTab ? _private : _photos;
    if (assets.isEmpty) {
      return Center(child: _loading ? const CircularProgressIndicator() : const Text('Nothing here'));
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (!_privateTab && notification.metrics.extentAfter < 600) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: assets.length,
        itemBuilder: (context, index) {
          final asset = assets[index];
          return _PickerTile(
            asset: asset,
            thumbnail: _thumb(asset),
            selected: _selected.containsKey(asset.id),
            onTap: () => _onTap(asset),
          );
        },
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  final AssetEntity asset;
  final Future<Uint8List?> thumbnail;
  final bool selected;
  final VoidCallback onTap;

  const _PickerTile({required this.asset, required this.thumbnail, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: thumbnail,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              return bytes == null
                  ? ColoredBox(color: scheme.surfaceContainerHighest)
                  : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
          if (asset.type == AssetType.video)
            Positioned(
              right: 4,
              bottom: 4,
              child: Text(
                _duration(asset.videoDuration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ),
          if (selected) ...[
            ColoredBox(color: scheme.primary.withValues(alpha: 0.25)),
            Positioned(top: 4, right: 4, child: Icon(Icons.check_circle, color: scheme.primary)),
          ],
        ],
      ),
    );
  }

  static String _duration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
