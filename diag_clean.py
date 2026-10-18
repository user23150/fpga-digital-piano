# -*- coding: utf-8 -*-
"""诊断版: 1)固定力度(排除ADC噪声) 2)去掉滑音(排除音高滑动噪声)"""
pt = r"D:\download\gaoyun\day3\gen_single_top.py"
with open(pt, encoding="utf-8") as f:
    ct = f.read()

# 1) 固定力度, 不用 ADC
old1 = '''a("    reg [11:0] loud;      // 力度系数 1024(25%) ~ 4095(100%)")
a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n)          loud <= 12'd4095;")
a("        else if (adc_ok)     loud <= 12'd1024 + vol_inc;")
a("    end")'''
new1 = '''a("    reg [11:0] loud;      // [诊断版] 固定力度, 排除 ADC 噪声")
a("    always @(posedge clk or negedge rst_n) begin")
a("        if (!rst_n) loud <= 12'd4095;")
a("        else        loud <= 12'd4095;      // 暂时固定, 不用 ADC")
a("    end")'''
assert old1 in ct, "loud 锚点没找到"
ct = ct.replace(old1, new1)

# 2) 自动播放的混响也先关掉(排除)
old2 = 'a("    wire auto_verb = (play_mode == 3\'d2 || play_mode == 3\'d3);")'
new2 = 'a("    wire auto_verb = 1\'b0;   // [诊断版] 暂时关闭自动混响")'
assert old2 in ct, "auto_verb 锚点没找到"
ct = ct.replace(old2, new2)

with open(pt, "w", encoding="utf-8", newline="\n") as f:
    f.write(ct)
print("1. 力度固定 4095 (排除 ADC 噪声)")
print("2. 自动混响关闭 (排除效果器)")

# 3) 去掉滑音: cur_fw 直接等于 fword
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
a("        else if (tick_sample) cur_fw <= fword;   // [诊断版] 无滑音, 音高直接到位")
a("    end")'''
assert old3 in cv, "滑音锚点没找到"
cv = cv.replace(old3, new3)

with open(pv, "w", encoding="utf-8", newline="\n") as f:
    f.write(cv)
print("3. 滑音关闭 (音高直接到位)")
