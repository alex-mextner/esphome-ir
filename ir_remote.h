#pragma once
#include "IRsend.h"

// Shared IRsend helper for the living-room universal remote.
// GPIO2 drives the IR LED. IRHaierACYRW02 (haier_acyrw02 component) also uses
// GPIO2 for AC commands. Both use plain GPIO bit-bang via IRsend, so
// whichever sender runs last wins the pin for the duration of its transmission.
// There is no RMT vs GPIO conflict because this helper removes ESPHome's
// remote_transmitter (RMT-based) from the build entirely.

inline void send_samsung(uint32_t data) {
  static IRsend irsend(2);
  irsend.begin();
  irsend.sendSAMSUNG(data, 32);
}
