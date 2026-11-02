#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
demo_average.py -- 用真实录像验证多帧平均对随机噪声的抑制，并生成对比图

口径说明（为什么用方差而不是中位数）：
  录像底噪是 0~7 的小整数、量化很粗，中位数位置几乎不动，无法体现平均效果。
  正确做法：先去掉每个 bin 的"确定性时间均值"，剩下的帧间随机波动才是噪声，
  用它的 RMS（功率）衡量。N 帧平均后噪声 RMS 按 1/sqrt(N) 下降，
  功率下降 10*log10(N) dB。

输出：
  1) 各窗口 N 的实测功率下降 vs 理论 10*log10(N)
  2) average_demo.png：噪声区单帧 vs 16 帧平均
"""

import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

import my_parser
from frame_average import FrameAverager, theoretical_drop

HERE = os.path.dirname(os.path.abspath(__file__))
BIN_PATH = os.path.join(HERE, "capture_20s.bin")
PNG_PATH = os.path.join(HERE, "average_demo.png")
N_BINS = 1024
WINDOWS = (4, 16, 64)


def residual_rms(matrix):
    """去掉每列时间均值后，随机波动的 RMS。"""
    resid = matrix - matrix.mean(axis=0, keepdims=True)
    return float(np.sqrt((resid ** 2).mean())), resid


def main():
    data = open(BIN_PATH, "rb").read()
    packets, _ = my_parser.find_packets(data, N_BINS)
    all_mags = np.array([m for _, m in packets], dtype=np.float64)
    flags = packets[0][0]["flags"]
    print("解析到 %d 帧，flags=0x%04x（%s 通道）"
          % (len(all_mags), flags, "DDS" if flags & 8 else "AD"))

    # 选远离主峰（bin32）的噪声区
    noise_idx = np.array([k for k in range(N_BINS) if abs(k - 32) > 60])
    S = all_mags[:, noise_idx]

    rms_single, _ = residual_rms(S)
    print("单帧随机噪声 RMS=%.4f" % rms_single)
    print("%6s %12s %12s %12s" % ("N", "实测功率下降", "理论dB", "平均后RMS"))

    plot_avg = None
    rms16 = None
    for n in WINDOWS:
        averager = FrameAverager(len(noise_idx), n)
        rows = []
        for row in S:
            out = averager.update(row)
            if averager.ready:
                rows.append(out)
        rms_avg, _ = residual_rms(np.array(rows))
        drop = 10 * np.log10((rms_single ** 2) / (rms_avg ** 2))
        print("%6d %12.2f %12.2f %12.4f"
              % (n, drop, theoretical_drop(n), rms_avg))
        if n == 16:
            plot_avg = rows[-1]
            rms16 = rms_avg

    # ---- 对比图：噪声区局部，单帧 vs 16 帧平均 ----
    fs = 100e6 if (flags & 8) else 32e6
    bin_hz = fs / 8192.0
    lo, hi = 600, 700
    seg = np.arange(lo, hi)
    x_khz = seg * bin_hz / 1e3
    single_seg = all_mags[0, seg]
    avg_seg = np.array(plot_avg)[np.searchsorted(noise_idx, seg)]

    fig, axes = plt.subplots(2, 1, figsize=(10, 6.5), sharex=True)
    axes[0].plot(x_khz, single_seg, color="#90a4ae", lw=1.2)
    axes[0].set_title("Single frame (global noise RMS=%.3f)" % rms_single)
    axes[0].grid(alpha=0.25)
    axes[1].plot(x_khz, avg_seg, color="#1e88e5", lw=1.4)
    axes[1].set_title("16-frame average (global noise RMS=%.3f)" % rms16)
    axes[1].set_xlabel("frequency (kHz)")
    axes[1].grid(alpha=0.25)
    # 统一纵轴范围，便于直接对比抖动大小
    ymax = max(single_seg.max(), avg_seg.max()) + 1
    for ax in axes:
        ax.set_ylabel("|X|")
        ax.set_ylim(-1, ymax)
    fig.suptitle("Multi-frame averaging suppresses random noise ~10log10(N) dB")
    fig.tight_layout()
    fig.savefig(PNG_PATH, dpi=130)
    print("对比图已保存: %s" % os.path.basename(PNG_PATH))


if __name__ == "__main__":
    main()
