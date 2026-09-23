import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/rules.dart';
import '../../link/frame_source.dart';
import '../../state/tiptoe_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../event/event_page.dart';
import '../node/node_page.dart';
import '../simulation/simulation_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.getInheritedWidgetOfExactType<TiptoeScope>()?.notifier;
      if (store != null && store.consumeGuide()) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SimulationPage()));
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final now = DateTime.now();
    final recent = store.events.take(8).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('TIPTOE'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Pill(text: _phase(store), color: _phaseColor(store))),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          if (store.useMock) ...[
            SoftCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Simulation guide'),
                subtitle: const Text('Play alerts, a queued command, and a full-resolution photo.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SimulationPage())),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (store.phaseDetail != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(store.phaseDetail!, style: const TextStyle(color: TiptoeColors.mute)),
            ),
          _handheld(store),
          const SizedBox(height: 12),
          if (store.nodes.isEmpty)
            const SoftCard(child: Text('No outdoor nodes yet. They appear after their first check-in.')),
          for (final node in store.nodes.values) ...[
            _nodeCard(context, store, node.nodeId, now),
            const SizedBox(height: 12),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Recent', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final event = recent[index];
                  return GestureDetector(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EventPage(seq: event.seq))),
                    child: PhotoThumb(path: event.smallPath ?? event.fullPath, size: 96),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _handheld(TiptoeStore store) {
    final handheld = store.handheld;
    return SoftCard(
      child: Row(
        children: [
          const Icon(Icons.sensors, color: TiptoeColors.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Handheld', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  handheld == null
                      ? 'Waiting for a status'
                      : '${batteryText(handheld.soc, handheld.charge)} · Wi-Fi ${handheld.wifi ? 'on' : 'off'}',
                  style: const TextStyle(color: TiptoeColors.mute),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nodeCard(BuildContext context, TiptoeStore store, int id, DateTime now) {
    final node = store.nodes[id]!;
    final presence = presenceOf(ageSeconds: node.ageSeconds(now), heartbeatMin: node.heartbeatMin);
    final motion = node.motionAt != null && now.difference(node.motionAt!).inSeconds < 60;
    final warnings = notesFor(node).where((note) => !note.info);
    final armed = node.pendingValues['armed'] ?? node.config['armed'] ?? 0;
    final eta = node.pendingCount > 0 || node.pendingValues.isNotEmpty
        ? pendingEta(lastSeen: node.lastSeen, heartbeatMin: node.heartbeatMin, motionLikely: motion, now: now)
        : null;
    final color = switch (presence) {
      Presence.online => TiptoeColors.ok,
      Presence.late => TiptoeColors.warn,
      Presence.offline => TiptoeColors.bad,
      Presence.unknown => TiptoeColors.mute,
    };
    return SoftCard(
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NodePage(nodeId: id))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(node.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                Pill(text: presenceLabel(presence), color: color),
                if (motion) ...[
                  const SizedBox(width: 6),
                  const Pill(text: 'Motion', color: TiptoeColors.bad),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(batteryText(node.soc, node.charge, qiMv: node.qiMv), style: const TextStyle(color: TiptoeColors.mute)),
                const SizedBox(width: 10),
                SignalMarks(rssi: node.rssi),
                const SizedBox(width: 10),
                Text(ago(node.lastSeen, now: now), style: const TextStyle(color: TiptoeColors.mute)),
                const Spacer(),
                const Text('Armed', style: TextStyle(color: TiptoeColors.mute, fontSize: 12)),
                Switch(
                  value: armed != 0,
                  onChanged: (value) => store.setValue(id, 'armed', value ? 1 : 0),
                ),
              ],
            ),
            if (eta != null)
              Text(
                node.pendingCount > 0 ? '$eta · ${node.pendingCount} queued' : eta,
                style: const TextStyle(color: TiptoeColors.warn),
              ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(warning.message, style: TextStyle(color: warning.critical ? TiptoeColors.bad : TiptoeColors.warn)),
              ),
          ],
        ),
      ),
    );
  }

  String _phase(TiptoeStore store) {
    if (store.useMock && store.phase == LinkPhase.live) return 'Simulated';
    return switch (store.phase) {
      LinkPhase.live => 'Live',
      LinkPhase.syncing => 'Syncing',
      LinkPhase.connecting => 'Connecting',
      LinkPhase.reconnecting => 'Reconnecting',
      LinkPhase.idle => 'Offline',
    };
  }

  Color _phaseColor(TiptoeStore store) {
    return switch (store.phase) {
      LinkPhase.live => TiptoeColors.ok,
      LinkPhase.reconnecting => TiptoeColors.warn,
      LinkPhase.idle => TiptoeColors.mute,
      _ => TiptoeColors.amber,
    };
  }
}
