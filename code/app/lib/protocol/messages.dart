import 'dart:convert';

import 'json_read.dart';

/// One JSON object from a type-1 frame. `rid` is echoed on command replies.
sealed class AppMessage {
  const AppMessage({this.rid});

  final int? rid;

  static AppMessage parse(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return UnknownMessage(raw: raw);
    return fromJson(asMap(decoded), raw: raw);
  }

  static AppMessage fromJson(Map<String, Object?> json, {String? raw}) {
    final rid = asInt(json['rid']);
    switch (json['t']) {
      case 'event':
        return LiveEvent.fromJson(json, rid: rid);
      case 'image':
        return ArchiveEvent.fromJson(json, rid: rid);
      case 'status':
      case 'hello_node':
        return NodeReport.fromJson(json, rid: rid);
      case 'nodes':
        return NodesMessage.fromJson(json, rid: rid);
      case 'events':
        return EventsMessage.fromJson(json, rid: rid);
      case 'pending':
        return PendingMessage.fromJson(json, rid: rid);
      case 'handheld':
        return HandheldState.fromJson(json, rid: rid);
      case 'wifi':
        return WifiState.fromJson(json, rid: rid);
      case 'resp':
        return CommandResponse.fromJson(json, rid: rid);
      case 'warning':
        return WarningMessage(json['msg']?.toString() ?? 'Handheld warning', rid: rid);
      default:
        return UnknownMessage(raw: raw ?? jsonEncode(json), rid: rid);
    }
  }
}

class UnknownMessage extends AppMessage {
  const UnknownMessage({required this.raw, super.rid});
  final String raw;
}

class WarningMessage extends AppMessage {
  const WarningMessage(this.message, {super.rid});
  final String message;
}

class CommandResponse extends AppMessage {
  const CommandResponse({
    required this.cmd,
    required this.ok,
    this.error,
    this.queuedFor,
    this.bytes,
    this.url,
    super.rid,
  });

  final String cmd;
  final bool ok;
  final String? error;
  final int? queuedFor;
  final int? bytes;
  final String? url;

  factory CommandResponse.fromJson(Map<String, Object?> json, {int? rid}) {
    return CommandResponse(
      cmd: json['cmd']?.toString() ?? '',
      ok: asBool(json['ok']),
      error: json['error']?.toString(),
      queuedFor: asInt(json['queued_for']),
      bytes: asInt(json['bytes']),
      url: json['url']?.toString(),
      rid: rid,
    );
  }
}

class HandheldState extends AppMessage {
  const HandheldState({
    required this.fw,
    required this.soc,
    required this.vbatMv,
    required this.charge,
    required this.ntc,
    required this.wifi,
    required this.timeSynced,
    required this.uptimeS,
    required this.fsFreeKb,
    required this.loraBudgetMs,
    required this.loraOk,
    super.rid,
  });

  final String? fw;
  final double? soc;
  final int? vbatMv;
  final String? charge;
  final String? ntc;
  final bool wifi;
  final bool timeSynced;
  final int? uptimeS;
  final int? fsFreeKb;
  final int? loraBudgetMs;
  final bool loraOk;

  factory HandheldState.fromJson(Map<String, Object?> json, {int? rid}) {
    return HandheldState(
      fw: json['fw']?.toString(),
      soc: asDouble(json['soc']),
      vbatMv: asInt(json['vbat_mv']),
      charge: json['charge']?.toString(),
      ntc: json['ntc']?.toString(),
      wifi: asBool(json['wifi']),
      timeSynced: asBool(json['time_synced']),
      uptimeS: asInt(json['uptime_s']),
      fsFreeKb: asInt(json['fs_free_kb']),
      loraBudgetMs: asInt(json['lora_budget_ms']),
      loraOk: json['lora_ok'] == null ? true : asBool(json['lora_ok']),
      rid: rid,
    );
  }
}

class WifiState extends AppMessage {
  const WifiState({
    required this.on,
    this.ssid,
    this.password,
    this.ip,
    this.port,
    this.channel,
    super.rid,
  });

  final bool on;
  final String? ssid;
  final String? password;
  final String? ip;
  final int? port;
  final int? channel;

  factory WifiState.fromJson(Map<String, Object?> json, {int? rid}) {
    return WifiState(
      on: asBool(json['on']),
      ssid: json['ssid']?.toString(),
      password: json['pass']?.toString(),
      ip: json['ip']?.toString(),
      port: asInt(json['port']),
      channel: asInt(json['channel']),
      rid: rid,
    );
  }
}

