class HandheldRecord {
  const HandheldRecord({
    this.fw,
    this.soc,
    this.vbatMv,
    this.charge,
    this.ntc,
    this.wifi = false,
    this.timeSynced = false,
    this.uptimeS,
    this.fsFreeKb,
    this.loraBudgetMs,
    this.loraOk = true,
    this.updatedAt,
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
  final DateTime? updatedAt;
}

class NodeRecord {
  NodeRecord({
    required this.nodeId,
    required this.name,
    this.lastSeen,
    this.rssi,
    this.snr,
    this.via,
    this.soc,
    this.vbatMv,
    this.charge,
    this.ntc,
    this.tempC,
    this.qiMv,
    this.hwOk,
    this.fw,
    this.eventCount,
    this.fsFreeKb,
    this.uptimeS,
    this.pendingCount = 0,
    this.lat,
    this.lng,
    Map<String, int>? config,
    Map<String, int>? pendingValues,
    List<String>? notes,
    this.motionAt,
  }) : config = config ?? {},
       pendingValues = pendingValues ?? {},
       notes = notes ?? [];

  final int nodeId;
  String name;
  DateTime? lastSeen;
  double? rssi;
  double? snr;
  String? via;
  double? soc;
  int? vbatMv;
  String? charge;
  String? ntc;
  int? tempC;
  int? qiMv;
  int? hwOk;
  String? fw;
  int? eventCount;
  int? fsFreeKb;
  int? uptimeS;
  int pendingCount;
  double? lat;
  double? lng;
  final Map<String, int> config;
  final Map<String, int> pendingValues;
  final List<String> notes;
  DateTime? motionAt;

  int get heartbeatMin => config['heartbeat_min'] ?? 30;

  int? ageSeconds(DateTime now) {
    final seen = lastSeen;
    if (seen == null) return null;
    return now.difference(seen).inSeconds;
  }
}

class EventRecord {
  const EventRecord({
    required this.seq,
    required this.nodeId,
    required this.eventId,
    required this.trigger,
    required this.time,
    required this.received,
    required this.ir,
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
    required this.smallPath,
    required this.fullPath,
    required this.audioPath,
    required this.hiresOnNode,
    required this.cameraFailed,
    required this.noBudget,
    required this.seen,
    required this.phoneOnly,
  });

  final int seq;
  final int nodeId;
  final int? eventId;
  final String trigger;
  final int time;
  final int received;
  final bool ir;
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
  final String? smallPath;
  final String? fullPath;
  final String? audioPath;
  final bool hiresOnNode;
  final bool cameraFailed;
  final bool noBudget;
  final bool seen;
  final bool phoneOnly;

  EventRecord copyWith({
    String? smallPath,
    String? fullPath,
    String? audioPath,
    bool? seen,
    bool? phoneOnly,
    bool? full,
    bool clearSmall = false,
    bool clearFull = false,
  }) {
    return EventRecord(
      seq: seq,
      nodeId: nodeId,
      eventId: eventId,
      trigger: trigger,
      time: time,
      received: received,
      ir: ir,
      soundPeakDb: soundPeakDb,
      soundRmsDb: soundRmsDb,
      luma: luma,
      soc: soc,
      width: width,
      height: height,
      via: via,
      rssi: rssi,
      hasImage: hasImage,
      full: full ?? this.full,
      bytes: bytes,
      smallPath: clearSmall ? null : (smallPath ?? this.smallPath),
      fullPath: clearFull ? null : (fullPath ?? this.fullPath),
      audioPath: audioPath ?? this.audioPath,
      hiresOnNode: hiresOnNode,
      cameraFailed: cameraFailed,
      noBudget: noBudget,
      seen: seen ?? this.seen,
      phoneOnly: phoneOnly ?? this.phoneOnly,
    );
  }
}

class PendingCommand {
  const PendingCommand({
    required this.id,
    required this.nodeId,
    required this.cmd,
    this.key,
    this.value,
    required this.createdAt,
  });

  final int id;
  final int nodeId;
  final String cmd;
  final String? key;
  final int? value;
  final DateTime createdAt;
}
