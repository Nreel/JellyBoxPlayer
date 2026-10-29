import 'package:flutter_riverpod/flutter_riverpod.dart';

class CastFailure {
  const CastFailure({
    required this.deviceName,
    this.takenOver = false,
  });

  final String deviceName;
  final bool takenOver;

  String get message {
    if (takenOver) {
      return '$deviceName is now playing something else — switched back to '
          'this device.';
    }
    return 'Unable to cast to $deviceName — switched back to this device.';
  }
}

class CastFailureNotifier extends Notifier<CastFailure?> {
  @override
  CastFailure? build() => null;

  void report(String deviceName, {bool takenOver = false}) =>
      state = CastFailure(deviceName: deviceName, takenOver: takenOver);

  void clear() => state = null;
}

final castFailureProvider = NotifierProvider<CastFailureNotifier, CastFailure?>(
  CastFailureNotifier.new,
);
