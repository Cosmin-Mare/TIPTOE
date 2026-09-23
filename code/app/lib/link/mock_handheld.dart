import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import '../protocol/stream_parser.dart';
import '../protocol/uuids.dart';
import 'frame_source.dart';

class _MockNode {
  _MockNode({
    required this.id,
    required this.lastSeen,
    required this.rssi,
    required this.snr,
    required this.soc,
    required this.vbat,
    required this.charge,
    required this.ntc,
    required this.qi,
    required this.temp,
    required this.hwOk,
    required this.fsFree,
    required this.heartbeat,
    required this.armed,
  });

  final int id;
  DateTime lastSeen;
  double rssi;
  double snr;
  double soc;
  int vbat;
  String charge;
  String ntc;
  int qi;
  int temp;
  int hwOk;
  int fsFree;
  int heartbeat;
  int armed;
  int cooldown = 30;
  int quality = 14;
  int framesize = 5;
  int irMode = 2;
  int irLuma = 40;
  int audioMs = 800;
  int txPower = 14;
  int sendImage = 1;
  int hiresLocal = 1;
  int grayscaleIr = 1;
  int eventCount = 3;
  final List<Map<String, Object?>> queue = [];

  Map<String, Object?> statusJson() => {
    'fw': '1.2',
    'armed': armed,
    'soc': soc,
    'vbat_mv': vbat,
    'crate_pct_h': charge == 'not charging' ? -0.4 : 18.0,
    'charge': charge,
    'ntc': ntc,
    'charger_fault': 0,
    'qi_mv': qi,
    'temp_c': temp,
    'node_rssi': rssi.round(),
    'event_count': eventCount,
    'uptime_s': 86000,
    'fs_free_kb': fsFree,
    'hw_ok': hwOk,
    'config': {
      'armed': armed,
      'heartbeat_min': heartbeat,
      'cooldown_s': cooldown,
      'jpeg_quality': quality,
      'framesize': framesize,
      'ir_mode': irMode,
      'ir_luma': irLuma,
      'audio_ms': audioMs,
      'tx_power': txPower,
      'send_image': sendImage,
      'hires_local': hiresLocal,
      'grayscale_ir': grayscaleIr,
    },
  };

  int apply(String key, int value) {
    switch (key) {
      case 'armed':
        armed = value;
      case 'heartbeat_min':
        heartbeat = value;
      case 'cooldown_s':
        cooldown = value;
      case 'jpeg_quality':
        quality = value;
      case 'framesize':
        framesize = value;
      case 'ir_mode':
        irMode = value;
      case 'ir_luma':
        irLuma = value;
      case 'audio_ms':
        audioMs = value;
      case 'tx_power':
        txPower = value;
      case 'send_image':
        sendImage = value;
      case 'hires_local':
        hiresLocal = value;
      case 'grayscale_ir':
        grayscaleIr = value;
      default:
        return 0;
    }
    return 1;
  }
}

/// Debug handheld. Emits the same framed stream the PCB would.
class MockHandheld implements FrameSource {
  final _incoming = StreamController<List<int>>.broadcast();
  final _nodes = <int, _MockNode>{};
  final _events = <Map<String, Object?>>[];
  final _jpegs = <int, Uint8List>{};
  var _seq = 40;
  var _running = false;
  var _wifi = false;
  var _timeSynced = false;
  var _uptime = 5321;
  Timer? _statusTimer;
  Timer? _wifiTimer;
  Future<void> _chain = Future<void>.value();
  Future<void> _emitLock = Future<void>.value();

