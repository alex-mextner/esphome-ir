import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import climate, sensor
from esphome.const import CONF_ID, CONF_SENSOR_ID, CONF_PIN
from esphome.core import CORE

AUTO_LOAD = ["climate"]

haier_acyrw02_ns = cg.esphome_ns.namespace("haier_acyrw02")
HaierClimate = haier_acyrw02_ns.class_("HaierClimate", climate.Climate)

CONFIG_SCHEMA = climate.climate_schema(HaierClimate).extend({
    cv.GenerateID(): cv.declare_id(HaierClimate),
    cv.Required(CONF_SENSOR_ID): cv.use_id(sensor.Sensor),
    cv.Required(CONF_PIN): cv.int_
})

async def to_code(config):
    if CORE.is_esp8266 or CORE.is_esp32:
        # Need master: 2.8.4 uses the legacy hw_timer API removed in
        # arduino-esp32 v3 (used by ESP32-C3 builds in ESPHome 2026.3+).
        cg.add_library(
            "IRremoteESP8266",
            None,
            "https://github.com/crankyoldgit/IRremoteESP8266.git",
        )

    var = cg.new_Pvariable(config[CONF_ID])
    await climate.register_climate(var, config)
    
    sens = await cg.get_variable(config[CONF_SENSOR_ID])
    cg.add(var.init(sens, config[CONF_PIN]))
