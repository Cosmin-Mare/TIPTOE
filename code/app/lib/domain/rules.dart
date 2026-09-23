import '../protocol/messages.dart';

/// Outdoor nodes sleep. A command waits until the next heartbeat or motion.
enum Presence { online, late, offline, unknown }

enum NotifyPref { all, motion, none }

/// Online while `age < heartbeat × 2.5 + 60s`. Offline after 4 missed heartbeats.
Presence presenceOf({required int? ageSeconds, required int heartbeatMin}) {
  if (ageSeconds == null || ageSeconds < 0) return Presence.unknown;
  final heartbeat = heartbeatMin <= 0 ? 30 : heartbeatMin;
  final onlineLimit = (heartbeat * 60 * 2.5 + 60).round();
  if (ageSeconds < onlineLimit) return Presence.online;
  if (ageSeconds >= heartbeat * 60 * 4) return Presence.offline;
  return Presence.late;
}

String presenceLabel(Presence presence) {
  switch (presence) {
    case Presence.online:
      return 'Online';
    case Presence.late:
      return 'Late';
    case Presence.offline:
      return 'Offline';
    case Presence.unknown:
      return 'Not seen';
  }
}

/// 3 bars at ≥ −90 dBm, 2 down to −110, 1 below that.
int signalBars(double? rssi) {
  if (rssi == null) return 0;
  if (rssi >= -90) return 3;
  if (rssi >= -110) return 2;
  return 1;
}

bool isCharging(String? charge, {int? qiMv}) {
  final active = charge == 'pre-charge' || charge == 'fast charging' || charge == 'fast-charge';
  if (!active) return false;
  // A dropped camera is on its battery. Charging only counts on a Qi pad.
  return qiMv != null && qiMv > 4000;
}

/// `last_seen + heartbeat − now`. Motion keeps the next delivery inside a minute.
String pendingEta({
  required DateTime? lastSeen,
  required int heartbeatMin,
  required bool motionLikely,
  DateTime? now,
}) {
  if (motionLikely) return 'Applies at next check-in, within 1 min';
  if (lastSeen == null) return 'Applies at the next check-in';
  final heartbeat = heartbeatMin <= 0 ? 30 : heartbeatMin;
  final due = lastSeen.add(Duration(minutes: heartbeat));
  final left = due.difference(now ?? DateTime.now());
  if (left.inSeconds <= 60) return 'Applies at next check-in, within 1 min';
  final minutes = left.inMinutes;
  if (minutes < 60) return 'Applies at next check-in, ≈ $minutes min';
  final hours = (minutes / 60).round();
  return 'Applies at next check-in, ≈ $hours h';
}

class HealthNote {
  const HealthNote(this.message, {this.critical = false, this.info = false});
  final String message;
  final bool critical;
  final bool info;
}

const int hwExpander = 1;
const int hwCharger = 2;
const int hwGauge = 4;
const int hwCamera = 8;
const int hwMic = 16;
const int hwCamPower = 32;
const int hwFlash = 64;
const int hwBoard = hwExpander | hwCharger | hwGauge | hwFlash;

List<HealthNote> healthNotes({
  double? soc,
  String? charge,
  String? ntc,
  int? qiMv,
  int? hwOk,
  int? fsFreeKb,
  double? rssi,
  double? snr,
}) {
  final notes = <HealthNote>[];
  final charging = isCharging(charge, qiMv: qiMv);
  if (soc != null && soc < 5) {
    notes.add(const HealthNote('Battery critical — node has stopped watching', critical: true));
    notes.add(const HealthNote('Check-ins slow to about every 3 hours'));
  } else if (soc != null && soc < 20 && !charging) {
    notes.add(const HealthNote('Battery low'));
  }
  if (qiMv != null && qiMv > 4000) {
    switch (ntc) {
      case 'cold':
        notes.add(const HealthNote('Too cold to charge — charging paused'));
      case 'hot':
        notes.add(const HealthNote('Too hot to charge — charging paused'));
      case 'warm':
      case 'cool':
        notes.add(const HealthNote('Charging at a reduced rate (temperature)'));
      default:
        break;
    }
    notes.add(const HealthNote('On the Qi pad', info: true));
  }
  if (hwOk != null) {
    if ((hwOk & hwCamera) == 0) notes.add(const HealthNote('Camera problem'));
    if ((hwOk & hwMic) == 0) notes.add(const HealthNote('Microphone problem'));
    if ((hwOk & hwCamPower) == 0) notes.add(const HealthNote('Camera power rail problem'));
    if ((hwOk & hwBoard) != hwBoard) notes.add(const HealthNote('Board fault'));
  }
  if (fsFreeKb != null && fsFreeKb < 1500) {
    notes.add(const HealthNote('Node storage nearly full'));
  }
  if ((rssi != null && rssi < -115) || (snr != null && snr < -10)) {
    notes.add(const HealthNote('Weak link — consider moving the node or the handheld'));
  }
  return notes;
}

