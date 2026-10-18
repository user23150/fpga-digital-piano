# -*- coding: utf-8 -*-
"""诊断版 v2: 完全禁用ADC力度 + 去掉滑音"""
pt = r"D:\download\gaoyun\day3\gen_single_top.py"
with open(pt, encoding="utf-8") as f:
    ct = f.read()

old1 = '''a("    // 力度系数: 加低通平滑, 避免 ADC 单次噪声造成 100Hz 音量抖动(听感'啵啵')")
a("    reg [11:0] loud;")
a("    wire [11:0] vol_new = 12'd768 + {1'b0, vol_inc[11:1]};   // 上限约 70%%, 给和弦留余量")
a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n) loud <= 12'd4095;")
a("        else if (adc_ok) begin")
a("            if (vol_new > loud)")
a("                loud <= loud + ((vol_new - loud) >> 3);   // 1/8 步进逼近")
a("            else")
a("                loud <= loud - ((loud - vol_new) >> 3);")
a("        end")
a("    end")'''
new1 = '''a("    // [诊断版] 力度固定 4095, 完全不用 ADC (排除 ADC/I2C 干扰)")
a("    reg [11:0] loud;")
a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n) loud <= 12'd4095;")
a("        else        loud <= 12'd4095;")
a("    end")'''
assert old1 in ct, "loud 锚点没找到"
ct = ct.replace(old1, new1)

old2 = 'a("    wire auto_verb = (play_mode == 3\'d2 || play_mode == 3\'d3);")'
new2 = 'a("    wire auto_verb = 1\'b0;   // [诊断版] 关闭自动混响")'
if old2 in ct:
    ct = ct.replace(old2, new2)
    print("   自动混响已关")
else:
    print("   (自动混响已是关闭状态)")

with open(pt, "w", encoding="utf-8", newline="\n") as f:
    f.write(ct)
print("1. ADC 力度: 完全禁用 (loud 固定 4095)")

# ---- 去掉滑音 ----
pv = r"D:\download\gaoyun\day3\gen_voice.py"
with open(pv, encoding="utf-8") as f:
    cv = f.read()

old3 = '''a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n) cur_fw <= 32'd0;")
a("        else if (tick_sample) begin")
a("            if (env_rst)")
a("                cur_fw <= fword;            // 换音: 音高立即到位(不要滑音, 否则旋律会飘)")
a("            else if (cur_fw < fword - GLIDE_STEP)")
a("                cur_fw <= cur_fw + GLIDE_STEP;")
a("            else if (cur_fw > fword + GLIDE_STEP)")
a("                cur_fw <= cur_fw - GLIDE_STEP;")
a("            else")
a("                cur_fw <= fword;")
a("        end")
a("    end")'''
new3 = '''a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n) cur_fw <= 32'd0;")
a("        else if (tick_sample) cur_fw <= fword;   // [诊断版] 无滑音")
a("    end")'''
assert old3 in cv, "滑音锚点没找到"
cv = cv.replace(old3, new3)

with open(pv, "w", encoding="utf-8", newline="\n") as f:
    f.write(cv)
print("2. 滑音: 关闭 (音高直接到位)")
