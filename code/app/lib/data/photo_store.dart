import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PhotoStore {
  PhotoStore(this.directory);

  final Directory directory;

  static Future<PhotoStore> open() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(root.path, 'photos'));
    await directory.create(recursive: true);
    return PhotoStore(directory);
  }

  Future<String> saveJpeg(int seq, Uint8List jpeg, {required bool full}) async {
    final name = full ? 'e${seq}_full.jpg' : 'e$seq.jpg';
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(jpeg, flush: true);
    return file.path;
  }

  Future<String> saveBytes(String name, List<int> bytes) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> deleteSeq(int seq) async {
    for (final name in ['e$seq.jpg', 'e${seq}_full.jpg', 'e$seq.wav']) {
      final file = File(p.join(directory.path, name));
      if (await file.exists()) await file.delete();
    }
  }
}
