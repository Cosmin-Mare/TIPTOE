import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'records.dart';

class AppDatabase {
  AppDatabase(this._db);

  final Database _db;

  static Future<AppDatabase> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'tiptoe.sqlite'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE handheld (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            fw TEXT, soc REAL, vbat_mv INTEGER, charge TEXT, ntc TEXT,
            wifi INTEGER, time_synced INTEGER, uptime_s INTEGER,
            fs_free_kb INTEGER, lora_budget_ms INTEGER, lora_ok INTEGER,
            updated_at INTEGER
          )''');
        await db.execute('''
          CREATE TABLE nodes (
            node_id INTEGER PRIMARY KEY,
            name TEXT,
            last_seen INTEGER,
            rssi REAL, snr REAL, via TEXT,
            soc REAL, vbat_mv INTEGER, charge TEXT, ntc TEXT, temp_c INTEGER,
            qi_mv INTEGER, hw_ok INTEGER, fw TEXT, event_count INTEGER,
            fs_free_kb INTEGER, uptime_s INTEGER, pending_count INTEGER,
            config_json TEXT, notes_json TEXT,
            lat REAL, lng REAL
          )''');
        await db.execute('''
          CREATE TABLE events (
            seq INTEGER PRIMARY KEY,
            node_id INTEGER, event_id INTEGER, trigger TEXT,
            time INTEGER, received INTEGER, ir INTEGER,
            sound_peak_db INTEGER, sound_rms_db INTEGER, luma INTEGER, soc INTEGER,
            width INTEGER, height INTEGER, via TEXT, rssi REAL,
            has_image INTEGER, full INTEGER, bytes INTEGER,
            small_path TEXT, full_path TEXT, audio_path TEXT,
            hires_on_node INTEGER, camera_failed INTEGER, no_budget INTEGER,
            seen INTEGER, phone_only INTEGER
          )''');
        await db.execute('''
          CREATE TABLE pending (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id INTEGER, cmd TEXT, key TEXT, value INTEGER, created_at INTEGER
          )''');
        await db.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE nodes ADD COLUMN lat REAL');
          await db.execute('ALTER TABLE nodes ADD COLUMN lng REAL');
        }
      },
    );
    return AppDatabase(db);
  }

  Future<String?> setting(String key) async {
    final rows = await _db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setSetting(String key, String? value) async {
    if (value == null) {
      await _db.delete('settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await _db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveHandheld(HandheldRecord record) async {
    await _db.insert('handheld', {
      'id': 1,
      'fw': record.fw,
      'soc': record.soc,
      'vbat_mv': record.vbatMv,
      'charge': record.charge,
      'ntc': record.ntc,
      'wifi': record.wifi ? 1 : 0,
      'time_synced': record.timeSynced ? 1 : 0,
      'uptime_s': record.uptimeS,
      'fs_free_kb': record.fsFreeKb,
      'lora_budget_ms': record.loraBudgetMs,
      'lora_ok': record.loraOk ? 1 : 0,
      'updated_at': record.updatedAt?.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<HandheldRecord?> loadHandheld() async {
    final rows = await _db.query('handheld', where: 'id = 1');
    if (rows.isEmpty) return null;
    final row = rows.first;
    return HandheldRecord(
      fw: row['fw'] as String?,
      soc: (row['soc'] as num?)?.toDouble(),
      vbatMv: row['vbat_mv'] as int?,
      charge: row['charge'] as String?,
      ntc: row['ntc'] as String?,
      wifi: row['wifi'] == 1,
      timeSynced: row['time_synced'] == 1,
      uptimeS: row['uptime_s'] as int?,
      fsFreeKb: row['fs_free_kb'] as int?,
      loraBudgetMs: row['lora_budget_ms'] as int?,
      loraOk: row['lora_ok'] != 0,
      updatedAt: _time(row['updated_at'] as int?),
    );
  }

  Future<void> saveNode(NodeRecord node) async {
    await _db.insert('nodes', {
      'node_id': node.nodeId,
      'name': node.name,
      'last_seen': node.lastSeen?.millisecondsSinceEpoch,
      'rssi': node.rssi,
      'snr': node.snr,
      'via': node.via,
      'soc': node.soc,
      'vbat_mv': node.vbatMv,
      'charge': node.charge,
      'ntc': node.ntc,
      'temp_c': node.tempC,
      'qi_mv': node.qiMv,
      'hw_ok': node.hwOk,
      'fw': node.fw,
      'event_count': node.eventCount,
      'fs_free_kb': node.fsFreeKb,
      'uptime_s': node.uptimeS,
      'pending_count': node.pendingCount,
      'config_json': jsonEncode(node.config),
      'notes_json': jsonEncode(node.notes),
      'lat': node.lat,
      'lng': node.lng,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<NodeRecord>> loadNodes() async {
    final rows = await _db.query('nodes', orderBy: 'node_id');
    return rows.map(_node).toList();
  }

  Future<void> upsertEvent(EventRecord event) async {
    final existing = await loadEvent(event.seq);
    final merged = existing == null
        ? event
        : event.copyWith(
            smallPath: event.smallPath ?? existing.smallPath,
            fullPath: event.fullPath ?? existing.fullPath,
            audioPath: event.audioPath ?? existing.audioPath,
            seen: existing.seen,
            phoneOnly: event.phoneOnly,
            full: event.full || existing.full,
          );
    await _insertEvent(merged);
  }

  Future<void> updateEvent(EventRecord event) => _insertEvent(event);

  Future<void> _insertEvent(EventRecord event) {
    return _db.insert('events', {
      'seq': event.seq,
      'node_id': event.nodeId,
      'event_id': event.eventId,
      'trigger': event.trigger,
      'time': event.time,
      'received': event.received,
      'ir': event.ir ? 1 : 0,
      'sound_peak_db': event.soundPeakDb,
      'sound_rms_db': event.soundRmsDb,
      'luma': event.luma,
      'soc': event.soc,
      'width': event.width,
      'height': event.height,
      'via': event.via,
      'rssi': event.rssi,
      'has_image': event.hasImage ? 1 : 0,
      'full': event.full ? 1 : 0,
      'bytes': event.bytes,
      'small_path': event.smallPath,
      'full_path': event.fullPath,
      'audio_path': event.audioPath,
      'hires_on_node': event.hiresOnNode ? 1 : 0,
      'camera_failed': event.cameraFailed ? 1 : 0,
      'no_budget': event.noBudget ? 1 : 0,
      'seen': event.seen ? 1 : 0,
      'phone_only': event.phoneOnly ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<EventRecord?> loadEvent(int seq) async {
    final rows = await _db.query('events', where: 'seq = ?', whereArgs: [seq], limit: 1);
    if (rows.isEmpty) return null;
    return _event(rows.first);
  }

  Future<List<EventRecord>> loadEvents() async {
    final rows = await _db.query('events', orderBy: 'seq DESC');
    return rows.map(_event).toList();
  }

  Future<void> deleteEvent(int seq) => _db.delete('events', where: 'seq = ?', whereArgs: [seq]);

  Future<void> markPhoneOnlyExcept(Set<int> stillOnHandheld) async {
    final rows = await _db.query('events', columns: ['seq']);
    for (final row in rows) {
      final seq = row['seq'] as int;
      if (!stillOnHandheld.contains(seq)) {
        await _db.update('events', {'phone_only': 1}, where: 'seq = ?', whereArgs: [seq]);
      }
    }
  }

  Future<int> addPending(PendingCommand command) async {
    return _db.insert('pending', {
      'node_id': command.nodeId,
      'cmd': command.cmd,
      'key': command.key,
      'value': command.value,
      'created_at': command.createdAt.millisecondsSinceEpoch,
    });
  }

  Future<List<PendingCommand>> loadPending() async {
    final rows = await _db.query('pending', orderBy: 'id');
    return rows
        .map(
          (row) => PendingCommand(
            id: row['id'] as int,
            nodeId: row['node_id'] as int,
            cmd: row['cmd'] as String,
            key: row['key'] as String?,
            value: row['value'] as int?,
            createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
          ),
        )
        .toList();
  }

  Future<void> deletePendingCmd(int nodeId, String cmd) {
    return _db.delete('pending', where: 'node_id = ? AND cmd = ? AND key IS NULL', whereArgs: [nodeId, cmd]);
  }

  Future<void> deletePendingOps(int nodeId) {
    return _db.delete('pending', where: 'node_id = ? AND key IS NULL', whereArgs: [nodeId]);
  }

  Future<void> deletePendingFor(int nodeId, {String? key}) {
    if (key == null) {
      return _db.delete('pending', where: 'node_id = ?', whereArgs: [nodeId]);
    }
    return _db.delete('pending', where: 'node_id = ? AND key = ?', whereArgs: [nodeId, key]);
  }

  Future<void> clearPending() => _db.delete('pending');

  NodeRecord _node(Map<String, Object?> row) {
    final config = <String, int>{};
    final rawConfig = row['config_json'] as String?;
    if (rawConfig != null && rawConfig.isNotEmpty) {
      final decoded = jsonDecode(rawConfig);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is num) config[entry.key.toString()] = value.round();
        }
      }
    }
    final notes = <String>[];
    final rawNotes = row['notes_json'] as String?;
    if (rawNotes != null && rawNotes.isNotEmpty) {
      final decoded = jsonDecode(rawNotes);
      if (decoded is List) notes.addAll(decoded.map((item) => item.toString()));
    }
    return NodeRecord(
      nodeId: row['node_id'] as int,
      name: (row['name'] as String?)?.isNotEmpty == true ? row['name'] as String : 'Node ${row['node_id']}',
      lastSeen: _time(row['last_seen'] as int?),
      rssi: (row['rssi'] as num?)?.toDouble(),
      snr: (row['snr'] as num?)?.toDouble(),
      via: row['via'] as String?,
      soc: (row['soc'] as num?)?.toDouble(),
      vbatMv: row['vbat_mv'] as int?,
      charge: row['charge'] as String?,
      ntc: row['ntc'] as String?,
      tempC: row['temp_c'] as int?,
      qiMv: row['qi_mv'] as int?,
      hwOk: row['hw_ok'] as int?,
      fw: row['fw'] as String?,
      eventCount: row['event_count'] as int?,
      fsFreeKb: row['fs_free_kb'] as int?,
      uptimeS: row['uptime_s'] as int?,
      pendingCount: (row['pending_count'] as int?) ?? 0,
      lat: (row['lat'] as num?)?.toDouble(),
      lng: (row['lng'] as num?)?.toDouble(),
      config: config,
      notes: notes,
    );
  }

  EventRecord _event(Map<String, Object?> row) {
    return EventRecord(
      seq: row['seq'] as int,
      nodeId: row['node_id'] as int,
      eventId: row['event_id'] as int?,
      trigger: (row['trigger'] as String?) ?? 'pir',
      time: (row['time'] as int?) ?? 0,
      received: (row['received'] as int?) ?? 0,
      ir: row['ir'] == 1,
      soundPeakDb: row['sound_peak_db'] as int?,
      soundRmsDb: row['sound_rms_db'] as int?,
      luma: row['luma'] as int?,
      soc: row['soc'] as int?,
      width: row['width'] as int?,
      height: row['height'] as int?,
      via: row['via'] as String?,
      rssi: (row['rssi'] as num?)?.toDouble(),
      hasImage: row['has_image'] == 1,
      full: row['full'] == 1,
      bytes: (row['bytes'] as int?) ?? 0,
      smallPath: row['small_path'] as String?,
      fullPath: row['full_path'] as String?,
      audioPath: row['audio_path'] as String?,
      hiresOnNode: row['hires_on_node'] == 1,
      cameraFailed: row['camera_failed'] == 1,
      noBudget: row['no_budget'] == 1,
      seen: row['seen'] == 1,
      phoneOnly: row['phone_only'] == 1,
    );
  }

  DateTime? _time(int? millis) => millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
}
