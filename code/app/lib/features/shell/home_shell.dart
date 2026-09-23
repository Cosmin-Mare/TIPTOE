import 'package:flutter/material.dart';

import '../../state/tiptoe_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../event/event_page.dart';
import '../handheld/handheld_page.dart';
import '../home/home_page.dart';
import '../map/map_page.dart';
import '../node/node_page.dart';
import '../settings/settings_page.dart';
import '../timeline/timeline_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  TiptoeStore? _store;
  final List<Widget?> _pages = List<Widget?>.filled(5, null);

  @override
  void initState() {
    super.initState();
    _store = context.getInheritedWidgetOfExactType<TiptoeScope>()!.notifier;
    _store!.addListener(_route);
    _pages[0] = const HomePage();
  }

  @override
  void dispose() {
    _store?.removeListener(_route);
    super.dispose();
  }

  void _route() {
    final payload = _store?.launchPayload;
    if (payload == null || !mounted) return;
    _store!.launchPayload = null;
    final store = _store!;
    if (payload.startsWith('seq:')) {
      final seq = int.tryParse(payload.substring(4));
      if (seq != null && store.events.any((event) => event.seq == seq)) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventPage(seq: seq)));
      }
      return;
    }
    final parts = payload.split(':');
    if (parts.length == 4 && parts[0] == 'node' && parts[2] == 'event') {
      final node = int.tryParse(parts[1]);
      final eventId = int.tryParse(parts[3]);
      if (node == null) return;
      for (final event in store.events) {
        if (event.nodeId == node && event.eventId == eventId) {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => EventPage(seq: event.seq)));
          return;
        }
      }
      if (store.nodes.containsKey(node)) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => NodePage(nodeId: node)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _pages[_index] ??= switch (_index) {
      0 => const HomePage(),
      1 => const MapPage(),
      2 => const TimelinePage(),
      3 => const HandheldPage(),
      _ => const SettingsPage(),
    };
    return Scaffold(
      body: Stack(
        children: [
          for (var i = 0; i < _pages.length; i++)
            Offstage(
              offstage: i != _index,
              child: TickerMode(enabled: i == _index, child: _pages[i] ?? const SizedBox.shrink()),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: TiptoeColors.ink,
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.timeline), label: 'Timeline'),
          NavigationDestination(icon: Icon(Icons.sensors), label: 'Handheld'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
