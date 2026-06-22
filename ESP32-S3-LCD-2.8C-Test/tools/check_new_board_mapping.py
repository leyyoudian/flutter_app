from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

lcd_h = (ROOT / "main" / "LCD_Driver" / "ST7701S.h").read_text(encoding="utf-8")
lcd_c = (ROOT / "main" / "LCD_Driver" / "ST7701S.c").read_text(encoding="utf-8")
sd_h = (ROOT / "main" / "SD_Card" / "SD_MMC.h").read_text(encoding="utf-8")
storage_c = (ROOT / "main" / "Badge" / "BadgeStorage.c").read_text(encoding="utf-8")
main_c = (ROOT / "main" / "main.c").read_text(encoding="utf-8")
cmake = (ROOT / "main" / "CMakeLists.txt").read_text(encoding="utf-8")

expected_sd_pins = {
    "CONFIG_EXAMPLE_PIN_CLK": "7",
    "CONFIG_EXAMPLE_PIN_CMD": "15",
    "CONFIG_EXAMPLE_PIN_D0": "42",
    "CONFIG_EXAMPLE_PIN_D1": "19",
    "CONFIG_EXAMPLE_PIN_D2": "20",
    "CONFIG_EXAMPLE_PIN_D3": "4",
}
for name, value in expected_sd_pins.items():
    assert f"#define {name}   {value}" in sd_h or f"#define {name}  {value}" in sd_h, (
        f"{name} should map to GPIO{value}"
    )

assert "#define LCD_MOSI 1" in lcd_h, "LCD SDA/MOSI should stay on GPIO1"
assert "#define LCD_SCLK 2" in lcd_h, "LCD SCK should stay on GPIO2"
assert "#define LCD_RST  16" in lcd_h or "#define LCD_RST 16" in lcd_h, "LCD reset should use GPIO16"
assert "#define LCD_CS   0" in lcd_h or "#define LCD_CS  0" in lcd_h or "#define LCD_CS 0" in lcd_h, (
    "LCD CS should default to GPIO0; hardware jumper may tie CS to GND"
)

for text, path in [
    (lcd_h, "ST7701S.h"),
    (lcd_c, "ST7701S.c"),
    (sd_h, "SD_MMC.h"),
    (storage_c, "BadgeStorage.c"),
    (main_c, "main.c"),
]:
    assert "TCA9554" not in text and "Set_EXIO" not in text, f"{path} should not depend on TCA9554"

assert "PCF85063" not in main_c and "RTC_Loop" not in main_c, "main should not initialize or poll RTC"
assert "I2C_Init" not in main_c and "EXIO_Init" not in main_c, "main should not initialize removed I2C/EXIO devices"

for removed in [
    "EXIO/TCA9554PWR.c",
    "PCF85063/PCF85063.c",
    "I2C_Driver/I2C_Driver.c",
    "Buzzer/Buzzer.c",
    "Button_Driver/Button_Driver.c",
    "Button_Driver/multi_button.c",
]:
    assert removed not in cmake, f"{removed} should be removed from CMake sources"

for removed_include in ["./EXIO", "./I2C_Driver", "./PCF85063", "./Buzzer", "./Button_Driver"]:
    assert removed_include not in cmake, f"{removed_include} include dir should be removed"

assert "esp_driver_i2c" not in cmake, "I2C driver requirement should be removed"
assert "SD_Card_CS_EN" not in storage_c, "Badge storage should not toggle removed SD CS/EXIO"
assert "button_Init" not in main_c, "GPIO0 button init should be removed because GPIO0 is LCD CS"

print("new board mapping checks passed")
