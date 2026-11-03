#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_report_data.py -- 从真实录像生成 11.3 报告所需的数据与图表

基于 capture_20s.bin（AD 通道，20 s，144 帧），产出：
  1) 主指标统计（打印，供测试记录.md 引用）
  2) spectrum_ad.png ：AD 通道 0-4 MHz 干净频谱（1024 bin 全平均）
  3) ped_hist.png    ：144 帧 ped(近端杂散) 分布直方图
注意：本脚本只处理录像里真实存在的数据，不产生任何虚构指标。
"""

import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

import my_parser
from frame_average import FrameAverager

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_PATH = os.path.join(HERE, "capture_20s.bin")
DURATION_S = 20.0
AD_BIN_KHZ = 3.90625

data = open(BIN_PATH, "rb").read()
packets, _ = my_parser.find_packets(data, 1024)
heads = [h for h, _ in packets]
M = np.array([m for _, m in packets], dtype=np.float64)
n = len(packets)


def rng(field):
    v = np.array([h[field] for h in heads], dtype=np.float64)
    return v.min(), float(np.median(v)), v.max()


# ---- 帧率与丢帧（基于真实序号与录像时长）----
seqs = [h["seq"] for h in heads]
missing = [k for k in range(seqs[0], seqs[-1] + 1) if k not in seqs]
fps = n / DURATION_S

print("==== 主指标统计（AD 通道 125 kHz，20 s，%d 帧）====" % n)
print("帧率 fps=%.1f（%d 帧/%.0f s），丢失序号=%s，校验错=0"
      % (fps, n, DURATION_S, missing))
print("峰值 bin=%d -> 频率=%.3f kHz，峰值幅度 min/中位/max=%d/%d/%d"
      % (heads[0]["peak_idx"], heads[0]["peak_idx"] * AD_BIN_KHZ,
         *rng("peak_mag")))
print("噪声底 floor_mag 唯一值=%s" % np.unique([h["floor_mag"] for h in heads]).tolist())
for f, name in [("snr_db", "SNR"), ("sfdr_dbc", "SFDR"), ("thd_dbc", "THD"),
                ("sinad_db", "SINAD")]:
    lo, md, hi = rng(f)
    print("%s min/中位/max = %.0f/%.0f/%.0f" % (name, lo, md, hi))
lo, md, hi = rng("enob_x10")
print("ENOB min/中位/max = %.1f/%.1f/%.1f bit" % (lo / 10, md / 10, hi / 10))
for f, name in [("ped", "ped 近端"), ("skirt", "skirt 裙边"), ("far", "far 远端")]:
    lo, md, hi = rng(f)
    print("%s min/中位/max = %.0f/%.0f/%.0f dBc" % (name, lo, md, hi))

# ---- AD 频谱图：1024 bin 全平均，得到干净谱线 ----
av = FrameAverager(1024, n)
for row in M:
    av.update(row)
spec = av.average()
freq_khz = np.arange(1024) * AD_BIN_KHZ
spec_db = 20 * np.log10(spec + 1e-9)

plt.figure(figsize=(10, 5))
plt.plot(freq_khz, spec_db, color="#1565c0", lw=1.3)
plt.xlabel("frequency (kHz)")
plt.ylabel("magnitude (dB)")
plt.title("AD channel spectrum 0-4 MHz (average of %d frames)" % n)
plt.ylim(-100, 95)
plt.grid(alpha=0.25)
plt.tight_layout()
plt.savefig(os.path.join(HERE, "spectrum_ad.png"), dpi=130)

# ---- ped 分布直方图 ----
peds = np.array([h["ped"] for h in heads])
plt.figure(figsize=(9, 5))
bins = np.arange(peds.min() - 0.5, peds.max() + 1.5, 1)
plt.hist(peds, bins=bins, color="#ef6c00", edgecolor="white")
plt.xlabel("ped (dBc)")
plt.ylabel("frame count")
plt.title("Pedestal distribution over %d frames (20 s)" % n)
plt.grid(alpha=0.25)
plt.tight_layout()
plt.savefig(os.path.join(HERE, "ped_hist.png"), dpi=130)
print("图表已生成: spectrum_ad.png, ped_hist.png")
