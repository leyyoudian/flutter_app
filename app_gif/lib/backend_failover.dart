const primaryBackendBase = 'http://47.108.204.22';
const fallbackBackendBase = 'http://60.205.122.153';

List<Uri> backendBaseCandidates({String overrideBase = ''}) {
  final values = <String>[
    if (overrideBase.trim().isNotEmpty) overrideBase.trim(),
    primaryBackendBase,
    fallbackBackendBase,
  ];
  final seen = <String>{};
  return values
      .map(
        (value) =>
            Uri.parse(value).replace(path: '', query: null, fragment: null),
      )
      .where((uri) => seen.add(uri.toString()))
      .toList(growable: false);
}

class BackendRequestException implements Exception {
  const BackendRequestException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

Future<T> withBackendFailover<T>(
  Iterable<Uri> candidates,
  Future<T> Function(Uri base) operation, {
  bool Function(Object error)? shouldRetry,
}) async {
  Object? lastError;
  StackTrace? lastStackTrace;
  final bases = candidates.toList(growable: false);
  for (var index = 0; index < bases.length; index++) {
    try {
      return await operation(bases[index]);
    } catch (error, stackTrace) {
      lastError = error;
      lastStackTrace = stackTrace;
      final hasFallback = index + 1 < bases.length;
      if (!hasFallback || (shouldRetry != null && !shouldRetry(error))) {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }
  Error.throwWithStackTrace(
    lastError ?? const BackendRequestException('no backend configured'),
    lastStackTrace ?? StackTrace.current,
  );
}
