import 'package:flutter/material.dart';

import 'features/onboarding/onboarding_page.dart';
import 'features/shell/home_shell.dart';
import 'state/tiptoe_store.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

class TiptoeApp extends StatelessWidget {
  const TiptoeApp({super.key, required this.store});

  final TiptoeStore store;

  @override
  Widget build(BuildContext context) {
    return TiptoeScope(
      store: store,
      child: MaterialApp(
        title: 'TIPTOE',
        theme: tiptoeTheme(),
        home: const NoticeHost(child: _Gate()),
      ),
    );
  }
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    return store.onboarded ? const HomeShell() : const OnboardingPage();
  }
}
