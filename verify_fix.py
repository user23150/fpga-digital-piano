# -*- coding: utf-8 -*-
"""验证修正后的自动播放波形: 旋律0.5x + 低音0.125x + 混响叠加"""
import numpy as np
from PIL import Image, ImageDraw

FS = 48000

def tone(freq, dur, amp):
    n = int(FS * dur)
    t = np.arange(n) / FS
    return np.sin(2 * np.pi * freq * t) * amp

def sat16(x):
    return np.clip(x, -32768, 32767)

# ---------- 场景1: 修复前 (旋律32000 + 低音16000) ----------
mel_old = tone(261.63, 0.6, 32000)
bas_old = tone(130.81, 0.6, 16000)
mix_old = mel_old + bas_old

# ---------- 场景2: 修复后 (旋律16000 + 低音4000) ----------
mel_new = tone(261.63, 0.6, 16000)
bas_new = tone(130.81, 0.6, 4000)
dry_new = mel_new + bas_new

# 模拟混响叠加(湿声约 0.33~0.5, 取最坏 0.5)
wet = np.roll(dry_new, int(FS*0.021)) * 0.5
wet[:int(FS*0.021)] = 0
mix_new = dry_new + wet

def stats(x, name):
    p = np.max(np.abs(x))
    cl = np.mean(np.abs(x) > 32767) * 100
    print(f"{name:<26} peak={p:>8.0f}   clipped={cl:>6.2f}%   headroom={(32767-p)/32767*100:>5.1f}%")
    return p, cl

print("=" * 70)
p1, c1 = stats(mix_old, "BEFORE (32000 + 16000)")
p2, c2 = stats(mix_new, "AFTER (16000 + 4000 + reverb)")
print("=" * 70)
print()
if c2 == 0:
    print("✅ 修复后 0%% 削顶, 峰值 %.0f (%.0f%% 满幅)" % (p2, p2/327.67))
    print("   留出了 %.0f%% 余量, 即使混响再叠一层也不会削顶" % ((32767-p2)/327.67))
else:
    print("⚠️ 仍有 %.2f%% 削顶, 需要继续降增益" % c2)

# ---------- 画对比图 ----------
W, H = 1000, 660
img = Image.new("RGB", (W, H), (16, 16, 20))
d = ImageDraw.Draw(img)

def draw(y0, data, color, title, half=120):
    d.text((14, y0 - half - 26), title, fill=color)
    # 限幅线
    y1 = y0 - int(32767 / 32768 * half)
    y2 = y0 + int(32767 / 32768 * half)
    for x in range(0, W, 14):
        d.line([(x, y1), (x + 7, y1)], fill=(110, 110, 110))
        d.line([(x, y2), (x + 7, y2)], fill=(110, 110, 110))
    n = len(data)
    for x in range(0, W, 2):
        i0 = x * n // W
        i1 = min(n, i0 + max(1, n // W))
        seg = data[i0:i1]
        if len(seg) == 0: continue
        d.line([(x, y0 - int(np.max(seg)/32768*half)), (x, y0 - int(np.min(seg)/32768*half))], fill=color)

sat_old = sat16(mix_old)
sat_new = sat16(mix_new)

draw(150, sat_old, (255, 90, 90),
     f"BEFORE: peak {p1:.0f} > 32767, {c1:.1f}% clipped  (the harsh '炸' sound)")
draw(450, sat_new, (90, 230, 120),
     f"AFTER : peak {p2:.0f} < 32767, 0% clipped  (clean, with headroom)")
d.text((14, 620), "grey dashed = 16-bit full scale (32767).  Flat tops = clipping distortion.", fill=(160, 160, 160))

out = r"D:\download\gaoyun\day3\waveform_after_fix.png"
img.save(out)
print(f"\n对比图: {out}")
