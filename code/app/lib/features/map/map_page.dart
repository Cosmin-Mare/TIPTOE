import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../data/records.dart';
import '../../domain/rules.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../node/node_page.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _map = MapController();
  Timer? _tick;
  LatLng? _phone;
  var _locating = true;
  var _ready = false;
  var _deniedForever = false;
  String? _locationNote;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    _locate(move: true);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate({required bool move}) async {
    setState(() => _locating = true);
    final permission = await _ensurePermission();
    if (!mounted) return;
    if (permission == null) {
      setState(() {
        _locating = false;
        _locationNote = 'Location is off. You can still place a camera by tapping the map.';
      });
      return;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
      );
      _applyFix(position.latitude, position.longitude, move: move);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (!mounted) return;
      if (last == null) {
        setState(() {
          _locating = false;
          _locationNote = 'No location yet. You can still place a camera by tapping the map.';
        });
        return;
      }
      _applyFix(last.latitude, last.longitude, move: move);
    }
  }

  void _applyFix(double lat, double lng, {required bool move}) {
    final point = LatLng(lat, lng);
    setState(() {
      _phone = point;
      _locating = false;
      _locationNote = null;
    });
    if (!move) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ready) _map.move(point, 17);
    });
  }

  Future<LocationPermission?> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _deniedForever = true);
      return null;
    }
    if (permission == LocationPermission.denied) return null;
    if (mounted) setState(() => _deniedForever = false);
    return permission;
  }

  void _fit(Iterable<NodeRecord> placed) {
    if (!_ready) return;
    final points = <LatLng>[
      ?_phone,
      for (final node in placed)
        if (node.lat != null && node.lng != null) LatLng(node.lat!, node.lng!),
    ];
    if (points.isEmpty) return;
    if (points.length == 1) {
      _map.move(points.first, 17);
      return;
    }
    _map.fitCamera(
      CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(64), maxZoom: 18),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final now = DateTime.now();
    final nodes = store.nodes.values.toList()
      ..sort((a, b) => _rank(a, now).compareTo(_rank(b, now)));
    final selected = _selected == null ? null : store.nodes[_selected!];
    final center = _fallbackCenter(nodes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          IconButton(
            tooltip: 'Show all cameras',
            onPressed: () => _fit(nodes),
            icon: const Icon(Icons.fit_screen),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: _phone == null && nodes.every((node) => node.lat == null) ? 2 : 17,
                    onMapReady: () {
                      _ready = true;
                      final phone = _phone;
                      if (phone != null) _map.move(phone, 17);
                    },
                    onTap: (_, point) {
                      final id = _selected;
                      if (id == null) return;
                      store.placeNode(id, point.latitude, point.longitude);
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      userAgentPackageName: 'com.tiptoe.tiptoe',
                    ),
                    if (_phone != null)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: _phone!,
                            radius: 10,
                            color: const Color(0xFF4C8DFF),
                            borderStrokeWidth: 2,
                            borderColor: Colors.white,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        for (final node in nodes)
                          if (node.lat != null && node.lng != null)
                            _marker(context, node, now, selected: node.nodeId == _selected),
                      ],
                    ),
                    const RichAttributionWidget(
                      attributions: [TextSourceAttribution('OpenStreetMap contributors, CARTO')],
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'locate',
                    onPressed: _locating ? null : () => _locate(move: true),
                    child: Icon(_locating ? Icons.hourglass_top : Icons.my_location),
                  ),
                ),
                if (_locationNote != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: SoftCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_locationNote!, style: const TextStyle(height: 1.3)),
                          if (_deniedForever)
                            TextButton(onPressed: Geolocator.openAppSettings, child: const Text('Open settings')),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Material(
            color: TiptoeColors.card,
            child: SizedBox(
              height: 228,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(_hint(selected), style: const TextStyle(color: TiptoeColors.mute, height: 1.3)),
                  ),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: _phone == null ? null : () => store.placeNode(selected.nodeId, _phone!.latitude, _phone!.longitude),
                            child: const Text('Drop at my location'),
                          ),
                          if (selected.lat != null)
                            TextButton(onPressed: () => store.clearNodePlace(selected.nodeId), child: const Text('Remove pin')),
                        ],
                      ),
                    ),
                  Expanded(
                    child: nodes.isEmpty
                        ? const Center(child: Text('No cameras yet. They appear after the first check-in.'))
                        : ListView(
                            children: [
                              for (final node in nodes)
                                ListTile(
                                  dense: true,
                                  selected: node.nodeId == _selected,
                                  leading: Icon(
                                    _alerted(node, now) ? Icons.notifications_active : Icons.videocam_outlined,
                                    color: _pinColor(node, now),
                                  ),
                                  title: Text(node.name),
                                  subtitle: Text(_rowStatus(node, now)),
                                  onTap: () => setState(() => _selected = node.nodeId),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  LatLng _fallbackCenter(List<NodeRecord> nodes) {
    if (_phone != null) return _phone!;
    for (final node in nodes) {
      if (node.lat != null && node.lng != null) return LatLng(node.lat!, node.lng!);
    }
    return const LatLng(0, 0);
  }

  int _rank(NodeRecord node, DateTime now) {
    if (_alerted(node, now)) return 0;
    if (node.lat == null) return 1;
    return 2;
  }

  Marker _marker(BuildContext context, NodeRecord node, DateTime now, {required bool selected}) {
    final alerted = _alerted(node, now);
    final color = _pinColor(node, now);
    return Marker(
      point: LatLng(node.lat!, node.lng!),
      width: 132,
      height: 44,
      alignment: Alignment.bottomCenter,
      child: GestureDetector(
        onTap: () {
          if (_selected == node.nodeId) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => NodePage(nodeId: node.nodeId)));
          } else {
            setState(() => _selected = node.nodeId);
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? Colors.white : Colors.black26, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              alerted ? '${node.name} · motion' : node.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF1A1408), fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  String _hint(NodeRecord? selected) {
    if (selected == null) return 'Choose a camera, then tap the map where it stands. A motion alert turns that pin red for a minute.';
    if (selected.lat == null) return 'Tap the map to place ${selected.name}. If you are standing at it, drop it at your location.';
    return 'Tap the map to move ${selected.name}. Tap its pin again to open it.';
  }

  String _rowStatus(NodeRecord node, DateTime now) {
    final presence = presenceLabel(presenceOf(ageSeconds: node.ageSeconds(now), heartbeatMin: node.heartbeatMin));
    if (_alerted(node, now)) return 'Motion · $presence';
    if (node.lat == null) return 'Not placed · $presence';
    return 'Placed · $presence';
  }

  bool _alerted(NodeRecord node, DateTime now) {
    final at = node.motionAt;
    return at != null && now.difference(at).inSeconds < 60;
  }

  Color _pinColor(NodeRecord node, DateTime now) {
    if (_alerted(node, now)) return TiptoeColors.bad;
    return switch (presenceOf(ageSeconds: node.ageSeconds(now), heartbeatMin: node.heartbeatMin)) {
      Presence.online => TiptoeColors.ok,
      Presence.late => TiptoeColors.warn,
      Presence.offline => TiptoeColors.bad,
      Presence.unknown => TiptoeColors.mute,
    };
  }
}