class PendingMessage extends AppMessage {
  const PendingMessage({required this.node, required this.count, super.rid});
  final int node;
  final int count;

  factory PendingMessage.fromJson(Map<String, Object?> json, {int? rid}) {
    return PendingMessage(node: asInt(json['node']) ?? 0, count: asInt(json['count']) ?? 0, rid: rid);
  }
}

/// Motion / snapshot / button alert. Arrives before the photo.
class LiveEvent extends AppMessage {
  const LiveEvent({
    required this.node,
    required this.eventId,
    required this.trigger,
    required this.time,
    required this.ir,
    required this.cameraFailed,
    required this.noBudget,
    required this.hiresOnNode,
    required this.soundPeakDb,
    required this.soundRmsDb,
    required this.luma,
    required this.soc,
    required this.width,
    required this.height,
    required this.imgLen,
    required this.via,
    required this.rssi,
    required this.incomingImage,
    super.rid,
  });

  final int node;
  final int eventId;
  final String trigger;
  final int time;
  final bool ir;
  final bool cameraFailed;
  final bool noBudget;
  final bool hiresOnNode;
  final int? soundPeakDb;
  final int? soundRmsDb;
  final int? luma;
  final int? soc;
  final int? width;
  final int? height;
  final int? imgLen;
  final String? via;
  final double? rssi;
  final bool incomingImage;

  factory LiveEvent.fromJson(Map<String, Object?> json, {int? rid}) {
    return LiveEvent(
      node: asInt(json['node']) ?? 0,
      eventId: asInt(json['event_id']) ?? 0,
      trigger: json['trigger']?.toString() ?? 'pir',
      time: asInt(json['time']) ?? 0,
      ir: asBool(json['ir']),
      cameraFailed: asBool(json['camera_failed']),
      noBudget: asBool(json['no_budget']),
      hiresOnNode: asBool(json['hires_on_node']),
      soundPeakDb: asInt(json['sound_peak_db']),
      soundRmsDb: asInt(json['sound_rms_db']),
      luma: asInt(json['luma']),
      soc: asInt(json['soc']),
      width: asInt(json['width']),
      height: asInt(json['height']),
      imgLen: asInt(json['img_len']),
      via: json['via']?.toString(),
      rssi: asDouble(json['rssi']),
      incomingImage: asBool(json['incoming_image']),
      rid: rid,
    );
  }
}

/// One archived event. `seq` is the handheld archive id and the phone's key.
class ArchiveEvent extends AppMessage {
  const ArchiveEvent({
    required this.seq,
    required this.node,
    required this.eventId,
    required this.trigger,
    required this.time,
    required this.received,
    required this.ir,
    required this.cameraFailed,
    required this.noBudget,
    required this.hiresOnNode,
    required this.soundPeakDb,
    required this.soundRmsDb,
    required this.luma,
    required this.soc,
    required this.width,
    required this.height,
    required this.via,
    required this.rssi,
    required this.hasImage,
    required this.full,
    required this.bytes,
    super.rid,
  });

  final int seq;
  final int node;
  final int? eventId;
  final String trigger;
  final int time;
  final int received;
  final bool ir;
  final bool cameraFailed;
  final bool noBudget;
  final bool hiresOnNode;
  final int? soundPeakDb;
  final int? soundRmsDb;
  final int? luma;
  final int? soc;
  final int? width;
  final int? height;
  final String? via;
  final double? rssi;
  final bool hasImage;
  final bool full;
  final int bytes;

  factory ArchiveEvent.fromJson(Map<String, Object?> json, {int? rid}) {
    return ArchiveEvent(
      seq: asInt(json['seq']) ?? 0,
      node: asInt(json['node']) ?? 0,
      eventId: asInt(json['event_id']),
      trigger: json['trigger']?.toString() ?? 'pir',
      time: asInt(json['time']) ?? 0,
      received: asInt(json['received']) ?? 0,
      ir: asBool(json['ir']),
      cameraFailed: asBool(json['camera_failed']),
      noBudget: asBool(json['no_budget']),
      hiresOnNode: asBool(json['hires_on_node']),
      soundPeakDb: asInt(json['sound_peak_db']),
      soundRmsDb: asInt(json['sound_rms_db']),
      luma: asInt(json['luma']),
      soc: asInt(json['soc']),
      width: asInt(json['width']),
      height: asInt(json['height']),
      via: json['via']?.toString(),
      rssi: asDouble(json['rssi']),
      hasImage: asBool(json['image']) || asBool(json['has_image']),
      full: asBool(json['full']),
      bytes: asInt(json['bytes']) ?? 0,
      rid: rid,
    );
  }
}

