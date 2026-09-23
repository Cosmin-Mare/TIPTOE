import 'package:flutter/material.dart';

import '../../domain/rules.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../event/event_page.dart';

class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key});

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  int? _node;
  DateTime? _day;

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final events = store.events.where((event) {
      if (_node != null && event.nodeId != _node) return false;
      if (_day != null) {
        final stamp = event.time > 0 ? event.time : event.received;
        if (stamp <= 0) return false;
        final local = DateTime.fromMillisecondsSinceEpoch(stamp * 1000, isUtc: true).toLocal();
        if (local.year != _day!.year || local.month != _day!.month || local.day != _day!.day) return false;
      }
      return true;
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Timeline')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                FilterChip(
                  label: const Text('All nodes'),
                  selected: _node == null,
                  onSelected: (_) => setState(() => _node = null),
                ),
                for (final node in store.nodes.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: FilterChip(
                      label: Text(node.name),
                      selected: _node == node.nodeId,
                      onSelected: (_) => setState(() => _node = node.nodeId),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ActionChip(
                    label: Text(_day == null ? 'Any day' : formatWhen(_day!)),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) setState(() => _day = picked);
                    },
                  ),
                ),
                if (_day != null)
                  IconButton(onPressed: () => setState(() => _day = null), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Expanded(
            child: events.isEmpty
                ? const Center(child: Text('No events yet', style: TextStyle(color: TiptoeColors.mute)))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final event = events[index];
                      final when = eventWhen(event.time, event.received);
                      return Card(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: event.seen ? TiptoeColors.line : TiptoeColors.amber),
                        ),
                        child: ListTile(
                          leading: PhotoThumb(path: event.smallPath ?? event.fullPath),
                          title: Text('${store.nameOf(event.nodeId)} · ${triggerLabel(event.trigger)}'),
                          subtitle: Text(
                            '${when.$1}${event.ir ? ' · IR' : ''}${event.full || event.hiresOnNode ? ' · full-res' : ''}${event.phoneOnly ? ' · on phone only' : ''}',
                          ),
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EventPage(seq: event.seq))),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
