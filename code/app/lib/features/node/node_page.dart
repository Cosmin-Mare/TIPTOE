import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/rules.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../event/event_page.dart';
import '../maintenance/maintenance_page.dart';

class NodePage extends StatelessWidget {
  const NodePage({super.key, required this.nodeId});

  final int nodeId;

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final node = store.nodes[nodeId];
    if (node == null) {
      return Scaffold(appBar: AppBar(title: Text('Node $nodeId')), body: const Center(child: Text('This node is not on the phone.')));
    }
    final now = DateTime.now();
    final presence = presenceOf(ageSeconds: node.ageSeconds(now), heartbeatMin: node.heartbeatMin);
    final history = store.events.where((event) => event.nodeId == nodeId).take(12);
    return Scaffold(
      appBar: AppBar(title: Text(node.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Pill(
                text: presenceLabel(presence),
                color: presence == Presence.online ? TiptoeColors.ok : TiptoeColors.warn,
              ),
              const SizedBox(width: 8),
              Text(ago(node.lastSeen, now: now), style: const TextStyle(color: TiptoeColors.mute)),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Name on this phone'),
            subtitle: Text(node.name),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () async {
              final controller = TextEditingController(text: node.name);
              final name = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Name'),
                  content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(border: OutlineInputBorder())),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
                  ],
                ),
              );
              controller.dispose();
              if (name != null) await store.renameNode(nodeId, name);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              node.lat == null ? 'Not on the map yet. Open Map, select this camera, and tap where it stands.' : 'Placed on the map. Motion turns its pin red for a minute.',
              style: const TextStyle(color: TiptoeColors.mute),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Status', style: TextStyle(fontWeight: FontWeight.w600)),
          _line('Battery', batteryText(node.soc, node.charge, qiMv: node.qiMv)),
          _line('Voltage', node.vbatMv == null ? '—' : '${node.vbatMv} mV'),
          _line('Qi input', node.qiMv != null && node.qiMv! > 4000 ? '${node.qiMv} mV' : 'none'),
          _line('Charger', node.ntc ?? '—'),
          _line('Temperature', node.tempC == null ? '—' : '${node.tempC} °C'),
          _line('Firmware', node.fw ?? '—'),
          _line('Uptime', node.uptimeS == null ? '—' : '${node.uptimeS} s'),
          _line('Free storage', node.fsFreeKb == null ? '—' : '${node.fsFreeKb} KB'),
          _line('Link', '${viaLabel(node.via)} · ${node.rssi ?? '—'} dBm · SNR ${node.snr ?? '—'}'),
          _line('Hardware', node.hwOk == null ? '—' : '0x${node.hwOk!.toRadixString(16)}'),
          for (final note in notesFor(node))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note.message, style: TextStyle(color: note.critical ? TiptoeColors.bad : note.info ? TiptoeColors.mute : TiptoeColors.warn)),
            ),
          if (node.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final note in node.notes) Text(note, style: const TextStyle(color: TiptoeColors.mute)),
          ],
          const SizedBox(height: 20),
          const Text('Settings', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('A change waits on the handheld until this node next wakes up.', style: TextStyle(color: TiptoeColors.mute)),
          if (node.heartbeatMin > 15)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Lower the check-in to 5–10 min if you want faster control. It costs battery on the node.'),
            ),
          for (final field in configFields)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(field.label),
              subtitle: Text(_subtitle(node, field)),
              onTap: () => _edit(context, store, field),
            ),
          if (node.pendingCount > 0 || node.pendingValues.isNotEmpty)
            TextButton(
              onPressed: () => store.cancelPending(nodeId),
              child: Text('Cancel queued commands (${node.pendingCount})'),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: () => store.snapshot(nodeId), child: const Text('Snapshot')),
              OutlinedButton(onPressed: () => store.requestStatus(nodeId), child: const Text('Request status')),
              OutlinedButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MaintenancePage(nodeId: nodeId))),
                child: const Text('Visit node'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final ok = await confirm(context, 'Reboot node ${node.name}?', 'It restarts at the next check-in.', 'Reboot');
                  if (ok) await store.reboot(nodeId);
                },
                child: const Text('Reboot'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final ok = await confirm(context, 'Clear storage on ${node.name}?', 'The node deletes its own photos and audio at the next check-in.', 'Clear');
                  if (ok) await store.clearNode(nodeId);
                },
                child: const Text('Clear storage'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Events', style: TextStyle(fontWeight: FontWeight.w600)),
          for (final event in history)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: PhotoThumb(path: event.smallPath ?? event.fullPath, size: 48),
              title: Text(triggerLabel(event.trigger)),
              subtitle: Text(eventWhen(event.time, event.received).$1),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EventPage(seq: event.seq))),
            ),
        ],
      ),
    );
  }

  String _subtitle(dynamic node, ConfigField field) {
    final pending = node.pendingValues[field.key] as int?;
    final confirmed = node.config[field.key] as int?;
    final shown = configValueLabel(field.key, pending ?? confirmed);
    if (pending != null && pending != confirmed) {
      return '$shown · pending (now ${configValueLabel(field.key, confirmed)})';
    }
    return shown;
  }

  Future<void> _edit(BuildContext context, dynamic store, ConfigField field) async {
    final node = store.nodes[nodeId];
    final current = (node.pendingValues[field.key] ?? node.config[field.key] ?? field.min) as int;
    final controller = TextEditingController(text: '$current');
    final saved = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(field.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.help.isNotEmpty) Text(field.help, style: const TextStyle(color: TiptoeColors.mute)),
            const SizedBox(height: 12),
            if (field.key == 'ir_mode')
              DropdownButtonFormField<int>(
                initialValue: current.clamp(0, 2),
                items: [for (final entry in irModeLabels.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
                onChanged: (value) => controller.text = '${value ?? current}',
              )
            else if (field.key == 'framesize')
              DropdownButtonFormField<int>(
                initialValue: current.clamp(field.min, field.max),
                items: [
                  for (final entry in frameSizeLabels.entries)
                    if (entry.key >= field.min && entry.key <= field.max)
                      DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) => controller.text = '${value ?? current}',
              )
            else
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(signed: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'-?\d+'))],
                decoration: InputDecoration(helperText: '${field.min} to ${field.max}'),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value == null || value < field.min || value > field.max) return;
              Navigator.pop(context, value);
            },
            child: const Text('Queue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved != null) await store.setValue(nodeId, field.key, saved);
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: TiptoeColors.mute))),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
