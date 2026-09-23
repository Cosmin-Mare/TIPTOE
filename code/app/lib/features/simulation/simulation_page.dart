import 'package:flutter/material.dart';

import '../../state/tiptoe_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SimulationStep {
  const SimulationStep({required this.title, required this.body, this.action, this.scenario});

  final String title;
  final String body;
  final String? action;
  final String? scenario;
}

const simulationSteps = <SimulationStep>[
  SimulationStep(
    title: 'Three nodes, three states',
    body: 'Garden checked in recently. Gate is late. Shed is offline: critical battery, too cold to charge, a camera fault, and a weak link. Open each card on Home.',
  ),
  SimulationStep(
    title: 'Place them on the map',
    body: 'Open the Map tab. It centers on this phone. Select a camera and tap where it stands, or drop it at your location if you are standing there. A motion alert turns that pin red for a minute.',
  ),
  SimulationStep(
    title: 'Motion, then the photo',
    body: 'A motion alert is sent before the picture. About two seconds later the thumbnail arrives. One also plays on its own a few seconds after the simulation starts.',
    action: 'Play motion on Garden',
    scenario: 'motion',
  ),
  SimulationStep(
    title: 'Commands wait for the node',
    body: 'Turn Armed off on Garden. It stays pending for about six seconds, then the simulated node checks in and the change is confirmed. Cancel is on the node screen.',
  ),
  SimulationStep(
    title: 'Camera trouble and a radio limit',
    body: 'One alert says the camera failed. The other keeps the photo on the node because the LoRa duty-cycle budget ran out.',
    action: 'Play both',
    scenario: 'faults',
  ),
  SimulationStep(
    title: 'Full-resolution photo',
    body: 'Near mode tells a nearby node to send the large photo. It is not pushed over Bluetooth. Open the new event and choose Get full-res over Bluetooth. Wi-Fi download needs the real handheld.',
    action: 'Near mode, then motion',
    scenario: 'near',
  ),
];

class SimulationPage extends StatelessWidget {
  const SimulationPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Simulation')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const Text(
            'Nothing here is a real board. The phone is talking to a simulated handheld that uses the same messages as the PCB, including the delay while a node is asleep.',
            style: TextStyle(color: TiptoeColors.mute, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < simulationSteps.length; i++) ...[
            SoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ${simulationSteps[i].title}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(simulationSteps[i].body, style: const TextStyle(height: 1.4)),
                  if (simulationSteps[i].action != null) ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: store.useMock ? () => _run(store, simulationSteps[i].scenario!) : null,
                      child: Text(simulationSteps[i].action!),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton(
            onPressed: () async {
              final ok = await confirm(
                context,
                'Leave the simulation?',
                'You can pair a real handheld next. Events from this session stay on the phone.',
                'Leave',
              );
              if (ok) await store.leaveSimulation();
            },
            child: const Text('Leave simulation and pair a handheld'),
          ),
        ],
      ),
    );
  }

  void _run(TiptoeStore store, String scenario) {
    if (scenario == 'faults') {
      store.runScenario('camera_fail');
      store.runScenario('no_budget');
    } else {
      store.runScenario(scenario);
    }
    store.notice('Playing. Watch Home and Timeline.');
  }
}
