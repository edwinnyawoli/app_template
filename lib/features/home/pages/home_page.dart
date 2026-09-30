import 'package:flutter/material.dart';

import '../../../common/widgets/section_card.dart';
import '../model/home_state.dart';
import '../repository/home_repository.dart';

class HomeViewModel extends ChangeNotifier {
  HomeViewModel({required HomeRepository repository})
    : _repository = repository;

  final HomeRepository _repository;
  HomeState _state = const HomeState();

  HomeState get state => _state;
  List<String> get highlights => List.unmodifiable(_state.highlights);
  bool get isLoading => _state.isLoading;

  Future<void> load() async {
    _state = _state.copyWith(isLoading: true);
    notifyListeners();

    final items = await _repository.loadHighlights();

    _state = _state.copyWith(highlights: items, isLoading: false);
    notifyListeners();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({required this.viewModel, super.key});

  final HomeViewModel viewModel;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.addListener(_onViewModelChanged);
    widget.viewModel.load();
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onViewModelChanged);
    super.dispose();
  }

  void _onViewModelChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.viewModel.state;

    return Scaffold(
      appBar: AppBar(title: const Text('Architecture Template')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Feature-first mobile app skeleton',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'This template follows the layered boundaries from the architecture guide.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              if (state.isLoading)
                const Center(child: CircularProgressIndicator())
              else ...[
                SectionCard(
                  title: 'Design principles',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in state.highlights)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.check_circle, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(item)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Layering',
                  child: const Text(
                    'app -> features -> repository contracts -> sdks; core and common stay foundational.',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
