import 'dart:async';

import 'package:flutter/foundation.dart';

enum PluginTaskState { running, done, failed, cancelled }

/// A long running job shown with app-native progress (in-app indicator, Plugins page; a notification once the native
/// area adds it). Started by a plugin with `tasks.start` or by app code with [PluginTasks.start].
class PluginTask {
  final String id;

  /// Plugin name, or `app` for built-in tasks.
  final String owner;
  String title;
  String? message;

  /// 0..1, or null while indeterminate.
  double? progress;
  final bool cancellable;
  PluginTaskState state = PluginTaskState.running;
  String? error;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  /// Called when the task is cancelled (app tasks; plugins get the `task.cancelled` event).
  final void Function()? onCancel;
  final _done = Completer<PluginTaskState>();

  PluginTask._({
    required this.id,
    required this.owner,
    required this.title,
    required this.cancellable,
    this.message,
    this.progress,
    this.onCancel,
  });

  bool get isRunning => state == PluginTaskState.running;

  bool get isCancelled => state == PluginTaskState.cancelled;

  /// Completes when the task finishes, fails or is cancelled.
  Future<PluginTaskState> get done => _done.future;

  Map<String, dynamic> toJson() => {
    'id': id,
    'plugin': owner,
    'title': title,
    if (message != null) 'message': message,
    'progress': progress,
    'cancellable': cancellable,
    'state': state.name,
    'cancelled': isCancelled,
    if (error != null) 'error': error,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toUtc().toIso8601String(),
  };
}

/// The task registry behind `tasks.*` host functions and the progress UI.
///
/// Cancelling a task (from the UI or `tasks.cancel`) marks it cancelled, calls its `onCancel` (app tasks) and emits
/// `task.cancelled` with `{ "id", "plugin", "title" }`; later `tasks.update` / `tasks.finish` calls for it are
/// ignored and `tasks.get` reports `"cancelled": true`.
class PluginTasks extends ChangeNotifier {
  static const _keepFinished = 30;

  final Map<String, PluginTask> _tasks = {};
  var _counter = 0;
  Timer? _notifyTimer;
  final Map<String, Timer> _lingerTimers = {};

  /// Emits `task.*` events; set by the kernel.
  void Function(String event, Map<String, dynamic> data)? emit;

  /// Running tasks, oldest first.
  List<PluginTask> get running => [
    for (final task in _tasks.values)
      if (task.isRunning) task,
  ];

  /// Running tasks plus tasks that finished in the last few seconds (what the in-app indicator shows).
  List<PluginTask> get visible => [
    for (final task in _tasks.values)
      if (task.isRunning || _lingerTimers.containsKey(task.id)) task,
  ];

  /// Every known task, newest first (running and the last finished ones).
  List<PluginTask> get all => _tasks.values.toList().reversed.toList();

  PluginTask? operator [](String id) => _tasks[id];

  PluginTask start(
    String owner,
    String title, {
    bool cancellable = false,
    double? progress,
    String? message,
    void Function()? onCancel,
  }) {
    final id = '${owner.replaceAll('/', '_')}-${DateTime.now().millisecondsSinceEpoch}-${_counter++}';
    final task = PluginTask._(
      id: id,
      owner: owner,
      title: title,
      cancellable: cancellable,
      progress: progress?.clamp(0.0, 1.0),
      message: message,
      onCancel: onCancel,
    );
    _tasks[id] = task;
    _trim();
    notifyListeners();
    emit?.call('task.started', task.toJson());
    return task;
  }

  /// Updates a running task. [clearProgress] switches back to indeterminate.
  bool update(String id, {double? progress, String? message, String? title, bool clearProgress = false}) {
    final task = _tasks[id];
    if (task == null || !task.isRunning) {
      return false;
    }
    if (clearProgress) {
      task.progress = null;
    } else if (progress != null) {
      task.progress = progress.clamp(0.0, 1.0);
    }
    if (message != null) {
      task.message = message;
    }
    if (title != null) {
      task.title = title;
    }
    _notifySoon();
    return true;
  }

  bool finish(String id, {String? message, String? error}) {
    final task = _tasks[id];
    if (task == null || !task.isRunning) {
      return false;
    }
    task
      ..state = error == null ? PluginTaskState.done : PluginTaskState.failed
      ..error = error
      ..message = message ?? task.message
      ..progress = error == null ? 1 : task.progress
      ..finishedAt = DateTime.now();
    _complete(task);
    emit?.call(error == null ? 'task.finished' : 'task.failed', task.toJson());
    return true;
  }

  /// Cancels a cancellable running task. Returns whether it was cancelled.
  bool cancel(String id) {
    final task = _tasks[id];
    if (task == null || !task.isRunning || !task.cancellable) {
      return false;
    }
    task
      ..state = PluginTaskState.cancelled
      ..finishedAt = DateTime.now();
    try {
      task.onCancel?.call();
    } catch (_) {
      // a failing cancel callback must not keep the task alive
    }
    _complete(task);
    emit?.call('task.cancelled', {'id': task.id, 'plugin': task.owner, 'title': task.title});
    return true;
  }

  /// Removes finished tasks from the list.
  void clearFinished() {
    _tasks.removeWhere((_, task) => !task.isRunning);
    notifyListeners();
  }

  /// Fails every running task of [owner] (the plugin was disabled or uninstalled).
  void abandon(String owner) {
    for (final task in running.where((task) => task.owner == owner)) {
      finish(task.id, error: 'Plugin unloaded');
    }
  }

  void _complete(PluginTask task) {
    if (!task._done.isCompleted) {
      task._done.complete(task.state);
    }
    _lingerTimers[task.id]?.cancel();
    _lingerTimers[task.id] = Timer(const Duration(seconds: 4), () {
      _lingerTimers.remove(task.id);
      notifyListeners();
    });
    _trim();
    notifyListeners();
  }

  void _trim() {
    final finished = _tasks.values.where((task) => !task.isRunning).toList();
    for (final task in finished.take(finished.length > _keepFinished ? finished.length - _keepFinished : 0)) {
      _tasks.remove(task.id);
    }
  }

  void _notifySoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    for (final timer in _lingerTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
