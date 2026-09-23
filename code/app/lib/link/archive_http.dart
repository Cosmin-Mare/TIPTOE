import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'frame_source.dart';

/// HTTP API on the handheld (`192.168.4.1`) or a node in maintenance mode.
class ArchiveHttp {
  const ArchiveHttp({this.host = '192.168.4.1'});

  final String host;

  Future<Uint8List> image({required int seq, required bool full}) async {
    final response = await http
        .get(Uri.http(host, '/img', {'seq': '$seq', 'full': full ? '1' : '0'}))
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      throw CommandException('The handheld does not have that photo (${response.statusCode}).');
    }
    return response.bodyBytes;
  }

  Future<Map<String, Object?>> status() async {
    final decoded = await _jsonGet('/api/status');
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value as Object?));
    }
    throw CommandException('Unexpected status from the node.');
  }

  Future<List<Map<String, Object?>>> events() async {
    final decoded = await _jsonGet('/api/events');
    if (decoded is! List) throw CommandException('The node archive was not a list.');
    return [
      for (final item in decoded)
        if (item is Map) item.map((key, value) => MapEntry(key.toString(), value as Object?)),
    ];
  }

  Future<Uint8List> bytes(String path) async {
    final response = await http.get(Uri.http(host, path)).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw CommandException('Could not download $path (${response.statusCode}).');
    }
    return response.bodyBytes;
  }

  Future<void> exitMaintenance() async {
    final response = await http.post(Uri.http(host, '/api/exit')).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw CommandException('The node did not leave maintenance mode.');
    }
  }

  Future<String> uploadFirmware(String path) async {
    final request = http.MultipartRequest('POST', Uri.http(host, '/update'));
    request.files.add(await http.MultipartFile.fromPath('fw', path));
    final response = await request.send().timeout(const Duration(minutes: 3));
    final text = await response.stream.bytesToString();
    if (response.statusCode != 200 || text.toLowerCase().contains('fail')) {
      throw CommandException(text.isEmpty ? 'Firmware update failed.' : text);
    }
    return text;
  }

  Future<Object?> _jsonGet(String path) async {
    final response = await http.get(Uri.http(host, path)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw CommandException('$path returned ${response.statusCode}. Join the node Wi-Fi first.');
    }
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw CommandException('Could not read the reply from $path.');
    }
  }
}
