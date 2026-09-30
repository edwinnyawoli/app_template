import 'package:flutter/foundation.dart' show immutable;

@immutable
class AppStatus {
  const AppStatus({required this.label, required this.isOnline});

  final String label;
  final bool isOnline;
}
