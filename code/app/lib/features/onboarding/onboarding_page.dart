import 'dart:async';

import 'package:flutter/material.dart';

import '../../link/ble_handheld.dart';
import '../../link/frame_source.dart';
import '../../state/tiptoe_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

const _suggestedNames = {1: 'Garden', 2: 'Gate', 3: 'Shed'};

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  var _step = 0;
  var _busy = false;
  String? _error;
  List<BleHit> _hits = const [];
  String? _deviceId;
  final _names = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _names.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_step) {
            0 => _intro(store),
            1 => _pair(store),
            _ => _namesStep(store),
          },
        ),
      ),
    );
  }

  Widget _intro(TiptoeStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Spacer(),
        const Text('TIPTOE', style: TextStyle(color: TiptoeColors.amber, letterSpacing: 3, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        const Text('Outdoor nodes sleep until something moves. The handheld you carry collects them, and this phone talks only to that handheld.', style: TextStyle(fontSize: 22, height: 1.35)),
        const SizedBox(height: 16),
        const Text('Alerts and small photos come over Bluetooth. Full-resolution photos use the handheld’s Wi-Fi, and only while you ask for it.', style: TextStyle(color: TiptoeColors.mute, height: 1.4)),
        const Spacer(),
        FilledButton(
          onPressed: _busy ? null : () => _useMock(store),
          child: Text(_busy ? 'Starting…' : 'Review with a simulation'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _busy ? null : () => setState(() => _step = 1), child: const Text('I have a handheld')),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _pair(TiptoeStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Pair', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('The phone will ask for a 6-digit PIN once. It lives in the handheld firmware, not in this app. If pairing fails later, forget TIPTOE-HH in Bluetooth settings.', style: TextStyle(color: TiptoeColors.mute, height: 1.4)),
        const SizedBox(height: 20),
        if (_error != null) Text(_error!, style: const TextStyle(color: TiptoeColors.bad)),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _scan, child: Text(_busy ? 'Scanning…' : 'Scan for TIPTOE-HH')),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : () => _useMock(store),
          child: const Text('No board yet — use the simulation'),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            children: [
              for (final hit in _hits)
                ListTile(
                  title: Text(hit.name),
                  subtitle: Text('${hit.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _useDevice(store, hit.id),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _namesStep(TiptoeStore store) {
    final nodes = store.nodes.values.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Name the nodes', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('Names stay on this phone. The boards only know numbers.', style: TextStyle(color: TiptoeColors.mute)),
        const SizedBox(height: 16),
        Expanded(
          child: nodes.isEmpty
              ? const Text('No nodes have checked in yet. You can name them from the home screen when they do.')
              : ListView(
                  children: [
                    for (final node in nodes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextField(
                          controller: _controller(node.nodeId, node.name),
                          decoration: InputDecoration(
                            labelText: 'Node ${node.nodeId}',
                            hintText: _suggestedNames[node.nodeId],
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        FilledButton(onPressed: () => _finish(store), child: const Text('Start watching')),
      ],
    );
  }

  TextEditingController _controller(int id, String name) {
    final suggested = _suggestedNames[id] ?? '';
    final initial = name.startsWith('Node ') ? suggested : name;
    return _names.putIfAbsent(id, () => TextEditingController(text: initial));
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hits = await BleHandheld.scan();
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _error = hits.isEmpty ? 'No TIPTOE-HH in range. The handheld has to be awake and advertising.' : null;
      });
    } on CommandException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useDevice(TiptoeStore store, String id) async {
    setState(() => _busy = true);
    _deviceId = id;
    await store.beginSession(mock: false, bleId: id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = 2;
    });
  }

  Future<void> _useMock(TiptoeStore store) async {
    setState(() => _busy = true);
    await store.beginSession(mock: true);
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = 2;
    });
  }

  Future<void> _finish(TiptoeStore store) async {
    final names = {for (final entry in _names.entries) entry.key: entry.value.text};
    await store.finishOnboarding(mock: store.useMock, bleId: _deviceId, names: names);
  }
}
