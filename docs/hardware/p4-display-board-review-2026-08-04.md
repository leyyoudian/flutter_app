# ESP32-P4 双屏适配板硬件评审

日期：2026-08-04

资料来源：
- `D:/Desktop/PowerToys.MouseWithoutBorders/ScreenCaptures/Netlist_Schematic1_5_2026-08-04.enet`
- `D:/Documents/xwechat_files/wxid_8ua73751c7pn22_14b0/msg/file/2026-08/HL028BW.. 1.pdf`
- `D:/Documents/xwechat_files/wxid_8ua73751c7pn22_14b0/msg/file/2026-08/3542184564HL025BWV8800ANT(2.5圆形SPI+RGB)_Specification V1.0(1)副本.pdf`
- `D:/Desktop/PowerToys.MouseWithoutBorders/ScreenCaptures/ESP_32_P4_C5_Core_User_Guide_20260521_9fbca980ee.pdf`

## 总体结论

ESP32-P4 方案方向合理。两块屏都是 480x480、3SPI+18RGB、ST7701S、40pin FPC，主 RGB/SPI 引脚可以共用同一个 FPC 座。P4 的 GPIO 资源足够把原来 ESP32-S3 上缺掉的数据位补回完整 18-bit RGB，软件上可以用不同初始化表适配两块屏。

当前网表不建议直接打样，至少需要先修下面几个高风险点。

## 必须修改

1. FPC1 pin16/DB0 没有接到 P4。
   - 屏规格：pin16~33 是 DB0~DB17，DB0 是 Blue LSB。
   - 当前网表：FPC1.16 = `$1N837`，没有接到 U6；U6.GPIO10 = `B0` 也没有接到 FPC。
   - 修改：FPC1.16 接 `B0`，也就是 U6 pin25/GPIO10。

2. `3V3` 和 `3.3V` 是两个不同电源网。
   - 当前 `3V3` 供屏 VCI、TP_VCI、部分背光控制。
   - 当前 `3.3V` 供 P4 核心板 ESP_3V3、RTC_VBAT、SD 卡和 SD 上拉。
   - 如果不是故意双电源轨，必须合并成同一个 3.3V 主电源网；否则会出现 P4/SD/屏有一部分没供电，或者屏断电时仍被 P4 IO 灌电。

3. 背光 0 欧姆切换方式需要重画。
   - HL025BWV8800ANT：6S，IF=20mA，VF=19.2V，TPS61165 用 10ohm 检流电阻合理。
   - HL028BWV8483BNT：4P，IF=80mA，VF=3.2V，检流电阻应约 2.5ohm。
   - 当前 R10 把 LEDK 接到 TPS61165 FB，R9 把 LEDK 接到 MOS/10ohm 下拉，但 R9 路径没有进入 FB 检流环路。这样 TPS61165 可能看不到反馈，导致过压保护或 LED 电流失控。
   - 修改建议：LEDA/LEDK 永远走 TPS61165 的标准 FB 检流路径，只用 0ohm/DNP 切换 FB 到 GND 的 Rset：
     - HL025：Rset=10ohm，20mA。
     - HL028：Rset=2.49ohm 或 2.55ohm，约 80mA。
   - 背光开关/调光用 TPS61165 CTRL，不建议再用 Q6 低边硬切 LEDK。

4. SD 卡串联电阻阵列料号和值冲突。
   - 当前 RN1/RN4 Value 写 22ohm，但 Manufacturer Part 是 `4D03WGJ0103T5E`，描述是 10k 阵列。
   - SD CMD/CLK/DAT 不能串 10k；必须换成真正的 22ohm 阵列或分立 22ohm。
   - SD CLK 不需要 10k 上拉；建议 DNP R41，只保留 CMD、DAT0~DAT3 上拉。

5. P4 下载插排 H1 缺少 GND 和 BOOT 控制。
   - 当前 H1：RST_P4、GPIO38、GPIO37、空脚。
   - P4 UART 下载至少需要：GND、UART0_RX(GPIO38)、UART0_TX(GPIO37)、CHIP_PU/RST，以及 BOOT(GPIO35 拉低)。
   - 修改建议：
     - 手动下载：引出 GND、GPIO37、GPIO38、RST_P4、GPIO35_BOOT；GPIO36 加 10k 上拉。
     - 自动下载：CH340 的 TXD->GPIO38，RXD->GPIO37，DTR/RTS 通过双三极管控制 RST_P4/GPIO35。

