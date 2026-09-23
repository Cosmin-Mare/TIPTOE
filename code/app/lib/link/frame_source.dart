import 'dart:async';

enum LinkPhase { idle, connecting, syncing, live, reconnecting }

abstract class FrameSource {
  Stream<List<int>> get incoming;

  Future<void> start();

  Future<void> stop();

  Future<void> write(List<int> bytes);

  void watchDisconnect(void Function(String reason) onLost) {}

  void simulateMotion() {}

  /// Named review scenarios. The real handheld ignores these.
  void runScenario(String name) {}
}

class CommandException implements Exception {
  CommandException(this.message);
  final String message;

  @override
  String toString() => message;
}
