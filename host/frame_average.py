#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
frame_average.py -- 多帧平均功能（11.2 加分功能 B）

原理（答辩要能讲）：
  对连续 N 帧、每个 bin 的幅度做算术平均。
  - 有用信号是相干的，帧与帧之间稳定，平均后基本不变；
  - 噪声是随机、零均值的，平均后方差缩小为原来的 1/N，
    噪声的标准差（RMS）缩小为原来的 1/sqrt(N)；
  - 因此噪声底的功率下降 10*log10(N) dB，
    用幅度衡量时 20*log10(1/sqrt(N)) 也是 -10*log10(N) dB。
  例：N=16 时噪声底下降约 12 dB。

对外：
  FrameAverager       滑动窗口多帧平均器
  noise_floor         用中位数稳健估计噪声底（不被主峰拉高）
  theoretical_drop    理论噪声底下降量 10*log10(N)
"""

import numpy as np


class FrameAverager:
    """保持最近 window 帧，实时返回它们的逐 bin 平均。"""

    def __init__(self, n_bins, window):
        if window < 1:
            raise ValueError("窗口大小必须 >= 1")
        self.n_bins = n_bins
        self.window = window
        self._frames = []                       # 最近的帧（每帧一个 ndarray）
        self._sum = np.zeros(n_bins, np.float64)  # 窗口内逐 bin 累加和

    def update(self, mags):
        """加入一帧，返回当前窗口的平均频谱（ndarray）。"""
        frame = np.asarray(mags, dtype=np.float64)
        self._frames.append(frame)
        self._sum += frame
        # 超过窗口：丢掉最旧的一帧，并从累加和里减去
        if len(self._frames) > self.window:
            oldest = self._frames.pop(0)
            self._sum -= oldest
        return self.average()

    def average(self):
        """当前窗口的逐 bin 平均；窗口未满时按实际帧数平均。"""
        return self._sum / len(self._frames)

    @property
    def count(self):
        """当前缓存了几帧。"""
        return len(self._frames)

    @property
    def ready(self):
        """是否已经攒满一个完整窗口。"""
        return len(self._frames) == self.window


def noise_floor(mags):
    """
    噪声底幅度估计。
    用中位数而不是均值：主峰只占极少数 bin，中位数不会被它拉高，
    能反映绝大多数 bin（噪声区域）的典型幅度。
    """
    return float(np.median(np.asarray(mags, dtype=np.float64)))


def amp_to_db(value, reference):
    """幅度比转 dB（20log10）。"""
    return 20.0 * np.log10(value / reference)


def theoretical_drop(window):
    """理论噪声底下降量（dB）= 10*log10(N)。"""
    return 10.0 * np.log10(window)