class AlertCopy {
  const AlertCopy({required this.title, required this.body});
  final String title;
  final String body;
}

AlertCopy alertCopy({
  required String nodeName,
  required String trigger,
  required bool cameraFailed,
  required bool noBudget,
  required bool ir,
  int? soundPeakDb,
}) {
  final what = switch (trigger) {
    'snapshot' => 'Snapshot',
    'button' => 'Button',
    _ => 'Motion',
  };
  final title = cameraFailed ? '$what — camera error' : '$what — $nodeName';
  final bits = <String>[
    if (noBudget) 'Photo kept on the node (radio limit reached)',
    if (ir) 'IR on',
    if (soundPeakDb != null) 'Sound $soundPeakDb dBFS',
  ];
  return AlertCopy(title: title, body: bits.isEmpty ? nodeName : bits.join(' · '));
}

bool shouldNotify({
  required NotifyPref pref,
  required String trigger,
  required bool quiet,
}) {
  if (pref == NotifyPref.none) return false;
  if (pref == NotifyPref.motion && trigger != 'pir') return false;
  return true;
}

bool inQuietHours(DateTime now, int startHour, int endHour) {
  if (startHour < 0 || endHour < 0) return false;
  final hour = now.hour;
  if (startHour == endHour) return false;
  if (startHour < endHour) return hour >= startHour && hour < endHour;
  return hour >= startHour || hour < endHour;
}

/// Event time is 0 until a node has heard the phone's clock. Show handheld time, marked ≈.
(String text, bool approximate) eventWhen(int unix, int received) {
  final stamp = unix > 0 ? unix : received;
  if (stamp <= 0) return ('Time unknown', true);
  final local = DateTime.fromMillisecondsSinceEpoch(stamp * 1000, isUtc: true).toLocal();
  final text = _format(local);
  return (unix > 0 ? text : '≈ $text', unix <= 0);
}

String formatWhen(DateTime time) => _format(time.toLocal());

String ago(DateTime? time, {DateTime? now}) {
  if (time == null) return 'not seen';
  final delta = (now ?? DateTime.now()).difference(time);
  if (delta.isNegative || delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 36) return '${delta.inHours} h ago';
  return '${delta.inDays} d ago';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _format(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}';

const Map<int, String> frameSizeLabels = {
  0: '96×96',
  1: 'QQVGA 160×120',
  2: 'QCIF 176×144',
  3: 'HQVGA 240×176',
  4: '240×240',
  5: 'QVGA 320×240',
  6: 'CIF 400×296',
  7: 'HVGA 480×320',
  8: 'VGA 640×480',
  9: 'SVGA 800×600',
  10: 'XGA 1024×768',
  11: 'HD 1280×720',
  12: 'SXGA 1280×1024',
};

const Map<int, String> irModeLabels = {0: 'Off', 1: 'Always', 2: 'Auto'};

class ConfigField {
  const ConfigField(this.key, this.label, this.min, this.max, {this.help = ''});
  final String key;
  final String label;
  final int min;
  final int max;
  final String help;
}

const List<ConfigField> configFields = [
  ConfigField('armed', 'Armed', 0, 1, help: 'PIR events on or off'),
  ConfigField('heartbeat_min', 'Check-in', 1, 1440, help: 'Minutes between status reports. 5–10 is faster and costs battery.'),
  ConfigField('cooldown_s', 'Cooldown', 0, 3600, help: 'Minimum seconds between photo events'),
  ConfigField('jpeg_quality', 'JPEG quality', 4, 63, help: 'LoRa photo. Lower is sharper and larger.'),
  ConfigField('framesize', 'Photo size', 0, 10, help: 'LoRa photo size. 5 is QVGA, 8 is VGA, 10 is the largest the node accepts.'),
  ConfigField('ir_mode', 'IR light', 0, 2, help: 'Off, always, or auto from scene brightness'),
  ConfigField('ir_luma', 'IR threshold', 0, 255, help: 'Auto-IR turns on below this brightness'),
  ConfigField('audio_ms', 'Audio length', 0, 5000, help: 'Sound sample per event, milliseconds'),
  ConfigField('tx_power', 'Radio power', -9, 22, help: 'LoRa dBm'),
  ConfigField('send_image', 'Send photos', 0, 1),
  ConfigField('hires_local', 'Keep full-res on node', 0, 1),
  ConfigField('grayscale_ir', 'Black and white under IR', 0, 1),
];

String triggerLabel(String trigger) {
  switch (trigger) {
    case 'snapshot':
      return 'Snapshot';
    case 'button':
      return 'Button';
    default:
      return 'Motion';
  }
}

String viaLabel(String? via) {
  switch (via) {
    case 'espnow':
      return 'ESP-NOW';
    case 'lora':
      return 'LoRa';
    default:
      return via ?? '—';
  }
}

extension NodeStatusHeartbeat on NodeStatus {
  int get heartbeatMin => config['heartbeat_min'] ?? 30;
}
