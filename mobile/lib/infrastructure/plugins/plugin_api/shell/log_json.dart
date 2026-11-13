import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/utils/plugin_hooks.dart';
import 'package:logging/logging.dart';

/// `LogV1`: one app log entry as plugins see it.
/// `{ "id"?, "level", "message", "logger"?, "error"?, "stack"?, "createdAt" }`; `createdAt` is ISO 8601 UTC.
Map<String, dynamic> logMessageToJson(LogMessage message) => {
  'level': message.level.name,
  'message': message.message,
  if (message.logger != null) 'logger': message.logger,
  if (message.error != null) 'error': message.error,
  if (message.stack != null) 'stack': message.stack,
  'createdAt': message.createdAt.toUtc().toIso8601String(),
};

/// Builds a log entry from `LogV1` JSON (a plugin adding entries to the log list), or null without a message.
LogMessage? logMessageFromJson(Map<String, dynamic> json) {
  final message = json['message'];
  if (message is! String) {
    return null;
  }
  return LogMessage(
    message: message,
    level: parseLogLevel(json['level']) ?? LogLevel.info,
    createdAt: PluginArgs.date(json['createdAt'])?.toLocal() ?? DateTime.now(),
    logger: PluginArgs.string(json['logger']),
    error: PluginArgs.string(json['error']),
    stack: PluginArgs.string(json['stack']),
  );
}

/// `finest` ... `shout` (case-insensitive), as in [LogLevel].
LogLevel? parseLogLevel(Object? value) {
  if (value is! String) {
    return null;
  }
  final name = value.toLowerCase();
  for (final level in LogLevel.values) {
    if (level.name == name) {
      return level;
    }
  }
  return switch (name) {
    'debug' || 'verbose' => LogLevel.fine,
    'warn' => LogLevel.warning,
    'error' => LogLevel.severe,
    _ => null,
  };
}

/// The `package:logging` level of [level].
Level loggingLevelOf(LogLevel level) => switch (level) {
  LogLevel.all => Level.ALL,
  LogLevel.finest => Level.FINEST,
  LogLevel.finer => Level.FINER,
  LogLevel.fine => Level.FINE,
  LogLevel.config => Level.CONFIG,
  LogLevel.info => Level.INFO,
  LogLevel.warning => Level.WARNING,
  LogLevel.severe => Level.SEVERE,
  LogLevel.shout => Level.SHOUT,
  LogLevel.off => Level.OFF,
};

/// Maps the log list through `after` handlers of the `logs.query` hook (filter, sort, add entries).
PluginListCodec<LogMessage> logListCodec() => PluginListCodec<LogMessage>(
  id: (message) => '${identityHashCode(message)}',
  toJson: (message) => {'id': '${identityHashCode(message)}', ...logMessageToJson(message)},
  fromJson: logMessageFromJson,
);