  MockHandheld() {
    final now = DateTime.now();
    _nodes[1] = _MockNode(
      id: 1,
      lastSeen: now.subtract(const Duration(minutes: 4)),
      rssi: -86,
      snr: 8,
      soc: 76,
      vbat: 3981,
      charge: 'not charging',
      ntc: 'normal',
      qi: 0,
      temp: 21,
      hwOk: 127,
      fsFree: 8120,
      heartbeat: 30,
      armed: 1,
    );
    _nodes[2] = _MockNode(
      id: 2,
      lastSeen: now.subtract(const Duration(minutes: 80)),
      rssi: -108,
      snr: 2,
      soc: 41,
      vbat: 3720,
      charge: 'not charging',
      ntc: 'warm',
      qi: 0,
      temp: 34,
      hwOk: 127,
      fsFree: 6400,
      heartbeat: 30,
      armed: 1,
    );
    _nodes[3] = _MockNode(
      id: 3,
      lastSeen: now.subtract(const Duration(hours: 8)),
      rssi: -120,
      snr: -12,
      soc: 4,
      vbat: 3480,
      charge: 'not charging',
      ntc: 'cold',
      qi: 0,
      temp: 2,
      hwOk: 127 & ~8,
      fsFree: 900,
      heartbeat: 30,
      armed: 0,
    );
    _remember(_archived(node: 1, trigger: 'pir', ago: const Duration(hours: 1), full: false));
    _remember(_archived(node: 2, trigger: 'snapshot', ago: const Duration(hours: 5), full: false));
  }

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> start() async {
    _running = true;
    await _emitJson(_handheld());
    await _emitJson(_nodesJson());
    await _emitJson(_wifiJson());
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final node = _nodes[1];
      if (node == null || !_running) return;
      node.lastSeen = DateTime.now();
      _emitJson(_report(node, hello: false));
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_running) _motion(1);
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    _statusTimer?.cancel();
    _wifiTimer?.cancel();
  }

  @override
  void watchDisconnect(void Function(String reason) onLost) {}

  @override
  void simulateMotion() => runScenario('motion');

  @override
  void runScenario(String name) {
    switch (name) {
      case 'camera_fail':
        unawaited(_motion(1, cameraFailed: true));
      case 'no_budget':
        unawaited(_motion(2, noBudget: true));
      case 'near':
        _setWifi(true);
        unawaited(() async {
          await _emitJson(_wifiJson());
          await _motion(1);
        }());
      default:
        unawaited(_motion(1));
    }
  }

  @override
  Future<void> write(List<int> bytes) {
    final next = _chain.then((_) => _handle(utf8.decode(bytes)));
    _chain = next.catchError((_) {});
    return Future<void>.value();
  }

  Future<void> _handle(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      await _emitJson({'t': 'resp', 'ok': false, 'error': 'bad json'});
      return;
    }
    final cmd = decoded['cmd']?.toString() ?? '';
    final rid = decoded['rid'];
    Map<String, Object?> reply;
    switch (cmd) {
      case 'hello':
      case 'nodes':
        reply = _nodesJson();
      case 'handheld':
        reply = _handheld();
      case 'time':
        _timeSynced = (decoded['unix'] as num? ?? 0) > 0;
        reply = {'t': 'resp', 'cmd': cmd, 'ok': _timeSynced};
      case 'events':
        reply = _eventsJson(decoded);
      case 'get_image':
        final seq = (decoded['seq'] as num?)?.toInt() ?? 0;
        final jpeg = _jpegs[seq];
        if (jpeg == null) {
          reply = {'t': 'resp', 'cmd': cmd, 'ok': false, 'error': 'not found'};
        } else {
          final wantFull = decoded['full'] == true;
          await _emitFrame(frameTypeImage, encodeImagePayload(seq, wantFull && _events.any((e) => e['seq'] == seq && e['full'] == true), jpeg));
          reply = {'t': 'resp', 'cmd': cmd, 'ok': true, 'bytes': jpeg.length};
        }
      case 'delete_event':
        final seq = (decoded['seq'] as num?)?.toInt() ?? 0;
        _events.removeWhere((event) => event['seq'] == seq);
        _jpegs.remove(seq);
        reply = {'t': 'resp', 'cmd': cmd, 'ok': true};
      case 'set':
        reply = _queueSet(decoded);
      case 'snapshot':
      case 'reboot':
      case 'maintenance':
      case 'status':
      case 'clear':
        reply = _queueOp(cmd, decoded);
      case 'cancel':
        reply = _cancel(decoded);
      case 'wifi':
        _setWifi(decoded['on'] == true);
        reply = _wifiJson();
      default:
        reply = {'t': 'resp', 'cmd': cmd, 'ok': false, 'error': 'unknown cmd'};
    }
    if (rid != null) reply['rid'] = rid;
    await _emitJson(reply);
  }

  Map<String, Object?> _queueSet(Map decoded) {
    final ids = _targets(decoded['node']);
    final key = decoded['key']?.toString() ?? '';
    final value = decoded['value'];
    if (ids.isEmpty || value is! num || !_knownKey(key)) {
      return {'t': 'resp', 'cmd': 'set', 'ok': false, 'error': 'bad $key'};
    }
    for (final id in ids) {
      _nodes[id]!.queue.add({'cmd': 'set', 'key': key, 'value': value.toInt()});
      unawaited(_emitJson({'t': 'pending', 'node': id, 'count': _nodes[id]!.queue.length}));
      _deliverLater(id);
    }
    return {'t': 'resp', 'cmd': 'set', 'ok': true, 'queued_for': ids.length};
  }

  bool _knownKey(String key) {
    return const {
      'armed',
      'heartbeat_min',
      'cooldown_s',
      'jpeg_quality',
      'framesize',
      'ir_mode',
      'ir_luma',
      'audio_ms',
      'tx_power',
      'send_image',
      'hires_local',
      'grayscale_ir',
    }.contains(key);
  }

  Map<String, Object?> _queueOp(String cmd, Map decoded) {
    final ids = _targets(decoded['node']);
    if (ids.isEmpty) return {'t': 'resp', 'cmd': cmd, 'ok': false, 'error': 'bad node'};
    for (final id in ids) {
      _nodes[id]!.queue.add({'cmd': cmd});
      unawaited(_emitJson({'t': 'pending', 'node': id, 'count': _nodes[id]!.queue.length}));
      _deliverLater(id);
    }
    return {'t': 'resp', 'cmd': cmd, 'ok': true, 'queued_for': ids.length};
  }

  void _deliverLater(int id) {
    Future<void>.delayed(const Duration(seconds: 6), () async {
      final node = _nodes[id];
      if (node == null || !_running || node.queue.isEmpty) return;
      final job = node.queue.removeAt(0);
      final cmd = job['cmd'];
      if (cmd == 'set') {
        node.apply(job['key'] as String, job['value'] as int);
      } else if (cmd == 'snapshot') {
        await _motion(id, trigger: 'snapshot');
      } else if (cmd == 'reboot') {
        await _emitJson(_report(node, hello: true));
      }
      node.lastSeen = DateTime.now();
      await _emitJson({'t': 'pending', 'node': id, 'count': node.queue.length});
      await _emitJson(_report(node, hello: false));
    });
  }

  Map<String, Object?> _cancel(Map decoded) {
    final ids = _targets(decoded['node']);
    if (ids.isEmpty) return {'t': 'resp', 'cmd': 'cancel', 'ok': false, 'error': 'bad node'};
    for (final id in ids) {
      _nodes[id]!.queue.clear();
      unawaited(_emitJson({'t': 'pending', 'node': id, 'count': 0}));
    }
    return {'t': 'resp', 'cmd': 'cancel', 'ok': true};
  }

  List<int> _targets(Object? node) {
    final id = node is num ? node.toInt() : int.tryParse('$node') ?? -1;
    if (id == 0) return _nodes.keys.toList();
    if (_nodes.containsKey(id)) return [id];
    return const [];
  }

  void _setWifi(bool on) {
    _wifi = on;
    _wifiTimer?.cancel();
    if (on) {
      _wifiTimer = Timer(const Duration(minutes: 10), () {
        _wifi = false;
        _emitJson(_wifiJson());
      });
    }
  }

  Future<void> _motion(
    int id, {
    String trigger = 'pir',
    bool cameraFailed = false,
    bool noBudget = false,
  }) async {
    final node = _nodes[id];
    if (node == null) return;
    node.eventCount++;
    node.lastSeen = DateTime.now();
    final eventId = 40 + node.eventCount;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sendImage = !cameraFailed && !noBudget;
    await _emitJson({
      't': 'event',
      'node': id,
      'event_id': eventId,
      'trigger': trigger,
      'time': _timeSynced ? now : 0,
      'ir': !cameraFailed,
      'camera_failed': cameraFailed,
      'no_budget': noBudget,
      'hires_on_node': noBudget,
      'sound_peak_db': cameraFailed ? -120 : -23,
      'sound_rms_db': cameraFailed ? -120 : -41,
      'luma': 18,
      'soc': node.soc.round(),
      'width': 320,
      'height': 240,
      'img_len': sendImage ? 8000 : 0,
      'via': _wifi ? 'espnow' : 'lora',
      'rssi': node.rssi,
      'incoming_image': sendImage,
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!_running) return;
    final archived = _archived(
      node: id,
      trigger: trigger,
      ago: Duration.zero,
      full: _wifi && sendImage,
      eventId: eventId,
      cameraFailed: cameraFailed,
      noBudget: noBudget,
      withImage: sendImage,
    );
    _remember(archived);
    await _emitJson({'t': 'image', ...archived});
    if (!sendImage || _wifi) return;
    final jpeg = _jpegs[archived['seq'] as int];
    if (jpeg != null) {
      await _emitFrame(frameTypeImage, encodeImagePayload(archived['seq'] as int, false, jpeg));
    }
  }

  Map<String, Object?> _archived({
    required int node,
    required String trigger,
    required Duration ago,
    required bool full,
    int? eventId,
    bool cameraFailed = false,
    bool noBudget = false,
    bool withImage = true,
  }) {
    final seq = ++_seq;
    final stamp = DateTime.now().subtract(ago).millisecondsSinceEpoch ~/ 1000;
    Uint8List? jpeg;
    if (withImage) {
      jpeg = _photo(node: node, seq: seq, label: trigger);
      _jpegs[seq] = jpeg;
    }
    return {
      'seq': seq,
      'node': node,
      'event_id': eventId ?? (30 + seq),
      'trigger': trigger,
      'time': stamp,
      'received': stamp + 8,
      'ir': trigger == 'pir' && !cameraFailed,
      'camera_failed': cameraFailed,
      'no_budget': noBudget,
      'hires_on_node': noBudget || (withImage && !full),
      'sound_peak_db': cameraFailed ? -120 : -28,
      'sound_rms_db': cameraFailed ? -120 : -46,
      'luma': 22,
      'soc': _nodes[node]?.soc.round() ?? 70,
      'width': withImage ? 320 : 0,
      'height': withImage ? 240 : 0,
      'via': full ? 'espnow' : 'lora',
      'rssi': _nodes[node]?.rssi ?? -90,
      'image': withImage,
      'full': full,
      'bytes': jpeg?.length ?? 0,
    };
  }

  void _remember(Map<String, Object?> event) => _events.add(event);

  Map<String, Object?> _eventsJson(Map decoded) {
    final node = (decoded['node'] as num?)?.toInt() ?? 0;
    final limit = (decoded['limit'] as num?)?.toInt().clamp(1, 100) ?? 20;
    final before = (decoded['before'] as num?)?.toInt() ?? 0;
    final page = _events.where((event) {
      final seq = event['seq'] as int;
      if (before != 0 && seq >= before) return false;
      if (node > 0 && event['node'] != node) return false;
      return true;
    }).toList()
      ..sort((a, b) => (b['seq'] as int).compareTo(a['seq'] as int));
    return {'t': 'events', 'events': page.take(limit).toList()};
  }

  Map<String, Object?> _nodesJson() => {
    't': 'nodes',
    'nodes': [
      for (final node in _nodes.values)
        {
          'node': node.id,
          'age_s': max(0, DateTime.now().difference(node.lastSeen).inSeconds),
          'rssi': node.rssi,
          'snr': node.snr,
          'via': 'lora',
          'pending': node.queue.length,
          'status': node.statusJson(),
        },
    ],
  };

  Map<String, Object?> _report(_MockNode node, {required bool hello}) => {
    't': hello ? 'hello_node' : 'status',
    'node': node.id,
    'reason': hello ? 1 : 4,
    'rssi': node.rssi,
    'snr': node.snr,
    'via': 'lora',
    'status': node.statusJson(),
  };

  Map<String, Object?> _handheld() => {
    't': 'handheld',
    'fw': '1.2',
    'soc': 88.1,
    'vbat_mv': 4052,
    'charge': 'not charging',
    'ntc': 'normal',
    'wifi': _wifi,
    'time_synced': _timeSynced,
    'uptime_s': _uptime++,
    'fs_free_kb': 9400,
    'lora_budget_ms': 298211,
    'lora_ok': true,
  };

  Map<String, Object?> _wifiJson() => {
    't': 'wifi',
    'on': _wifi,
    if (_wifi) ...{
      'ssid': 'TIPTOE-HH',
      'pass': 'mock-demo',
      'ip': '192.168.4.1',
      'port': 80,
      'channel': 1,
    },
  };

  Future<void> _emitJson(Map<String, Object?> json) {
    return _emitFrame(frameTypeJson, utf8.encode(jsonEncode(json)));
  }

  Future<void> _emitFrame(int type, List<int> payload) {
    final run = _emitLock.then((_) => _writeFrame(type, payload));
    _emitLock = run.catchError((Object _) {});
    return run;
  }

  Future<void> _writeFrame(int type, List<int> payload) async {
    final frame = encodeFrame(type, payload);
    const size = 80;
    for (var i = 0; i < frame.length; i += size) {
      if (!_running) return;
      final end = min(i + size, frame.length);
      _incoming.add(frame.sublist(i, end));
      await Future<void>.delayed(const Duration(milliseconds: 6));
    }
  }

  Uint8List _photo({required int node, required int seq, required String label}) {
    final pic = im.Image(width: 320, height: 240);
    final sky = switch (node) {
      2 => im.ColorRgb8(42, 36, 28),
      3 => im.ColorRgb8(28, 32, 40),
      _ => im.ColorRgb8(24, 36, 32),
    };
    im.fill(pic, color: sky);
    im.fillRect(pic, x1: 0, y1: 150, x2: 319, y2: 239, color: im.ColorRgb8(18, 22, 20));
    im.drawString(pic, 'Node $node  #$seq', font: im.arial24, x: 16, y: 24, color: im.ColorRgb8(232, 220, 196));
    im.drawString(pic, label, font: im.arial24, x: 16, y: 64, color: im.ColorRgb8(228, 177, 90));
    return Uint8List.fromList(im.encodeJpg(pic, quality: 55));
  }
}
