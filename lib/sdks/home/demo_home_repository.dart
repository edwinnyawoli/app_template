import '../../features/home/repository/home_repository.dart';

class DemoHomeRepository implements HomeRepository {
  @override
  Future<List<String>> loadHighlights() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));

    return const [
      'Architecture-first code layout',
      'Stable feature contracts over SDK types',
      'Testable presentation logic',
    ];
  }
}
