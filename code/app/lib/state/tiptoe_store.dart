import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../data/photo_store.dart';
import '../data/records.dart';
import '../domain/rules.dart';
import '../link/archive_http.dart';
import '../link/frame_source.dart';
import '../link/wifi_join.dart';
import '../protocol/messages.dart';
import '../protocol/stream_parser.dart';
import '../services/handheld_service.dart';
import '../services/notification_service.dart';

class TiptoeStore extends ChangeNotifier {
  TiptoeStore({
    required this.db,
    required this.photos,
    required this.notifications,
    HandheldService? service,
  }) : service = service ?? HandheldService();

  final AppDatabase db;
  final PhotoStore photos;
  final NotificationService notifications;
  final HandheldService service;

  LinkPhase phase = LinkPhase.idle;
  String? phaseDetail;
  bool onboarded = false;
  bool useMock = false;
  bool offerGuide = false;
  String? deviceId;
  HandheldRecord? handheld;
  final nodes = <int, NodeRecord>{};
  List<EventRecord> events = [];
  WifiState? wifi;
  final log = <String>[];
  int? downloadingSeq;
  double? downloadProgress;
  int keepDays = 90;
  int quietStart = -1;
  int quietEnd = 7;
  final notifyPrefs = <int, NotifyPref>{};
  String? launchPayload;

  final _offlineNotified = <int>{};
  final _sawPending = <int>{};
  final _liveAlerts = <String, LiveEvent>{};
  final _snapshotWait = <int>{};
  String? _notice;
  Future<void> _chain = Future<void>.value();
  Timer? _presenceTimer;
  bool _ready = false;

  String? takeNotice() {
    final value = _notice;
    _notice = null;
    return value;
  }

  void notice(String message) {
    _notice = message;
    notifyListeners();
  }

  String nameOf(int nodeId) => nodes[nodeId]?.name ?? 'Node $nodeId';

  NotifyPref prefFor(int nodeId) => notifyPrefs[nodeId] ?? NotifyPref.all;

