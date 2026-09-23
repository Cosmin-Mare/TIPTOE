import 'dart:io';

import 'package:flutter/material.dart';

import '../data/records.dart';
import '../domain/rules.dart';
import '../state/tiptoe_store.dart';
import 'theme.dart';

class TiptoeScope extends InheritedNotifier<TiptoeStore> {
  const TiptoeScope({super.key, required TiptoeStore store, required super.child}) : super(notifier: store);

  static TiptoeStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TiptoeScope>();
    assert(scope != null, 'TiptoeScope is missing');
    return scope!.notifier!;
  }
}

class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.child});
  final Widget child;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  TiptoeStore? _store;

  @override
  void initState() {
    super.initState();
    _store = context.getInheritedWidgetOfExactType<TiptoeScope>()!.notifier;
    _store!.addListener(_show);
  }

  @override
  void dispose() {
    _store?.removeListener(_show);
    super.dispose();
  }

  void _show() {
    final message = _store?.takeNotice();
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(child: Padding(padding: padding, child: child));
  }
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class SignalMarks extends StatelessWidget {
  const SignalMarks({super.key, required this.rssi});
  final double? rssi;

  @override
  Widget build(BuildContext context) {
    final bars = signalBars(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 1; i <= 3; i++)
          Container(
            width: 4,
            height: 5.0 + i * 4,
            margin: const EdgeInsets.only(right: 2),
            color: i <= bars ? TiptoeColors.amber : TiptoeColors.line,
          ),
      ],
    );
  }
}

class PhotoThumb extends StatelessWidget {
  const PhotoThumb({super.key, this.path, this.size = 72});
  final String? path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: TiptoeColors.line,
        child: file != null && file.existsSync()
            ? Image.file(file, fit: BoxFit.cover)
            : const Icon(Icons.photo_outlined, color: TiptoeColors.mute),
      ),
    );
  }
}

String batteryText(double? soc, String? charge, {int? qiMv}) {
  if (soc == null) return 'Battery —';
  final suffix = isCharging(charge, qiMv: qiMv) ? ' · charging' : '';
  return '${soc.round()}%$suffix';
}

String configValueLabel(String key, int? value) {
  if (value == null) return 'not reported';
  switch (key) {
    case 'armed':
    case 'send_image':
    case 'hires_local':
    case 'grayscale_ir':
      return value == 0 ? 'Off' : 'On';
    case 'ir_mode':
      return irModeLabels[value] ?? '$value';
    case 'framesize':
      return frameSizeLabels[value] ?? '$value';
    case 'heartbeat_min':
      return '$value min';
    case 'cooldown_s':
    case 'audio_ms':
      return '$value';
    case 'tx_power':
      return '$value dBm';
    default:
      return '$value';
  }
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

List<HealthNote> notesFor(NodeRecord node) {
  return healthNotes(
    soc: node.soc,
    charge: node.charge,
    ntc: node.ntc,
    qiMv: node.qiMv,
    hwOk: node.hwOk,
    fsFreeKb: node.fsFreeKb,
    rssi: node.rssi,
    snr: node.snr,
  );
}
