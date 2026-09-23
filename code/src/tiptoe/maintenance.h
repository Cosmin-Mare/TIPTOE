// Wi-Fi AP + web UI: status, local event archive, live snapshot, config, OTA update.
#pragma once
#include <stdint.h>

namespace maintenance {
// Blocks until the user exits, the idle timeout passes, or the button is pressed again.
void run(uint32_t idleTimeoutMs = 10 * 60 * 1000);
}
