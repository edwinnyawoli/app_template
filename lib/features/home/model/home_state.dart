import 'package:flutter/foundation.dart' show immutable;

@immutable
class HomeState {
  const HomeState({this.highlights = const <String>[], this.isLoading = false});

  final List<String> highlights;
  final bool isLoading;

  HomeState copyWith({List<String>? highlights, bool? isLoading}) {
    return HomeState(
      highlights: highlights ?? this.highlights,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