6. C26 是 LEDA 到 GND 的升压输出电容，需按 2.5 寸 19.2V 背光选耐压。
   - 建议 C26 使用 1uF/35V 或 1uF/50V，且放在 LEDA/LEDK 回路附近。

## 建议修改

1. PCLK 串阻现在是 R1 22ohm + R16 22ohm，等效 44ohm。
   - 建议只保留一个 22ohm，放在 P4 端靠近源头；另一个改 0ohm 或 DNP。

2. 给屏型号加 `SCREEN_ID`。
   - 仅靠 R9/R10 选择背光电流，固件无法知道当前装的是哪块屏。
   - 建议加一个 GPIO 读取电阻配置，或用 ADC 分压识别：HL025=上拉，HL028=下拉。
   - 固件按 SCREEN_ID 选择 ST7701S 初始化表、时序参数和背光限流参数。

3. 避免把 GPIO35/GPIO36 当成有外部负载的普通信号。
   - P4 核心板资料中 GPIO35/36/37/38 是启动 strapping，GPIO37/38 还是 P4 UART0 下载脚。
   - 当前 FPC1.36/37 接 GPIO35/GPIO36，作为 TP_SDA/TP_SCL。如果屏真的没有触摸，这两个脚可能是 NC，风险较低；如果未来上触摸屏，I2C 上拉/触摸 IC 上电状态可能影响启动或下载。
   - 建议触摸可选功能换到非 strapping GPIO，或通过 0ohm/串阻隔离，并明确默认 DNP。

4. RGB 数据线建议补齐命名。
   - 当前红色用了 `GPIO28~GPIO33` 作为 R0~R5，但网名没有写 R0/R1。
   - 建议按屏定义统一命名：B0~B5、G0~G5、R0~R5，减少后续固件映射错误。

5. 外部接口建议补 ESD。
   - TF 卡、FPC、USB/烧录插排如果用户可接触，建议增加低电容 ESD 器件或预留位。

## 可以保留

1. RGB 主体映射方向合理：
   - DB1~DB5 -> B1~B5
   - DB6~DB11 -> G0~G5
   - DB12~DB17 -> GPIO28~GPIO33，建议改名 R0~R5
   - DE/VSYNC/HSYNC/SPI SDA/SCK/RESET/CS 均已拉到 P4 GPIO

2. SD 卡方向合理：
   - GPIO39~44 对应 SD1 DAT0/DAT1/DAT2/DAT3/CLK/CMD，适合 4-bit SD。
   - GPIO45 做 card detect 可以保留。

3. RTC_VBAT 已接 3.3V，符合核心板资料“不能悬空”的要求。

4. CHIP_PU 有 10k 上拉和 1uF 到地，方向合理；建议额外保留实体 Reset 按键或测试点。

## P4 引脚注意事项

- GPIO34：影响 JTAG Signal Source，不建议接会在复位时强拉电平的外设。
- GPIO35/36/37/38：启动 strapping，必须保证上电/复位采样电平符合启动模式。
- GPIO37/38：P4 UART0 下载脚，建议只接烧录口，不要挂重负载。
- GPIO24/25：复用 USB Serial/JTAG；当前拿去做 LCD G2/G3 可以，但会失去这一路 USB-JTAG 调试便利。
- GPIO39~48：SD1/GMAC 复用；当前用于 SD 卡是合理的，但后续若加以太网会冲突。
- RTC_VBAT：必须接 2.3V~3.6V，当前接 3.3V 可以。
- ESP_LDO_VO4：最大 0.2A，不应用作外部大负载电源。

## 下版原理图检查清单

- [ ] FPC1.16 接 U6.GPIO10/B0。
- [ ] `3V3` 与 `3.3V` 电源策略明确：合并或加时序/隔离。
- [ ] 背光 R9/R10 改成切换 TPS61165 FB 检流电阻，不旁路 FB。
- [ ] C26 改 35V/50V。
- [ ] RN1/RN4 确认实际 BOM 是 22ohm，不是 10k。
- [ ] SD CLK 上拉 R41 DNP。
- [ ] H1 增加 GND 和 GPIO35_BOOT。
- [ ] GPIO36 加 10k 上拉，保证下载模式可靠。
- [ ] 触摸相关 GPIO35/36 风险处理：换脚或默认 DNP。
- [ ] 增加 SCREEN_ID 给固件识别屏型号。