class NodeStatus {
  const NodeStatus({
    required this.fw,
    required this.armed,
    required this.soc,
    required this.vbatMv,
    required this.charge,
    required this.ntc,
    required this.qiMv,
    required this.tempC,
    required this.eventCount,
    required this.uptimeS,
    required this.fsFreeKb,
    required this.hwOk,
    required this.config,
    required this.raw,
  });

  final String? fw;
  final int? armed;
  final double? soc;
  final int? vbatMv;
  final String? charge;
  final String? ntc;
  final int? qiMv;
  final int? tempC;
  final int? eventCount;
  final int? uptimeS;
  final int? fsFreeKb;
  final int? hwOk;
  final Map<String, int> config;
  final Map<String, Object?> raw;

  factory NodeStatus.fromJson(Map<String, Object?> json) {
    final config = <String, int>{};
    for (final entry in asMap(json['config']).entries) {
      final value = asInt(entry.value);
      if (value != null) config[entry.key] = value;
    }
    if (json['armed'] != null && !config.containsKey('armed')) {
      final armed = asInt(json['armed']);
      if (armed != null) config['armed'] = armed;
    }
    return NodeStatus(
      fw: json['fw']?.toString(),
      armed: asInt(json['armed']),
      soc: asDouble(json['soc']),
      vbatMv: asInt(json['vbat_mv']),
      charge: json['charge']?.toString(),
      ntc: json['ntc']?.toString(),
      qiMv: asInt(json['qi_mv']),
      tempC: asInt(json['temp_c']),
      eventCount: asInt(json['event_count']),
      uptimeS: asInt(json['uptime_s']),
      fsFreeKb: asInt(json['fs_free_kb']),
      hwOk: asInt(json['hw_ok']),
      config: config,
      raw: json,
    );
  }
}

class NodeSummary {
  const NodeSummary({
    required this.node,
    required this.ageS,
    required this.rssi,
    required this.snr,
    required this.via,
    required this.pending,
    required this.status,
  });

  final int node;
  final int? ageS;
  final double? rssi;
  final double? snr;
  final String? via;
  final int pending;
  final NodeStatus? status;

  factory NodeSummary.fromJson(Map<String, Object?> json) {
    final statusRaw = json['status'];
    return NodeSummary(
      node: asInt(json['node']) ?? 0,
      ageS: asInt(json['age_s']),
      rssi: asDouble(json['rssi']),
      snr: asDouble(json['snr']),
      via: json['via']?.toString(),
      pending: asInt(json['pending']) ?? 0,
      status: statusRaw is Map ? NodeStatus.fromJson(asMap(statusRaw)) : null,
    );
  }
}

class NodesMessage extends AppMessage {
  const NodesMessage({required this.nodes, super.rid});
  final List<NodeSummary> nodes;

  factory NodesMessage.fromJson(Map<String, Object?> json, {int? rid}) {
    final list = json['nodes'];
    final nodes = <NodeSummary>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) nodes.add(NodeSummary.fromJson(asMap(item)));
      }
    }
    return NodesMessage(nodes: nodes, rid: rid);
  }
}

class NodeReport extends AppMessage {
  const NodeReport({
    required this.hello,
    required this.node,
    required this.rssi,
    required this.snr,
    required this.via,
    required this.status,
    super.rid,
  });

  final bool hello;
  final int node;
  final double? rssi;
  final double? snr;
  final String? via;
  final NodeStatus? status;

  factory NodeReport.fromJson(Map<String, Object?> json, {int? rid}) {
    final statusRaw = json['status'];
    return NodeReport(
      hello: json['t'] == 'hello_node',
      node: asInt(json['node']) ?? 0,
      rssi: asDouble(json['rssi']),
      snr: asDouble(json['snr']),
      via: json['via']?.toString(),
      status: statusRaw is Map ? NodeStatus.fromJson(asMap(statusRaw)) : null,
      rid: rid,
    );
  }
}

class EventsMessage extends AppMessage {
  const EventsMessage({required this.events, super.rid});
  final List<ArchiveEvent> events;

  factory EventsMessage.fromJson(Map<String, Object?> json, {int? rid}) {
    final list = json['events'];
    final events = <ArchiveEvent>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) events.add(ArchiveEvent.fromJson(asMap(item)));
      }
    }
    return EventsMessage(events: events, rid: rid);
  }
}
