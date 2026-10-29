import 'package:flutter/foundation.dart';

/// Local diagnostics: everything lands in the on-device log
/// (`DeviceLog`), nothing leaves the machine.
class Diagnostics {
  const Diagnostics();

  Future<void> capture(
    Object error, {
    required String operation,
    StackTrace? stackTrace,
    Map<String, String> tags = const {},
    Map<String, Object?> extra = const {},
  }) async {
    final context = [
      for (final tag in tags.entries) '${tag.key}=${tag.value}',
      for (final entry in extra.entries) '${entry.key}=${entry.value}',
    ];
    debugPrintThrottled(
      '[${operation}] $error'
      '${context.isEmpty ? '' : ' (${context.join(', ')})'}',
    );
    if (stackTrace != null) debugPrintThrottled(stackTrace.toString());
  }

  Future<void> report(
    String message, {
    Map<String, Object?> data = const {},
  }) async {
    debugPrintThrottled('[report] $message $data');
  }

  void trail(
    String message, {
    String category = 'app',
    Map<String, Object?> data = const {},
  }) {
    debugPrintThrottled(
      '[$category] $message${data.isEmpty ? '' : ' $data'}',
    );
  }
}