  Future<void> bootstrap() async {
    service.onPhase = (next, detail) {
      phase = next;
      phaseDetail = detail;
      if (next == LinkPhase.live || next == LinkPhase.syncing) {
        unawaited(notifications.startLinkService());
      } else if (next == LinkPhase.idle) {
        unawaited(notifications.stopLinkService());
      }
      notifyListeners();
    };
    service.onMessage = (message, raw) {
      if (raw.isNotEmpty) {
        log.insert(0, raw);
        if (log.length > 80) log.removeLast();
      }
      _chain = _chain.then((_) => _apply(message));
    };
    service.onImage = (image) {
      _chain = _chain.then((_) => _saveImage(image));
    };
    service.onProgress = (received, total) {
      if (total <= 0) return;
      downloadProgress = received / total;
      notifyListeners();
    };
    service.onLive = _onLive;
    notifications.onTap = (payload) {
      launchPayload = payload;
      notifyListeners();
    };

    onboarded = await db.setting('onboarded') == '1';
    useMock = await db.setting('use_mock') == '1';
    deviceId = await db.setting('device_id');
    keepDays = int.tryParse(await db.setting('keep_days') ?? '') ?? 90;
    quietStart = int.tryParse(await db.setting('quiet_start') ?? '') ?? -1;
    quietEnd = int.tryParse(await db.setting('quiet_end') ?? '') ?? 7;
    handheld = await db.loadHandheld();
    for (final node in await db.loadNodes()) {
      nodes[node.nodeId] = node;
      notifyPrefs[node.nodeId] = _parsePref(await db.setting('notify_${node.nodeId}'));
    }
    for (final pending in await db.loadPending()) {
      final node = nodes[pending.nodeId];
      if (node != null && pending.key != null && pending.value != null) {
        node.pendingValues[pending.key!] = pending.value!;
      }
    }
    events = await db.loadEvents();
    await _applyRetention();
    _ready = true;
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkOffline());
    notifyListeners();
    if (onboarded && (useMock || (deviceId?.isNotEmpty ?? false))) {
      await service.start(mock: useMock, deviceId: deviceId);
    }
  }

  Future<void> beginSession({required bool mock, String? bleId}) async {
    useMock = mock;
    if (bleId != null) deviceId = bleId;
    notifyListeners();
    await service.start(mock: mock, deviceId: deviceId);
  }

  Future<void> finishOnboarding({required bool mock, String? bleId, Map<int, String>? names}) async {
    useMock = mock;
    if (bleId != null) deviceId = bleId;
    onboarded = true;
    if (names != null) {
      for (final entry in names.entries) {
        final node = nodes[entry.key];
        if (node != null && entry.value.trim().isNotEmpty) node.name = entry.value.trim();
      }
    }
    await db.setSetting('onboarded', '1');
    await db.setSetting('use_mock', mock ? '1' : '0');
    await db.setSetting('device_id', deviceId);
    for (final node in nodes.values) {
      await db.saveNode(node);
    }
    offerGuide = mock;
    notifyListeners();
    if (phase == LinkPhase.idle) {
      await service.start(mock: useMock, deviceId: deviceId);
    }
  }

  Future<void> forgetHandheld() async {
    await service.stop();
    deviceId = null;
    useMock = false;
    wifi = null;
    await db.setSetting('device_id', null);
    await db.setSetting('use_mock', '0');
    phase = LinkPhase.idle;
    phaseDetail = 'Forget TIPTOE-HH in the phone’s Bluetooth settings, then pair again.';
    notifyListeners();
  }

  Future<void> connectBle(String id) async {
    deviceId = id;
    useMock = false;
    await db.setSetting('device_id', id);
    await db.setSetting('use_mock', '0');
    await service.start(mock: false, deviceId: id);
  }

  Future<void> renameNode(int nodeId, String name) async {
    final node = nodes[nodeId];
    if (node == null) return;
    node.name = name.trim().isEmpty ? 'Node $nodeId' : name.trim();
    await db.saveNode(node);
    notifyListeners();
  }

  Future<void> placeNode(int nodeId, double lat, double lng) async {
    final node = nodes[nodeId];
    if (node == null) return;
    node.lat = lat;
    node.lng = lng;
    await db.saveNode(node);
    notifyListeners();
  }

  Future<void> clearNodePlace(int nodeId) async {
    final node = nodes[nodeId];
    if (node == null) return;
    node.lat = null;
    node.lng = null;
    await db.saveNode(node);
    notifyListeners();
  }

  Future<void> setValue(int nodeId, String key, int value) async {
    final node = nodes[nodeId];
    if (node == null) return;
    node.pendingValues[key] = value;
    await db.deletePendingFor(nodeId, key: key);
    await db.addPending(PendingCommand(
      id: 0,
      nodeId: nodeId,
      cmd: 'set',
      key: key,
      value: value,
      createdAt: DateTime.now(),
    ));
    notifyListeners();
    await _send({'cmd': 'set', 'node': nodeId, 'key': key, 'value': value}, rollback: () {
      node.pendingValues.remove(key);
      unawaited(db.deletePendingFor(nodeId, key: key));
    });
  }

  Future<void> snapshot(int nodeId) async {
    _snapshotWait.add(nodeId);
    await _rememberQueued('snapshot', nodeId);
    notice('Snapshot queued for ${nameOf(nodeId)}. It arrives at the next check-in.');
  }

  Future<void> requestStatus(int nodeId) => _rememberQueued('status', nodeId);

  Future<void> reboot(int nodeId) => _rememberQueued('reboot', nodeId);

  Future<void> maintenance(int nodeId) => _rememberQueued('maintenance', nodeId);

  Future<void> clearNode(int nodeId) => _rememberQueued('clear', nodeId);

  Future<void> _rememberQueued(String cmd, int nodeId) async {
    await db.deletePendingCmd(nodeId, cmd);
    await db.addPending(PendingCommand(id: 0, nodeId: nodeId, cmd: cmd, createdAt: DateTime.now()));
    final message = await _send({'cmd': cmd, 'node': nodeId});
    if (message is CommandResponse && !message.ok) {
      await db.deletePendingCmd(nodeId, cmd);
    }
  }

  Future<void> cancelPending(int nodeId) async {
    final node = nodes[nodeId];
    node?.pendingValues.clear();
    await db.deletePendingFor(nodeId);
    notifyListeners();
    await _send({'cmd': 'cancel', 'node': nodeId});
  }

  Future<void> deleteEvent(int seq) async {
    final message = await _send({'cmd': 'delete_event', 'seq': seq});
    if (message is CommandResponse && message.ok) {
      events.removeWhere((event) => event.seq == seq);
      await db.deleteEvent(seq);
      await photos.deleteSeq(seq);
      notifyListeners();
    }
  }

  Future<void> markSeen(int seq) async {
    final index = events.indexWhere((event) => event.seq == seq);
    if (index < 0 || events[index].seen) return;
    events[index] = events[index].copyWith(seen: true);
    await db.updateEvent(events[index]);
    notifyListeners();
  }

  Future<void> fetchFullBle(int seq) async {
    downloadingSeq = seq;
    downloadProgress = 0;
    notifyListeners();
    final message = await _send(
      {'cmd': 'get_image', 'seq': seq, 'full': true},
      timeout: const Duration(seconds: 30),
    );
    if (message is CommandResponse && !message.ok) {
      notice(message.error ?? 'No full-resolution photo on the handheld.');
    }
    downloadingSeq = null;
    notifyListeners();
  }

  Future<void> fetchFullWifi(int seq) async {
    var ssid = wifi?.ssid;
    try {
      if (wifi?.on != true) {
        await _send({'cmd': 'wifi', 'on': true});
        await _chain;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final info = wifi;
      ssid = info?.ssid;
      if (info == null || !info.on || info.ssid == null || info.password == null) {
        notice('The handheld did not share a Wi-Fi network.');
        return;
      }
      final joined = await WifiJoin.join(ssid: info.ssid!, password: info.password!);
      if (!joined) {
        notice('Join ${info.ssid} from the phone’s Wi-Fi settings, then download again.');
        return;
      }
      final bytes = await ArchiveHttp(host: info.ip ?? '192.168.4.1').image(seq: seq, full: true);
      await _saveJpeg(seq, bytes, full: true);
      notice('Full-resolution photo saved.');
    } on CommandException catch (error) {
      notice(error.message);
    } finally {
      await WifiJoin.leave(ssid: ssid);
      await _send({'cmd': 'wifi', 'on': false});
    }
  }

  Future<void> setNearMode(bool on) async {
    await _send({'cmd': 'wifi', 'on': on});
  }

  bool consumeGuide() {
    final open = offerGuide;
    offerGuide = false;
    return open;
  }

  void runScenario(String name) {
    if (useMock) service.runScenario(name);
  }

  Future<void> leaveSimulation() async {
    await service.stop();
    useMock = false;
    onboarded = false;
    offerGuide = false;
    wifi = null;
    await db.setSetting('use_mock', '0');
    await db.setSetting('onboarded', '0');
    phase = LinkPhase.idle;
    phaseDetail = null;
    notifyListeners();
  }

  void simulateMotion() => service.simulateMotion();

  Future<void> setPref(int nodeId, NotifyPref pref) async {
    notifyPrefs[nodeId] = pref;
    await db.setSetting('notify_$nodeId', pref.name);
    notifyListeners();
  }

  Future<void> setRetention(int days) async {
    keepDays = days;
    await db.setSetting('keep_days', '$days');
    await _applyRetention();
    notifyListeners();
  }

  Future<void> setQuietHours(int start, int end) async {
    quietStart = start;
    quietEnd = end;
    await db.setSetting('quiet_start', '$start');
    await db.setSetting('quiet_end', '$end');
    notifyListeners();
  }

  Future<File> exportFile() async {
    final file = File('${photos.directory.path}/tiptoe-export.json');
    final payload = {
      'exported': DateTime.now().toIso8601String(),
      'nodes': {
        for (final node in nodes.values) '${node.nodeId}': node.name,
      },
      'events': [
        for (final event in events)
          {
            'seq': event.seq,
            'node': event.nodeId,
            'event_id': event.eventId,
            'trigger': event.trigger,
            'time': event.time,
            'received': event.received,
            'via': event.via,
            'phone_only': event.phoneOnly,
          },
      ],
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    return file;
  }

  Future<void> _onLive() async {
    await _send({
      'cmd': 'time',
      'unix': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    await _chain;
    await _resendLost(oneShots: false);
    await _catchUp();
    await _fetchThumbs();
  }

  Future<void> _catchUp() async {
    final floor = events.fold<int>(0, (maxSeq, event) => event.seq > maxSeq ? event.seq : maxSeq);
    final seen = <int>{};
    int? before;
    var exhausted = false;
    while (true) {
      final body = <String, Object?>{'cmd': 'events', 'limit': 50};
      if (before != null) body['before'] = before;
      final message = await _send(body, quiet: true);
      if (message is! EventsMessage || message.events.isEmpty) {
        exhausted = message is EventsMessage;
        break;
      }
      var allNew = true;
      var oldest = message.events.first.seq;
      for (final event in message.events) {
        seen.add(event.seq);
        if (event.seq <= floor) allNew = false;
        if (event.seq < oldest) oldest = event.seq;
      }
      await _chain;
      if (message.events.length < 50) {
        exhausted = true;
        break;
      }
      if (!allNew) break;
      before = oldest;
    }
    if (exhausted) {
      await db.markPhoneOnlyExcept(seen);
      events = await db.loadEvents();
      notifyListeners();
    }
  }

  Future<void> _fetchThumbs() async {
    final missing = events.where((event) => event.hasImage && event.smallPath == null).take(20);
    for (final event in missing) {
      downloadingSeq = event.seq;
      notifyListeners();
      await _send(
        {'cmd': 'get_image', 'seq': event.seq, 'full': false},
        timeout: const Duration(seconds: 30),
        quiet: true,
      );
      await _chain;
    }
    downloadingSeq = null;
    downloadProgress = null;
    notifyListeners();
  }

  Future<void> _resendLost({required bool oneShots}) async {
    final pending = await db.loadPending();
    for (final command in pending) {
      final node = nodes[command.nodeId];
      if (node == null || node.pendingCount > 0) continue;
      if (command.key != null && node.config[command.key] == command.value) {
        node.pendingValues.remove(command.key);
        await db.deletePendingFor(command.nodeId, key: command.key);
        continue;
      }
      if (command.cmd == 'set' && command.key != null && command.value != null) {
        await _send({'cmd': 'set', 'node': command.nodeId, 'key': command.key, 'value': command.value});
      } else if (oneShots && command.cmd != 'set') {
        await _send({'cmd': command.cmd, 'node': command.nodeId});
      }
    }
  }

  Future<AppMessage?> _send(
    Map<String, Object?> body, {
    Duration? timeout,
    void Function()? rollback,
    bool quiet = false,
  }) async {
    try {
      final message = await service.command(body, timeout: timeout);
      if (message is CommandResponse && !message.ok) {
        rollback?.call();
        if (!quiet) notice(message.error ?? 'The handheld rejected ${body['cmd']}.');
      }
      return message;
    } on CommandException catch (error) {
      if (!quiet) notice(error.message);
      return null;
    }
  }

  Future<void> _apply(AppMessage message) async {
    switch (message) {
      case HandheldState():
        await _applyHandheld(message);
      case WifiState():
        wifi = message;
      case NodesMessage():
        for (final summary in message.nodes) {
          _applySummary(summary);
          await db.saveNode(nodes[summary.node]!);
        }
        _checkOffline();
      case NodeReport():
        final node = _touch(message.node);
        node.lastSeen = DateTime.now();
        if (message.rssi != null) node.rssi = message.rssi;
        if (message.snr != null) node.snr = message.snr;
        if (message.via != null) node.via = message.via;
        _applyStatus(node, message.status);
        if (message.hello) _note(node, 'Restarted');
        await db.saveNode(node);
        _checkOffline();
      case PendingMessage():
        final node = _touch(message.node);
        node.pendingCount = message.count;
        if (message.count > 0) _sawPending.add(message.node);
        await db.saveNode(node);
      case LiveEvent():
        await _applyLive(message);
      case ArchiveEvent():
        await _upsertArchive(message, seen: false);
      case EventsMessage():
        for (final event in message.events) {
          await _upsertArchive(event, seen: true);
        }
      case WarningMessage():
        await notifications.showWarning(message.message);
        notice(message.message);
      case CommandResponse():
      case UnknownMessage():
        break;
    }
    if (_ready) notifyListeners();
  }

  Future<void> _applyHandheld(HandheldState message) async {
    final previous = handheld?.uptimeS;
    final rebooted = previous != null && message.uptimeS != null && message.uptimeS! + 5 < previous;
    handheld = HandheldRecord(
      fw: message.fw,
      soc: message.soc,
      vbatMv: message.vbatMv,
      charge: message.charge,
      ntc: message.ntc,
      wifi: message.wifi,
      timeSynced: message.timeSynced,
      uptimeS: message.uptimeS,
      fsFreeKb: message.fsFreeKb,
      loraBudgetMs: message.loraBudgetMs,
      loraOk: message.loraOk,
      updatedAt: DateTime.now(),
    );
    await db.saveHandheld(handheld!);
    if (rebooted) {
      notice('The handheld restarted. Queued commands are being sent again.');
      await _resendLost(oneShots: true);
    }
  }

  void _applySummary(NodeSummary summary) {
    final node = _touch(summary.node);
    if (summary.ageS != null && summary.ageS! >= 0) {
      node.lastSeen = DateTime.now().subtract(Duration(seconds: summary.ageS!));
    }
    node.rssi = summary.rssi ?? node.rssi;
    node.snr = summary.snr ?? node.snr;
    node.via = summary.via ?? node.via;
    node.pendingCount = summary.pending;
    if (summary.pending > 0) _sawPending.add(summary.node);
    _applyStatus(node, summary.status);
  }

  void _applyStatus(NodeRecord node, NodeStatus? status) {
    if (status == null) return;
    node.fw = status.fw ?? node.fw;
    node.soc = status.soc ?? node.soc;
    node.vbatMv = status.vbatMv ?? node.vbatMv;
    node.charge = status.charge ?? node.charge;
    node.ntc = status.ntc ?? node.ntc;
    node.qiMv = status.qiMv ?? node.qiMv;
    node.tempC = status.tempC ?? node.tempC;
    node.eventCount = status.eventCount ?? node.eventCount;
    node.fsFreeKb = status.fsFreeKb ?? node.fsFreeKb;
    node.uptimeS = status.uptimeS ?? node.uptimeS;
    node.hwOk = status.hwOk ?? node.hwOk;
    if (status.config.isNotEmpty) {
      node.config
        ..clear()
        ..addAll(status.config);
    }
        if (node.pendingCount == 0 && _sawPending.remove(node.nodeId)) {
          final keys = node.pendingValues.keys.toList();
          for (final key in keys) {
            final wanted = node.pendingValues[key];
            final actual = node.config[key];
            if (actual == null || actual == wanted) {
              node.pendingValues.remove(key);
              unawaited(db.deletePendingFor(node.nodeId, key: key));
            } else {
              node.pendingValues.remove(key);
              unawaited(db.deletePendingFor(node.nodeId, key: key));
              notice('${node.name}: $key is still $actual');
            }
          }
          unawaited(db.deletePendingOps(node.nodeId));
        } else {
      for (final key in node.pendingValues.keys.toList()) {
        if (node.config[key] == node.pendingValues[key]) {
          node.pendingValues.remove(key);
          unawaited(db.deletePendingFor(node.nodeId, key: key));
        }
      }
    }
  }

  Future<void> _applyLive(LiveEvent event) async {
    final node = _touch(event.node);
    if (event.trigger == 'pir') node.motionAt = DateTime.now();
    if (event.trigger == 'snapshot' && _snapshotWait.remove(event.node)) {
      notice('Snapshot from ${node.name} arrived');
    }
    _liveAlerts['${event.node}:${event.eventId}'] = event;
    await db.saveNode(node);
    await _notify(event, seq: null, imagePath: null);
    _checkOffline();
  }

  Future<void> _upsertArchive(ArchiveEvent event, {required bool seen}) async {
    final record = EventRecord(
      seq: event.seq,
      nodeId: event.node,
      eventId: event.eventId,
      trigger: event.trigger,
      time: event.time,
      received: event.received,
      ir: event.ir,
      soundPeakDb: event.soundPeakDb,
      soundRmsDb: event.soundRmsDb,
      luma: event.luma,
      soc: event.soc,
      width: event.width,
      height: event.height,
      via: event.via,
      rssi: event.rssi,
      hasImage: event.hasImage,
      full: event.full,
      bytes: event.bytes,
      smallPath: null,
      fullPath: null,
      audioPath: null,
      hiresOnNode: event.hiresOnNode,
      cameraFailed: event.cameraFailed,
      noBudget: event.noBudget,
      seen: seen,
      phoneOnly: false,
    );
    await db.upsertEvent(record);
    final stored = await db.loadEvent(event.seq);
    if (stored == null) return;
    final index = events.indexWhere((item) => item.seq == event.seq);
    if (index >= 0) {
      events[index] = stored;
    } else {
      events.insert(0, stored);
      events.sort((a, b) => b.seq.compareTo(a.seq));
    }
  }

  Future<void> _saveImage(ImagePayload image) async {
    await _saveJpeg(image.seq, image.jpeg, full: image.full);
    final index = events.indexWhere((event) => event.seq == image.seq);
    if (index < 0) return;
    final event = events[index];
    final live = _liveAlerts['${event.nodeId}:${event.eventId}'];
    if (live != null && !image.full) {
      await _notify(live, seq: event.seq, imagePath: event.smallPath);
    }
    if (downloadingSeq == image.seq) {
      downloadingSeq = null;
      downloadProgress = null;
    }
  }

  Future<void> _saveJpeg(int seq, Uint8List jpeg, {required bool full}) async {
    if (jpeg.isEmpty) return;
    final path = await photos.saveJpeg(seq, jpeg, full: full);
    final index = events.indexWhere((event) => event.seq == seq);
    if (index < 0) return;
    final updated = full ? events[index].copyWith(fullPath: path, full: true) : events[index].copyWith(smallPath: path);
    events[index] = updated;
    await db.updateEvent(updated);
    if (_ready) notifyListeners();
  }

  Future<void> _notify(LiveEvent event, {required int? seq, required String? imagePath}) async {
    final quiet = inQuietHours(DateTime.now(), quietStart, quietEnd);
    if (!shouldNotify(pref: prefFor(event.node), trigger: event.trigger, quiet: false)) return;
    if (prefFor(event.node) == NotifyPref.none) return;
    await notifications.showAlert(
      nodeId: event.node,
      eventId: event.eventId,
      nodeName: nameOf(event.node),
      trigger: event.trigger,
      cameraFailed: event.cameraFailed,
      noBudget: event.noBudget,
      ir: event.ir,
      soundPeakDb: event.soundPeakDb,
      imagePath: imagePath,
      quiet: quiet,
      payload: seq == null ? 'node:${event.node}:event:${event.eventId}' : 'seq:$seq',
    );
  }

  void _checkOffline() {
    final now = DateTime.now();
    for (final node in nodes.values) {
      final presence = presenceOf(ageSeconds: node.ageSeconds(now), heartbeatMin: node.heartbeatMin);
      if (presence == Presence.offline) {
        if (_offlineNotified.add(node.nodeId)) {
          unawaited(notifications.showWarning(
            '${node.name} has missed several check-ins.',
            title: '${node.name} offline',
            id: 800000 + node.nodeId,
          ));
        }
      } else if (presence == Presence.online) {
        _offlineNotified.remove(node.nodeId);
      }
    }
  }

  Future<void> _applyRetention() async {
    if (keepDays <= 0) return;
    final cutoff = DateTime.now().subtract(Duration(days: keepDays)).millisecondsSinceEpoch ~/ 1000;
    final doomed = events.where((event) {
      final stamp = event.time > 0 ? event.time : event.received;
      return stamp > 0 && stamp < cutoff;
    }).toList();
    for (final event in doomed) {
      events.remove(event);
      await db.deleteEvent(event.seq);
      await photos.deleteSeq(event.seq);
    }
  }

  NodeRecord _touch(int id) {
    return nodes.putIfAbsent(id, () {
      notifyPrefs[id] = NotifyPref.all;
      return NodeRecord(nodeId: id, name: 'Node $id');
    });
  }

  void _note(NodeRecord node, String text) {
    node.notes.insert(0, text);
    if (node.notes.length > 8) node.notes.removeLast();
  }

  NotifyPref _parsePref(String? value) {
    switch (value) {
      case 'motion':
        return NotifyPref.motion;
      case 'none':
        return NotifyPref.none;
      default:
        return NotifyPref.all;
    }
  }

  Future<void> attachImport(int seq, Uint8List bytes, {required bool full}) {
    return _saveJpeg(seq, bytes, full: full);
  }

  Future<void> attachAudio(int seq, List<int> bytes) async {
    final path = await photos.saveBytes('e$seq.wav', bytes);
    final index = events.indexWhere((event) => event.seq == seq);
    if (index < 0) return;
    events[index] = events[index].copyWith(audioPath: path);
    await db.updateEvent(events[index]);
    notifyListeners();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    unawaited(service.stop());
    super.dispose();
  }
}
