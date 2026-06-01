#pragma once
#include "IRsend.h"
#include "IRutils.h"

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

// Extended-NEC gear (e.g. the living-room projector, address 0xBD00).
// We only ever capture codes as ESPHome's decoded (address, command) pair.
// ESPHome clocks each 16-bit field LSB-first; IRsend::sendNEC clocks its
// payload MSB-first — so the payload is the bit-reverse of both fields.
// This reproduces the exact waveform the receiver decoded (verified: it
// equals the LG-decoder value the receiver logged for the same frame).
// One leader frame == one tap. Toggle/cycle keys (power, source) MUST NOT
// be repeated, so no NEC repeat frames here.
inline void send_nec(uint16_t address, uint16_t command) {
  static IRsend irsend(2);
  irsend.begin();
  uint32_t data = (reverseBits(address, 16) << 16) | reverseBits(command, 16);
  irsend.sendNEC(data, 32);
}
