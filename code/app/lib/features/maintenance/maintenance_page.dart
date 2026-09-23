import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../link/archive_http.dart';
import '../../link/frame_source.dart';
import '../../link/wifi_join.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key, required this.nodeId});

  final int nodeId;

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  final _password = TextEditingController();
  var _busy = false;
  String? _status;
  List<Map<String, Object?>> _events = const [];
  final _http = const ArchiveHttp();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final name = store.nameOf(widget.nodeId);
    return Scaffold(
      appBar: AppBar(title: Text('Visit $name')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Maintenance is for setup, diagnostics, and the node’s own archive. The node opens Wi-Fi TIPTOE-<id> at its next check-in, or immediately if you press its BOOT button. The password is the maintenance AP password from the firmware. It is not stored in this app.',
            style: TextStyle(height: 1.4, color: TiptoeColors.mute),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => store.maintenance(widget.nodeId),
            child: const Text('Ask the node to open Wi-Fi'),
          ),
          const SizedBox(height: 12),
          Text('Then join TIPTOE-${widget.nodeId}.', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Maintenance password', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _busy ? null : () => _join(store), child: const Text('Join and load archive')),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: const TextStyle(color: TiptoeColors.mute)),
          ],
          for (final event in _events)
            ListTile(
              title: Text('Event ${event['id']}'),
              subtitle: Text('${event['meta'] ?? ''}'.trim()),
              trailing: TextButton(
                onPressed: _busy ? null : () => _import(store, event),
                child: const Text('Import'),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _busy ? null : _exit, child: const Text('Exit and let the node sleep')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _busy ? null : _ota, child: const Text('Upload firmware')),
        ],
      ),
    );
  }

  Future<void> _join(dynamic store) async {
    setState(() => _busy = true);
    try {
      final joined = await WifiJoin.join(ssid: 'TIPTOE-${widget.nodeId}', password: _password.text);
      if (!joined && mounted) {
        store.notice('Join TIPTOE-${widget.nodeId} in Wi-Fi settings, then load the archive.');
      }
      final status = await _http.status();
      final events = await _http.events();
      if (!mounted) return;
      setState(() {
        _status = status.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n');
        _events = events;
      });
    } on CommandException catch (error) {
      if (mounted) store.notice(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(dynamic store, Map<String, Object?> event) async {
    final id = event['id'];
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final hi = event['hi'] == true;
      final bytes = await _http.bytes('/ev/$id${hi ? '_hi' : ''}.jpg');
      final match = store.events.cast<dynamic>().where((item) => item.nodeId == widget.nodeId && item.eventId == id).toList();
      if (match.isEmpty) {
        store.notice('Saved the file, but no phone event matches node ${widget.nodeId} event $id.');
        await store.photos.saveBytes('node${widget.nodeId}_$id.jpg', bytes);
      } else {
        final seq = match.first.seq as int;
        await store.attachImport(seq, bytes, full: hi);
        if (event['wav'] == true) {
          final wav = await _http.bytes('/ev/$id.wav');
          await store.attachAudio(seq, wav);
        }
        store.notice('Imported event $id.');
      }
    } on CommandException catch (error) {
      store.notice(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exit() async {
    try {
      await _http.exitMaintenance();
      await WifiJoin.leave(ssid: 'TIPTOE-${widget.nodeId}');
      if (mounted) TiptoeScope.of(context).notice('The node is going back to sleep.');
    } on CommandException catch (error) {
      if (mounted) TiptoeScope.of(context).notice(error.message);
    }
  }

  Future<void> _ota() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['bin']);
    final path = picked?.files.single.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final text = await _http.uploadFirmware(path);
      if (mounted) TiptoeScope.of(context).notice(text);
    } on CommandException catch (error) {
      if (mounted) TiptoeScope.of(context).notice(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
