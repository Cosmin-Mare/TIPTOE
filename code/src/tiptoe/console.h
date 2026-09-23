// USB-CDC bench console (entered by pressing a key within 3 s of a cold boot).
#pragma once
#include <stdint.h>
namespace console {
bool offer(uint32_t windowMs = 3000);   // returns true if the user opened the console
void run();                             // returns when the user types "exit"/"sleep"
void selftest();
}
