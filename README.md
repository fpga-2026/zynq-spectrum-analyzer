# 基于 Zynq 的双源频谱分析系统

用一块 Zynq-7020 做的小型频谱分析仪。数字源（DDS，10 MHz）和模拟源（AD9280 采样）共用同一条 8192 点 FFT 通路，靠"已知源走一遍同一条路"来标定整条链路的频率和幅度——这样在没有信号源、没有频谱仪的现场，也能判断测量结果对不对。

整个东西断断续续弄了一个多月，中间推翻重来过两次（`Spectrum_Analyzer` → `ddr_test` → 现在这版）。

## 能干什么

- 测 0~4 MHz 的信号频谱，1024 个点，每秒刷 7 帧左右
- 数字通道出 10.000000 MHz 单音，可以叠噪声，用来当标尺
- 模拟通道采 AD9280（8 位、32 MSPS），整帧 8192 点连续采，不丢样
- 两级自校准：数字源标 FFT 的 bin 和幅度，DA 环回标前端的直流和增益
- 每帧算 14 个指标，谱质量差的帧直接丢掉不发
- 上位机 Python，能实时画图，也能无窗口跑统计

## 硬件怎么接

```
板子 xc7z020clg400-2
  ├─ AD/DA 扩展模块（AD9280 + AD9708）插在板对板接口
  ├─ 一根蓝色 SMA 短线：DA 输出 → AD 输入（就靠它做激励）
  └─ USB 转串口，230400 8N1

时钟：
  FCLK_CLK0  100 MHz → FFT、AXIS 复用、峰值检测、DMA、AXI
  FCLK_CLK2   32 MHz → ADC 采样、DAC 更新、整帧快照、FIFO 写侧
```

数据流大致是这样：

```
DDS(10M) → iq_scale → 噪声注入 ─┐
                                ├─ AXIS 二选一 → FFT 8192 点 ─┐
AD9280 → 采样 → 整帧快照(8192) → 异步FIFO → 8转32(减DC×512) ─┘
                                                              ↓
                             包 FIFO → 峰值检测 → DMA → DDR →  Cortex-A9
                                                              ↓
                                          指标 / 闸门 / 校准 / 组包 → 串口 → 上位机
```

## 实测数据

| 项目 | 结果 |
|---|---|
| 载波 | 125.000 kHz 落在 bin 32（误差 0） |
| 幅度稳定性 | mag 11264~11306，波动 ±0.2% |
| ADC 利用率 | 约 34%（±44 LSB / ±128） |
| 近端杂散 ped | −46 ~ −75 dBc |
| 远端杂散 far | −69 ~ −81 dBc |
| 峰值/谱底 | 66 ~ 81 dB |
| SFDR / THD | 44~53 dBc / −90~−100 dBc |
| 采集耗时 | 361 µs/帧（8192/32 MHz 是 256 µs，其余是读出和中断开销） |
| 上传 | 1024 bin @ 7.2 fps，连续 144 帧 0 校验错 |
| 时序 | WNS +0.665 ns，TNS 0 |
| 资源/功耗 | LUT 10459 / FF 15723 / BRAM 40 / 1.889 W |

> 峰值/谱底这个数里含着 36 dB 的 FFT 处理增益（10log10(4096)），扣掉后 SINAD 约 30 dB，按 34% 量程折算满量程大概 6 bit——8 位 ADC 理论上限也就 8 bit，所以对外只说"投影满量程约 6 bit"。

## 目录

```
vivado/src/            现在用的 RTL
  ad9280_axis_sample.v   ADC 采样，用 ADC 自己的时钟采
  ad_snapshot_capture.v  整帧快照状态机，保证 8192 点连续
  fifo_to_axis_8to32.v   8 位转 32 位，减直流、乘 512、打 tlast
  axis_mux_2to1.v        双源二选一，带一级 skid buffer
  axis_fft_peak_detect.v 三级流水线找最大 bin
  axis_iq_scale.v        数字源幅度缩放
  iq_noise.v / lfsr_16bit.v  噪声注入
  da_wave_gen.v          256 点正弦表，出 125 kHz
  da_path_mux.v          校准音/扫频音切换

vivado/src/archive/    早期版本，留着看演进（加窗、tlast 生成器、旧采集模块）
vivado/constr/         引脚和跨时钟约束
vivado/bd/             Block Design 关键改动的脚本
sdk/src/main.c         PS 固件：RUN_MODE 0 校准 / 1 二进制流 / 4 扫频
host/                  上位机和统计脚本
```

