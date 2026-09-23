import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/rules.dart';
import '../../ui/widgets.dart';
import '../simulation/simulation_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (store.useMock) ...[
            ListTile(
              title: const Text('Simulation guide'),
              subtitle: const Text('Replay alerts and photos without a board'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SimulationPage())),
            ),
            ListTile(
              title: const Text('Leave simulation'),
              subtitle: const Text('Pair a real handheld instead'),
              onTap: () async {
                final ok = await confirm(
                  context,
                  'Leave the simulation?',
                  'Simulated events stay on this phone. You can pair a handheld next.',
                  'Leave',
                );
                if (ok) await store.leaveSimulation();
              },
            ),
            const Divider(),
          ],
          const ListTile(title: Text('Notifications')),
          for (final node in store.nodes.values)
            ListTile(
              title: Text(node.name),
              subtitle: Text(_prefLabel(store.prefFor(node.nodeId))),
              onTap: () async {
                final picked = await showModalBottomSheet<NotifyPref>(
                  context: context,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final pref in NotifyPref.values)
                          ListTile(
                            title: Text(_prefLabel(pref)),
                            onTap: () => Navigator.pop(context, pref),
                          ),
                      ],
                    ),
                  ),
                );
                if (picked != null) await store.setPref(node.nodeId, picked);
              },
            ),
          ListTile(
            title: const Text('Quiet hours'),
            subtitle: Text(store.quietStart < 0 ? 'Off' : '${store.quietStart}:00 – ${store.quietEnd}:00'),
            onTap: () => _quiet(context, store),
          ),
          ListTile(
            title: const Text('Keep photos'),
            subtitle: Text(store.keepDays <= 0 ? 'Forever' : '${store.keepDays} days'),
            onTap: () => _retention(context, store),
          ),
          ListTile(
            title: const Text('Export archive'),
            subtitle: const Text('Event list as JSON. Photos stay on this phone.'),
            onTap: () async {
              final file = await store.exportFile();
              await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
            },
          ),
          const Divider(),
          const ListTile(title: Text('Debug log'), subtitle: Text('Raw frames, with Wi-Fi passwords removed')),
          if (store.log.isEmpty)
            const ListTile(title: Text('Nothing yet', style: TextStyle(color: Colors.white54)))
          else
            for (final line in store.log.take(40))
              ListTile(dense: true, title: Text(line, style: const TextStyle(fontSize: 11))),
        ],
      ),
    );
  }

  String _prefLabel(NotifyPref pref) {
    switch (pref) {
      case NotifyPref.all:
        return 'All events';
      case NotifyPref.motion:
        return 'Motion only';
      case NotifyPref.none:
        return 'None';
    }
  }

  Future<void> _quiet(BuildContext context, dynamic store) async {
    final start = await _hour(context, 'Quiet from', store.quietStart < 0 ? 22 : store.quietStart);
    if (start == null || !context.mounted) return;
    if (start < 0) {
      await store.setQuietHours(-1, -1);
      return;
    }
    final end = await _hour(context, 'Quiet until', store.quietEnd);
    if (end == null) return;
    await store.setQuietHours(start, end);
  }

  Future<int?> _hour(BuildContext context, String title, int current) {
    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(context, -1), child: const Text('Off')),
          for (var hour = 0; hour < 24; hour++)
            SimpleDialogOption(onPressed: () => Navigator.pop(context, hour), child: Text('$hour:00')),
        ],
      ),
    );
  }

  Future<void> _retention(BuildContext context, dynamic store) async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Keep photos'),
        children: [
          for (final days in [7, 30, 90, 365, 0])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, days),
              child: Text(days == 0 ? 'Forever' : '$days days'),
            ),
        ],
      ),
    );
    if (days != null) await store.setRetention(days);
  }
}
