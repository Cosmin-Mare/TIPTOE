import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../simulation/simulation_page.dart';

class HandheldPage extends StatelessWidget {
  const HandheldPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = TiptoeScope.of(context);
    final handheld = store.handheld;
    final budget = handheld?.loraBudgetMs;
    final wifiOn = store.wifi?.on ?? handheld?.wifi ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Handheld')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(store.phaseDetail ?? 'Not connected', style: const TextStyle(color: TiptoeColors.mute)),
                const SizedBox(height: 8),
                Text(batteryText(handheld?.soc, handheld?.charge), style: const TextStyle(fontSize: 22)),
                const SizedBox(height: 8),
                _line('Firmware', handheld?.fw ?? '—'),
                _line('Voltage', handheld?.vbatMv == null ? '—' : '${handheld!.vbatMv} mV'),
                _line('Time', handheld == null ? '—' : handheld.timeSynced ? 'Synced from this phone' : 'Not synced yet'),
                _line('Free storage', handheld?.fsFreeKb == null ? '—' : '${handheld!.fsFreeKb} KB'),
                _line('LoRa budget', budget == null ? '—' : '${(budget / 1000).toStringAsFixed(0)} s left this hour'),
                _line('Radio', handheld == null ? '—' : handheld.loraOk ? 'Listening' : 'Not ready'),
                if (budget != null && budget < 30000)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Duty-cycle budget is low. Nodes will keep photos locally until it recovers.', style: TextStyle(color: TiptoeColors.warn)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Near mode'),
                  subtitle: Text(wifiOn ? 'Wi-Fi is on. Nearby nodes send full-resolution photos.' : 'Wi-Fi is off.'),
                  value: wifiOn,
                  onChanged: (value) async {
                    if (value) {
                      final ok = await confirm(
                        context,
                        'Turn on Near mode?',
                        'The handheld uses about 100 mA more. Nodes close to you send full-resolution photos over ESP-NOW. It turns itself off after 10 minutes without activity.',
                        'Turn on',
                      );
                      if (!ok) return;
                    }
                    await store.setNearMode(value);
                  },
                ),
                if (store.wifi?.ssid != null)
                  Text('Network ${store.wifi!.ssid}', style: const TextStyle(color: TiptoeColors.mute)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SoftCard(
            child: Text(
              'Pairing uses a PIN from the handheld firmware. It is not stored in this app. If the phone rejects the handheld after a re-flash, forget TIPTOE-HH in Bluetooth settings and pair again.',
              style: TextStyle(height: 1.4),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: store.forgetHandheld, child: const Text('Forget this handheld')),
          if (store.useMock) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SimulationPage())),
              child: const Text('Open the simulation guide'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: TiptoeColors.mute))),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