## 怎么跑

1. Vivado 2018.3 建工程，器件 `xc7z020clg400-2`，把 `vivado/src/*.v` 加进去（`archive/` 不用加）
2. 按上面的框图搭 Block Design。两处关键改动有脚本：`vivado/bd/bd_fix_cdc.tcl`（改回 32 MHz 域的复位拓扑）、`vivado/bd/bd_da_path.tcl`（加 DA 支路，把 axi_gpio_0 扩成 32 位）
3. 加 `vivado/constr/*.xdc`，综合实现，时序应该 WNS ≥ 0
4. 导出硬件，SDK 建 Hello World，用 `sdk/src/` 覆盖 `src/`，编译下载
5. 串口 230400，跑 `RUN_MODE=1`
6. 上位机：
   ```
   python host/live_view.py --port COM6 --hold
   python host/live_view.py --port COM6 --headless --duration 20
   ```

## 踩过的坑（按踩到的顺序）

1. **谱底一直是毛的**：AXIS 直接接 FFT，FIFO 满就丢样。把"非零谱线数"统计出来是 5400 根，加了整帧快照状态机后降到 17 根。
2. **DA 输出有台阶**：每 8 个时钟才更新一次，出现对称镜像。改成 256 点表、每时钟更新、下降沿给数据。
3. **帧率只有一半**：复用器的 valid 组合直出，反压时多耗一拍（2.02 周期/beat）。加 skid buffer 后 1.02，帧率 3.4 → 6.9 fps。
4. **时序违例 −2.48 ns**：自己加的 flush 组合逻辑把 32 MHz 信号接到 100 MHz 域的复位上，改回 BD 标准复位拓扑就好了。
5. **串口只发出 64 字节**：`XUartPs_Send` 是中断驱动的，只填 FIFO 就返回。改成轮询写 FIFO 寄存器。
6. **DDS 通道一包都发不出**：闸门阈值 −100 dBc 是最严的条件（ped 永远 ≤ 0），改成 0。
7. **约束写了不生效**：XDC 的 `-filter` 里 `[0]` 被当成字符类通配符，去掉方括号才命中。
8. **GPIO 写进去没反应**：`XGpio_Initialize` 只读地址表，永远返回成功。后来加了"写 0xA5 读回来"的自检才发现问题。
9. **频率测成 375/625/875 kHz**：每次上电还不一样。最后发现是 AD/DA 模块上的电平电位器被碰偏了，波形削顶，峰值检测抓到奇次谐波。慢慢调回来，far 从 −41 改善到 −81 dBc。
10. **最后一条时序违例**：100 MHz 和 32 MHz 同出 PS 的 PLL，Vivado 按最紧的 rise→fall 边沿算 0.6 ns 要求，53 个端点全是静态控制字，用 `set_false_path -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_2]` 处理，WNS 变成 +0.665 ns。

经验就是：不报错的错最贵，所以每次都要想办法"造一个数字"出来（非零谱线数、每 beat 周期数、命中单元数、读回值）。

## 已知问题

- ADC 只用了 34% 量程（硬件不能动，加不了放大），满量程折算 ENOB 约 6 bit
- 用的是矩形窗，信号不在 bin 正中时近端杂散会到 −30 dBc 量级（`archive/hanning_window.v` 写过一版加窗，还没接到主链路）
- 板子上有间歇干扰，靠闸门筛，通过率大概 18%
- 绝对幅度还是相对标定，要绝对精度得再来一次外部基准

## 说明

PL 数据通路和校准算法是我做的，上位机和实测数据整理是队友做的。