import 'package:flutter_test/flutter_test.dart';
import 'package:app_template/features/home/home.dart';

class FakeHomeRepository implements HomeRepository {
  @override
  Future<List<String>> loadHighlights() async => ['Architecture', 'Testing'];
}

void main() {
  test('HomeViewModel loads highlights from the repository', () async {
    final viewModel = HomeViewModel(repository: FakeHomeRepository());

    await viewModel.load();

    expect(viewModel.highlights, ['Architecture', 'Testing']);
    expect(viewModel.isLoading, isFalse);
  });
}
