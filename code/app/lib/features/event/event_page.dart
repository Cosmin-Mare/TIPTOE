import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/rules.dart';
import '../../state/tiptoe_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class EventPage extends StatelessWidget {
  const EventPage({super.key, required this.seq});

  final int seq;

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final index = store.events.indexWhere((event) => event.seq == seq);
    if (index < 0) {
      return Scaffold(appBar: AppBar(title: const Text('Event')), body: const Center(child: Text('This event is no longer on the phone.')));
    }
    final event = store.events[index];
    if (!event.seen) {
      Future<void>.microtask(() => store.markSeen(seq));
    }
    final when = eventWhen(event.time, event.received);
    final path = event.fullPath ?? event.smallPath;
    final downloading = store.downloadingSeq == seq;
    return Scaffold(
      appBar: AppBar(title: Text('${store.nameOf(event.nodeId)} · ${triggerLabel(event.trigger)}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                color: TiptoeColors.card,
                child: path == null
                    ? const Center(child: Text('Photo not on the phone yet', style: TextStyle(color: TiptoeColors.mute)))
                    : InteractiveViewer(child: Image.file(File(path), fit: BoxFit.contain)),
              ),
            ),
          ),
          if (downloading)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(value: store.downloadProgress),
            ),
          const SizedBox(height: 16),
          Text(when.$1, style: const TextStyle(fontSize: 18)),
          if (when.$2) const Text('Node clock was not set yet. This is when the handheld received it.', style: TextStyle(color: TiptoeColors.mute)),
          const SizedBox(height: 12),
          _row('Trigger', triggerLabel(event.trigger)),
          _row('IR', event.ir ? 'On' : 'Off'),
          _row('Sound peak', event.soundPeakDb == null ? '—' : '${event.soundPeakDb} dBFS'),
          _row('Sound average', event.soundRmsDb == null ? '—' : '${event.soundRmsDb} dBFS'),
          if (event.soundPeakDb != null) _meter(event.soundPeakDb!),
          _row('Light', event.luma?.toString() ?? '—'),
          _row('Battery then', event.soc == null ? '—' : '${event.soc}%'),
          _row('Arrived via', viaLabel(event.via)),
          _row('Signal', event.rssi == null ? '—' : '${event.rssi} dBm'),
          if (event.cameraFailed) const Text('The camera failed for this event.', style: TextStyle(color: TiptoeColors.bad)),
          if (event.noBudget) const Text('The radio duty-cycle limit was reached, so the photo stayed on the node.'),
          if (event.phoneOnly) const Text('The handheld no longer has this one. The copy here is only on the phone.', style: TextStyle(color: TiptoeColors.mute)),
          const SizedBox(height: 16),
          _fullRes(context, store, event.full, event.hiresOnNode, event.hasImage),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: path == null
                ? null
                : () => SharePlus.instance.share(ShareParams(files: [XFile(path)], text: '${store.nameOf(event.nodeId)} ${when.$1}')),
            child: const Text('Share'),
          ),
          TextButton(
            onPressed: () async {
              final ok = await confirm(context, 'Delete this event?', 'It is removed from the handheld archive and this phone.', 'Delete');
              if (ok && context.mounted) {
                await store.deleteEvent(seq);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('Delete'),
          ),
          TextButton(
            onPressed: () => store.snapshot(event.nodeId),
            child: Text('Take a new snapshot from ${store.nameOf(event.nodeId)}'),
          ),
        ],
      ),
    );
  }

  Widget _fullRes(BuildContext context, TiptoeStore store, bool full, bool onNode, bool hasImage) {
    if (full && hasImage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(onPressed: () => store.fetchFullWifi(seq), child: const Text('Get full-res over Wi-Fi')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () => store.fetchFullBle(seq), child: const Text('Get full-res over Bluetooth')),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Wi-Fi is faster. Bluetooth stays on your current network and takes longer.', style: TextStyle(color: TiptoeColors.mute)),
          ),
        ],
      );
    }
    if (onNode) {
      return const Text(
        'The full photo is stored on the node. Turn on Near mode and walk up to it so the next photos arrive in full, or open maintenance mode and import this one.',
        style: TextStyle(color: TiptoeColors.mute, height: 1.4),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: TiptoeColors.mute))),
          Text(value),
        ],
      ),
    );
  }

  Widget _meter(int db) {
    final level = ((db + 90) / 90).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LinearProgressIndicator(value: level, color: TiptoeColors.amber, backgroundColor: TiptoeColors.line),
    );
  }
}
