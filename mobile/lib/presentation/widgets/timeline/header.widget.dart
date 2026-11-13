import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/timeline_plugin.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/timeline/timeline_plugin_ids.dart';
import 'package:immich_mobile/presentation/widgets/timeline/plugins/timeline_slots.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/timeline/timeline_plugins.provider.dart';

class TimelineHeader extends HookConsumerWidget {
  final Bucket bucket;
  final HeaderType header;
  final double height;
  final int assetOffset;

  const TimelineHeader({
    super.key,
    required this.bucket,
    required this.header,
    required this.height,
    required this.assetOffset,
  });

  String _formatMonth(DateTime date) {
    final formatter = date.year == DateTime.now().year
        ? DateFormat.MMMM(resolvedDateTimeLocale())
        : DateFormat.yMMMM(resolvedDateTimeLocale());
    return formatter.format(date);
  }

  String _formatDay(DateTime date) {
    final formatter = DateFormat.yMMMEd(resolvedDateTimeLocale());
    return formatter.format(date);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bucket = this.bucket;
    if (bucket is! TimeBucket || header == HeaderType.none) {
      return const SizedBox.shrink();
    }

    final bridge = ref.watch(timelinePluginBridgeProvider);
    final rules = bridge.rules(const [TimelineSlots.groupHeader]);
    final showTitle = !rules.isHidden(TimelineItemIds.groupTitle);
    final showSelect = !rules.isHidden(TimelineItemIds.selectGroup);
    final Widget content = bucket is PluginGroupBucket
        ? _buildPluginGroup(context, bucket, showTitle: showTitle, showSelect: showSelect)
        : _buildDateGroup(context, bucket.date, showTitle: showTitle, showSelect: showSelect);

    if (!bridge.hasDecorations(TimelineSlots.groupHeader)) {
      return content;
    }
    return bridge.decorate(TimelineSlots.groupHeader, {
      'page': TimelinePageScope.of(context),
      'origin': ref.read(timelineServiceProvider).origin.name,
      'header': header.name,
      'group': {
        'firstIndex': assetOffset,
        'count': bucket.assetCount,
        'date': bucket.date.toUtc().toIso8601String(),
        if (bucket is PluginGroupBucket) ...bucket.toJson(),
      },
    }, content);
  }

  Widget _buildDateGroup(BuildContext context, DateTime date, {required bool showTitle, required bool showSelect}) {
    final isMonthHeader = header == HeaderType.month || header == HeaderType.monthAndDay;
    final isDayHeader = header == HeaderType.day || header == HeaderType.monthAndDay;

    return Padding(
      padding: EdgeInsets.only(top: isMonthHeader ? 8.0 : 0.0, left: 12.0, right: 12.0),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (isMonthHeader)
              Row(
                children: [
                  if (showTitle)
                    Text(
                      toBeginningOfSentenceCase(_formatMonth(date)),
                      style: context.textTheme.labelLarge?.copyWith(fontSize: 24),
                    ),
                  const Spacer(),
                  if (header != HeaderType.monthAndDay && showSelect)
                    _BulkSelectIconButton(bucket: bucket, assetOffset: assetOffset),
                ],
              ),
            if (isDayHeader)
              Row(
                children: [
                  if (showTitle)
                    Text(
                      toBeginningOfSentenceCase(_formatDay(date)),
                      style: context.textTheme.labelLarge?.copyWith(fontSize: 15),
                    ),
                  const Spacer(),
                  if (showSelect) _BulkSelectIconButton(bucket: bucket, assetOffset: assetOffset),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// A group a `timeline.query` plugin made: its title (large or small) and subtitle.
  Widget _buildPluginGroup(
    BuildContext context,
    PluginGroupBucket group, {
    required bool showTitle,
    required bool showSelect,
  }) {
    final title = group.title;
    final subtitle = group.subtitle;
    return Padding(
      padding: EdgeInsets.only(top: group.large ? 8.0 : 0.0, left: 12.0, right: 12.0),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (showTitle && title != null)
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.labelLarge?.copyWith(fontSize: group.large ? 24 : 15),
                    ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceSecondary),
                    ),
                ],
              ),
            ),
            if (showSelect) _BulkSelectIconButton(bucket: group, assetOffset: assetOffset),
          ],
        ),
      ),
    );
  }
}

class _BulkSelectIconButton extends ConsumerWidget {
  final Bucket bucket;
  final int assetOffset;

  const _BulkSelectIconButton({required this.bucket, required this.assetOffset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    List<BaseAsset> bucketAssets;
    try {
      bucketAssets = ref.watch(timelineServiceProvider).getAssets(assetOffset, bucket.assetCount);
    } catch (e) {
      bucketAssets = <BaseAsset>[];
    }

    final isReadonlyModeEnabled = ref.watch(readonlyModeProvider);
    final isAllSelected = ref.watch(
      multiSelectProvider.select(
        (state) => bucketAssets.isNotEmpty && bucketAssets.every(state.selectedAssets.contains),
      ),
    );

    return isReadonlyModeEnabled
        ? const SizedBox.shrink()
        : IconButton(
            onPressed: () {
              unawaited(ref.read(multiSelectProvider.notifier).toggleBucketSelection(assetOffset, bucket.assetCount));
              ref.read(hapticFeedbackProvider.notifier).heavyImpact();
            },
            icon: isAllSelected
                ? Icon(Icons.check_circle_rounded, size: 26, color: context.primaryColor)
                : Icon(Icons.check_circle_outline_rounded, size: 26, color: context.colorScheme.onSurfaceSecondary),
          );
  }
}
