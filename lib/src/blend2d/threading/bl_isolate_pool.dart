import 'dart:async';

/// Bootstrap de pool para futura paralelizacao do port Blend2D.
///
/// Nesta etapa, o pool executa tarefas localmente para manter API estavel sem
/// custo extra de serializacao. A troca para isolates reais sera incremental.
class BLIsolatePool {
  final int workerCount;
  bool _started = false;
  bool _disposed = false;

  BLIsolatePool({required this.workerCount})
      : assert(workerCount > 0, 'workerCount must be > 0');

  Future<void> start() async {
    if (_disposed) {
      throw StateError('BLIsolatePool is disposed');
    }
    _started = true;
  }

  bool get isStarted => _started;
  bool get isDisposed => _disposed;

  Future<T> run<T>(FutureOr<T> Function() job) async {
    if (_disposed) {
      throw StateError('BLIsolatePool is disposed');
    }
    if (!_started) {
      await start();
    }
    return await Future<T>.sync(job);
  }

  Future<void> dispose() async {
    _disposed = true;
    _started = false;
  }
}
