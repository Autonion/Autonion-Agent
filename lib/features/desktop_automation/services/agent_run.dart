import 'dart:async';

class AgentCancelledException implements Exception {
  @override
  String toString() => 'Automation cancelled.';
}

/// Cancellation belongs to a run, so a subsequent request cannot reset it.
class AgentRun {
  final String id;
  final String owner;
  final _cancelled = Completer<void>();
  AgentRun(this.id, this.owner);

  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw AgentCancelledException();
  }

  /// Discards a late result while retaining an error listener on the work.
  Future<T> wait<T>(Future<T> work) =>
      Future.any([
        work,
        _cancelled.future.then<T>((_) => throw AgentCancelledException()),
      ]).then((value) {
        check();
        return value;
      });
}
