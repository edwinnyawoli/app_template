import 'package:flutter/material.dart';

import '../features/home/home.dart';
import '../sdks/home/demo_home_repository.dart';
import '../theme/app_theme.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final viewModel = HomeViewModel(repository: DemoHomeRepository());

    return MaterialApp(
      title: 'App Template',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: HomePage(viewModel: viewModel),
    );
  }
}
