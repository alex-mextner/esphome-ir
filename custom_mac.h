#pragma once
#include "esp_mac.h"
#include "esp_wifi.h"

inline void set_custom_mac() {
    uint8_t mac[6] = {0xE2, 0x72, 0xA1, 0x70, 0xE5, 0x6C};
    esp_base_mac_addr_set(mac);
}

// Disable 802.11r (Fast Transition) — Xiaomi AX3000 mesh enables FT by default
// which breaks WPA2-PSK auth on Arduino ESP32 stack.
inline void configure_wifi_compat() {
    wifi_config_t cfg = {};
    esp_wifi_get_config(WIFI_IF_STA, &cfg);
    cfg.sta.ft_enabled = 0;
    cfg.sta.pmf_cfg.capable = true;
    cfg.sta.pmf_cfg.required = false;
    esp_wifi_set_config(WIFI_IF_STA, &cfg);
}
