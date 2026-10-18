# -*- coding: utf-8 -*-
"""离线仿真: 模拟自动播放的 PCM 波形, 分析削顶, 画出对比图"""
import numpy as np
from PIL import Image, ImageDraw

FS = 48000

def tone(freq, dur, amp, phase0=0.0):
    n = int(FS * dur)
    t = np.arange(n) / FS
    return (np.sin(2 * np.pi * freq * t + phase0) * amp).astype(np.float64)

# ============ 模拟小星星前两个音: 哆(C4) 哆嗦(C4) ============
# 当前实现: 旋律 loud=4095(满) -> 约 ±32000; 低音 loud/2 -> ±16000
melody = tone(261.63, 0.5, 32000)
bass   = tone(130.81, 0.5, 16000)      # C3 低八度
mix_now = melody + bass

peak_now  = np.max(np.abs(mix_now))
clip_now  = np.mean(np.abs(mix_now) > 32767) * 100
fs_now    = np.mean(np.abs(mix_now) > 32767) * FS   # 每秒削顶采样数

# 改进方案: 旋律 22000 (0.69x) + 低音 8000 (0.5x of 0.5), 总峰值 < 30000
melody2 = tone(261.63, 0.5, 22000)
bass2   = tone(130.81, 0.5, 8000)
mix_fix = melody2 + bass2
peak_fix = np.max(np.abs(mix_fix))
clip_fix = np.mean(np.abs(mix_fix) > 32767) * 100

# 硬限幅后的样子(模拟 sat16)
def sat16(x):
    return np.clip(x, -32768, 32767)
mix_now_c = sat16(mix_now)
mix_fix_c = sat16(mix_fix)

# 削顶造成的"方波化"程度: 用二次谐波能量占比粗略估计
def hd2_ratio(x):
    spec = np.abs(np.fft.rfft(x))
    if spec[1] == 0: return 0
    return spec[2] / spec[1] * 100

print("=" * 62)
print(f"{'指标':<22}{'当前实现':>18}{'改进方案':>18}")
print("=" * 62)
print(f"{'旋律振幅':<22}{32000:>18}{22000:>18}")
print(f"{'低音振幅':<22}{16000:>18}{8000:>18}")
print(f"{'混音峰值':<22}{peak_now:>18.0f}{peak_fix:>18.0f}")
print(f"{'16bit 上限':<22}{32767:>18}{32767:>18}")
print(f"{'削顶采样占比':<20}{clip_now:>17.2f}%{clip_fix:>17.2f}%")
print(f"{'每秒削顶采样数':<19}{fs_now:>17.0f}{0:>18}")
print(f"{'二次谐波占比(失真指标)':<15}{hd2_ratio(mix_now_c):>16.1f}%{hd2_ratio(mix_fix_c):>17.1f}%")
print("=" * 62)
print()
print("结论:")
if clip_now > 1:
    print(f"  ❌ 当前实现有 {clip_now:.1f}% 的采样被硬限幅 -> 产生大量谐波 -> 听感'炸'")
    print(f"     每秒约 {fs_now:.0f} 个采样被削平, 相当于信号被'方波化'")
else:
    print("  ✅ 当前实现未削顶")
print(f"  ✅ 改进后峰值 {peak_fix:.0f} ({(peak_fix/32767*100):.0f}% 满幅), 留足余量给混响叠加")

# ============ 画波形图 ============
W, H = 1000, 620
img = Image.new("RGB", (W, H), (18, 18, 22))
d = ImageDraw.Draw(img)

def draw_wave(y_center, data, color, label, half_h=110, max_pts=400):
    # 每列取 min/max 画竖线(示波器风格)
    n = len(data)
    step = max(1, n // W)
    for x in range(0, W, 2):
        i0 = x * n // W
        i1 = min(n, i0 + step)
        seg = data[i0:i1]
        if len(seg) == 0:
            continue
        lo, hi = np.min(seg), np.max(seg)
        y_lo = y_center - int(hi / 32768 * half_h)
        y_hi = y_center - int(lo / 32768 * half_h)
        d.line([(x, y_lo), (x, y_hi)], fill=color)
    d.text((14, y_center - half_h - 22), label, fill=color)

def draw_limit(y_center, half_h=110):
    y1 = y_center - int(32767 / 32768 * half_h)
    y2 = y_center + int(32767 / 32768 * half_h)
    for x in range(0, W, 12):
        d.line([(x, y1), (x + 6, y1)], fill=(120, 120, 120))
        d.line([(x, y2), (x + 6, y2)], fill=(120, 120, 120))

# 上: 当前
d.text((14, 12), "CURRENT: melody 32000 + bass 16000  ->  HARD CLIPPED", fill=(255, 90, 90))
draw_limit(180)
draw_wave(180, mix_now_c, (255, 90, 90), f"peak {peak_now:.0f} (limit 32767), clipped {clip_now:.1f}%")

# 下: 改进
d.text((14, 330), "FIXED: melody 22000 + bass 8000  ->  headroom kept", fill=(90, 230, 120))
draw_limit(500)
draw_wave(500, mix_fix, (90, 230, 120), f"peak {peak_fix:.0f} ({(peak_fix/32767*100):.0f}% FS), no clipping")

# 说明
d.text((14, 588), "grey dashed = 16-bit full scale (32767). Flat tops in red = clipping distortion (the '炸' sound).", fill=(170, 170, 170))

out = r"D:\download\gaoyun\day3\waveform_analysis.png"
img.save(out)
print(f"\n波形图已保存: {out}")
