# -*- coding: utf-8 -*-
"""生成《作品设计报告》Word 文档 —— 全国大学生嵌入式芯片与系统设计竞赛(FPGA赛道)"""
from docx import Document
from docx.shared import Pt, RGBColor, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn

doc = Document()

# ---------- 全局字体 ----------
def set_font(run, cn="宋体", en="Times New Roman", size=12, bold=False, color=None):
    run.font.name = en
    run.font.size = Pt(size)
    run.font.bold = bold
    if color:
        run.font.color.rgb = color
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = rPr.makeelement(qn('w:rFonts'), {})
        rPr.append(rFonts)
    rFonts.set(qn('w:eastAsia'), cn)

def add_para(text, cn="宋体", size=12, bold=False, align=None, space_after=6, color=None):
    p = doc.add_paragraph()
    if align is not None:
        p.alignment = align
    p.paragraph_format.space_after = Pt(space_after)
    run = p.add_run(text)
    set_font(run, cn=cn, size=size, bold=bold, color=color)
    return p

def add_heading_cn(text, level=1):
    p = doc.add_heading(level=level)
    run = p.add_run(text)
    # 标题字号随级别
    size_map = {0: 22, 1: 16, 2: 14, 3: 12}
    set_font(run, cn="黑体", en="Arial", size=size_map.get(level, 12), bold=True,
             color=RGBColor(0x1F, 0x3B, 0x73) if level <= 1 else RGBColor(0x00, 0x00, 0x00))
    return p

# ================= 封面 =================
for _ in range(4):
    doc.add_paragraph()

add_para("全国大学生嵌入式芯片与系统设计竞赛", cn="黑体", size=22, bold=True,
         align=WD_ALIGN_PARAGRAPH.CENTER, color=RGBColor(0x1F, 0x3B, 0x73))
add_para("FPGA 创新设计赛道 · 作品设计报告", cn="黑体", size=18, bold=True,
         align=WD_ALIGN_PARAGRAPH.CENTER, color=RGBColor(0x1F, 0x3B, 0x73))

doc.add_paragraph()
add_para("题目：选题二　基于 FPGA 的实时多音色合成电子乐器引擎", cn="黑体", size=15, bold=True,
         align=WD_ALIGN_PARAGRAPH.CENTER)
doc.add_paragraph()
add_para("作品名称：8 声部纯硬件实时合成电子琴", cn="宋体", size=14,
         align=WD_ALIGN_PARAGRAPH.CENTER)
doc.add_paragraph()
add_para("（此处填写：参赛队伍 / 成员 / 院校 / 指导教师）", cn="宋体", size=12,
         align=WD_ALIGN_PARAGRAPH.CENTER, color=RGBColor(0x99, 0x99, 0x99))

doc.add_page_break()

# ================= 摘要 =================
add_heading_cn("摘  要", 1)
add_para(
    "本作品基于高云 GW2A-18 FPGA，实现了一款完全由硬件逻辑实时合成的多音色电子乐器引擎。"
    "系统以 4×4 矩阵键盘与旋转电位器（经 16 位 ADS1115 ADC）采集演奏动作，"
    "在 FPGA 内部搭建 8 路独立声部引擎（32 位 DDS 相位累加 + 指数 ADSR 包络 + 四种波形），"
    "经多声部混音、饱和限幅与延迟/混响/合唱三级数字效果器处理后，通过 I2S 接口（48 kHz）"
    "输出至 PCM5102A DAC 驱动扬声器发声。",
    size=12)
add_para(
    "系统实现 8 声部复音并发、4 维演奏表情（选音 / 力度 / 滑音 / 颤音）、4 种音色切换、"
    "3 种音频效果器，端到端演奏延迟约 2.7 ms（≤5 ms），并提供 4 路 LED 音区演奏指引、"
    "自动演奏（音阶 / 小星星 / 琵琶曲 / 音准测试）与按键事件录音回放等功能。"
    "音频生成通路全部由 HDL 硬件逻辑逐样本实时运算，无 CPU 参与、无预录 PCM 播放，"
    "充分发挥 FPGA 并行流水线优势。", size=12)

# ================= 一、设计背景与需求分析 =================
add_heading_cn("一、设计需求分析", 1)

add_heading_cn("1.1 赛题要求对照", 2)
add_para(
    "本作品严格对照大赛选题二《基于 FPGA 的实时多音色合成电子乐器引擎》的要求设计。"
    "各要求达成情况如下表所示：", size=12)

tbl = doc.add_table(rows=1, cols=4)
tbl.style = "Table Grid"
tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
hdr = tbl.rows[0].cells
for i, t in enumerate(["要求类别", "官方要求", "本作品实现", "达成"]):
    p = hdr[i].paragraphs[0]
    r = p.add_run(t)
    set_font(r, cn="黑体", size=10.5, bold=True)

rows_data = [
    ("基础 1",
     "≥2 个独立可控演奏维度",
     "选音 / 力度 / 滑音 / 颤音（4 维）",
     "✅"),
    ("基础 2",
     "FPGA 纯硬件实时合成，总延迟 ≤10 ms",
     "全硬件 DDS 合成，延迟约 2.7 ms",
     "✅"),
    ("基础 3",
     "复音数 ≥4，ADSR 包络、多声部混音，严禁预录",
     "8 声部复音，独立 ADSR，实时混音，无预录",
     "✅"),
    ("拓展 2",
     "≥3 维表情 + ≥2 音色 + 混响/延迟/合唱",
     "4 维表情 + 4 音色 + 3 种效果器",
     "✅"),
    ("拓展 3",
     "延迟 ≤5 ms + LED 指引/频谱/波形",
     "2.7 ms + 4 路 LED 音区指引",
     "✅"),
    ("拓展 4",
     "LED 曲目指引 + 蓝牙/手机 App",
     "LED 音区指引已有，蓝牙未实现",
     "⚠️ 部分"),
    ("拓展 1",
     "复音数 ≥32 或加成分量 ≥32",
     "复音数 8（受交互键位限制）",
     "❌ 未达成"),
]
for row in rows_data:
    cells = tbl.add_row().cells
    for i, t in enumerate(row):
        p = cells[i].paragraphs[0]
        r = p.add_run(t)
        set_font(r, cn="宋体", size=10)

add_para("", size=6)

add_heading_cn("1.2 关键设计指标", 2)
spec_rows = [
    ("复音数", "8（8 路独立振荡器并行）"),
    ("音频采样率", "48.000 kHz（相位累加小数分频，误差 < 0.001%）"),
    ("音准基准", "A4 = 440 Hz，频率分辨率 0.011 Hz"),
    ("音域 / 音色", "C4~C5 一个八度 × 4 种波形（正弦/三角/锯齿/方波）"),
    ("演奏表情", "力度（ADC 16bit）/ 滑音 / 颤音（6Hz LFO）"),
    ("效果器", "延迟（85ms）/ 混响（21ms）/ 合唱（12.5ms+LFO）"),
    ("端到端延迟", "约 2.7 ms（键盘 1ms + I2S 0.67ms + DAC 1ms）"),
    ("输出接口", "I2S 主模式：BCK 3.072MHz / LRCK 48kHz / DATA 16bit"),
    ("可视化", "4 路 LED 音区演奏指引"),
    ("资源占用", "LUT 52% / DSP 69% / BSRAM 14% / Register 9%"),
]
stbl = doc.add_table(rows=1, cols=2)
stbl.style = "Table Grid"
h = stbl.rows[0].cells
for i, t in enumerate(["指标", "参数"]):
    r = h[i].paragraphs[0].add_run(t)
    set_font(r, cn="黑体", size=10.5, bold=True)
for k, v in spec_rows:
    cs = stbl.add_row().cells
    r = cs[0].paragraphs[0].add_run(k)
    set_font(r, cn="黑体", size=10)
    r = cs[1].paragraphs[0].add_run(v)
    set_font(r, cn="宋体", size=10)

doc.add_page_break()

# ================= 二、系统总体方案 =================
add_heading_cn("二、系统总体方案", 1)

add_heading_cn("2.1 系统架构", 2)
add_para(
    "系统采用纯硬件流水线架构，数据从演奏采集到音频输出全程单向流动，无软件轮询、无操作系统调度。"
    "总体信号链路如下：", size=12)

arch_lines = [
    ("一、输入采集", True),
    (" 4×4 矩阵键盘  ──→  三态扫描  ──→  16 位按键位图", False),
    (" 旋转电位器    ──→  ADS1115 ADC（16 bit）──→  力度值（平方律曲线）", False),
    ("                    ↓", False),
    ("二、实时合成（48 kHz 逐样本，全硬件）", True),
    (" 音符事件 + 力度  ──→  8× 声部引擎（32 位 DDS + 指数 ADSR + 波形选择）", False),
    ("                    ↓", False),
    ("三、混音与处理", True),
    (" 多声部混音  ──→  饱和限幅  ──→  效果器（延迟 / 混响 / 合唱）──→  主音量", False),
    ("                    ↓", False),
    ("四、音频输出", True),
    (" I2S 发送（BCK/LRCK/DATA）──→ PCM5102A DAC ──→ PAM8403 ──→ 扬声器", False),
]
for ln, is_stage in arch_lines:
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(1)
    r = p.add_run(ln)
    set_font(r, cn="黑体" if is_stage else "宋体", size=10, bold=is_stage)

add_para("", size=4)
add_para(
    "其中「声部引擎」是整个系统的核心：每个声部包含独立的 32 位相位累加器、频率控制字、"
    "ADSR 包络状态机与波形选择，8 路完全并行、逐样本（48 kHz）实时运算。", size=12)

add_heading_cn("2.2 模块划分", 2)
mod_rows = [
    ("模块", "功能", "关键技术"),
    ("键盘扫描", "检测 16 键按下状态", "三态行驱动，250µs/行，无同列短路"),
    ("力度采集", "ADC 模拟量 → 力度值", "ADS1115 I2C，平方律曲线，1/8 平滑"),
    ("声部引擎 ×8", "DDS 振荡 + 包络 + 波形", "32 位相位累加，指数 ADSR，4 波形"),
    ("混音限幅", "多声部求和", "19 位求和 + 饱和限幅，预留 headroom"),
    ("效果器", "延迟/混响/合唱", "BRAM 延迟线 + 反馈 + LFO 调制"),
    ("I2S 发送", "PCM → 串行三线", "精确 48kHz 小数分频"),
    ("可视化", "音区指引", "4 路 LED 对应 4 个音区"),
    ("演奏辅助", "自动播放/录音回放", "音符 ROM / 按键事件记录回放"),
]
mtbl = doc.add_table(rows=1, cols=3)
mtbl.style = "Table Grid"
hh = mtbl.rows[0].cells
for i, t in enumerate(mod_rows[0]):
    r = hh[i].paragraphs[0].add_run(t)
    set_font(r, cn="黑体", size=10.5, bold=True)
for row in mod_rows[1:]:
    cs = mtbl.add_row().cells
    for i, t in enumerate(row):
        r = cs[i].paragraphs[0].add_run(t)
        set_font(r, cn="宋体", size=10)

doc.add_page_break()

# ================= 三、核心模块设计 =================
add_heading_cn("三、核心模块设计（HDL 实现）", 1)

add_heading_cn("3.1 键盘扫描（三态行驱动）", 2)
add_para(
    "4×4 矩阵键盘由 4 根行线（输出）与 4 根列线（输入，内部上拉）构成。传统做法是未扫描的行输出"
    "高电平，但当同一列的两个键同时按下时，列线会被扫描行（0V）与未扫描行（3.3V）同时强驱动，"
    "造成短路、电平不确定，导致同列多键无法识别。本设计将未扫描行改为「高阻输出」（三态），"
    "只有当前扫描行拉低，从根本上消除短路。扫描节拍为 250µs/行，一轮 1 ms，显著降低检测延迟。", size=12)

add_heading_cn("3.2 力度采集（ADS1115 ADC）", 2)
add_para(
    "力度旋钮（旋转电位器）输出模拟电压，经 ADS1115（16 位、I2C、单端 A0 通道、PGA ±4.096V、"
    "128SPS）采样。FPGA 侧自建 I2C 主机（100 kHz）完成配置与读取。ADC 数值经 256 点平方律曲线"
    "映射为力度系数（使听感响度近似线性），并对相邻采样做 1/8 步进平滑，抑制噪声抖动。", size=12)

add_heading_cn("3.3 声部引擎：DDS + ADSR + 波形", 2)
add_para(
    "每个声部是一个完整振荡器：", size=12)
bullet_items = [
    "DDS：32 位相位累加器。频率控制字 FWORD = 2³² × f / 48000，频率分辨率 0.011 Hz；"
    "A4=440Hz 对应的 FWORD = 39,370,534，音准极高。",
    "ADSR：指数包络（Attack / Decay / Sustain / Release）。衰减采用 env - (env >> N) 实现指数曲线，"
    "比线性衰减更接近真实乐器；不同音色预设对应不同 ADSR 参数组。",
    "波形：256 点正弦查表 + 方波/三角/锯齿的组合逻辑生成，覆盖 4 种基础波形。",
    "表情：滑音（频率渐变，约 0.3 ms 到位）与颤音（6 Hz 正弦 LFO 调制频率，深度约 ±0.4%）。",
]
for b in bullet_items:
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(b)
    set_font(r, cn="宋体", size=11)

add_heading_cn("3.4 混音与限幅", 2)
add_para(
    "8 路声部采样做 19 位带符号求和，再经饱和限幅到 16 位。为避免多声部叠加削顶（clipping），"
    "单声部采样幅度预设为满幅的 50%（预留 headroom），使 4 声部以内不产生削顶失真，"
    "保证大动态和弦下音色清晰、无刺耳谐波。", size=12)

add_heading_cn("3.5 数字音频效果器", 2)
add_para(
    "效果器通过 BRAM 实现延迟线（同步读写），共三种，可循环切换：", size=12)
fx_items = [
    "延迟（Echo）：4096 采样（85 ms），反馈 1/2，湿声 1/4 —— 清晰可数回声。",
    "混响（Reverb）：1024 采样（21 ms），反馈 3/4，湿声 1/2 —— 密集回声融合成空间感。",
    "合唱（Chorus）：1024 采样延迟线，延迟时间被 0.5 Hz LFO 调制，与原声 1:1 混合 —— 声音增厚。",
]
for b in fx_items:
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(b)
    set_font(r, cn="宋体", size=11)

add_heading_cn("3.6 I2S 发送与精确 48 kHz 时基", 2)
add_para(
    "I2S 主模式输出 BCK / LRCK / DATA 三线。为获得精确的 48 kHz 采样率，采用相位累加小数分频："
    "以 K=3817749 在 27 MHz 主时钟下累加，溢出翻转 BCK，得到 BCK=3.072 MHz、LRCK=48.000 Hz、"
    "BCK/LRCK=64。LRCK 与 DIN 在 BCK 下降沿变化，数据为 1 位无效位 + 16 位数据（MSB 先行）。"
    "这种小数分频使采样率误差 < 0.001%，远优于整数分频。", size=12)

add_heading_cn("3.7 可视化与演奏辅助", 2)
add_para(
    "可视化：4 路 LED 对应 4 个音区（哆唻/咪发/唆拉/西哆），按键或自动播放时对应音区灯亮，"
    "实现「LED 演奏指引」；上电前 5 秒全部点亮作自检。", size=12)
add_para(
    "自动演奏：内置音阶、《小星星》、《琵琶曲（东船与西舫）》、音准测试四种模式，"
    "以 ROM 存储「音高 + 时值」音符参数，播放时逐音符送入声部引擎实时合成（非预录 PCM）。", size=12)
add_para(
    "录音回放：以 20 ms 周期采样 8 位按键位图存入 BRAM（容量 40 秒），回放时用记录事件重新驱动"
    "声部实时合成，符合「严禁整段录音触发」的合规要求。", size=12)

doc.add_page_break()

# ================= 四、关键指标与测试 =================
add_heading_cn("四、关键指标与测试数据", 1)

add_heading_cn("4.1 复音数与吞吐量", 2)
add_para(
    "本设计集成 8 个完整独立振荡器（各自含相位累加器、频率控制、包络控制），可同时活跃发声。"
    "系统吞吐量 = 同时活跃可闻振荡器总数 × 采样率 = 8 × 48000 = 384,000 振荡器·样本/秒。"
    "现场验证时，测试模式下可同时输出 8 路不同频率，频谱可观察到 8 个独立谱峰。", size=12)

add_heading_cn("4.2 演奏延迟预算", 2)
lat_rows = [
    ("环节", "延迟", "说明"),
    ("键盘扫描", "最坏 1 ms", "250µs/行 × 4 行，扫到即更新"),
    ("声部分配 + DDS + ADSR", "< 21 µs", "组合逻辑 + 48kHz 同步更新"),
    ("混音 + 限幅 + 效果器", "< 21 µs", "组合逻辑 + BRAM 同步读"),
    ("I2S 串行发送", "约 0.67 ms", "48kHz × 32 位帧"),
    ("PCM5102A 转换", "约 1 ms", "芯片内部流水（手册）"),
    ("合计", "≈ 2.7 ms", "≤ 5 ms，确定性无抖动"),
]
ltbl = doc.add_table(rows=1, cols=3)
ltbl.style = "Table Grid"
hh = ltbl.rows[0].cells
for i, t in enumerate(lat_rows[0]):
    r = hh[i].paragraphs[0].add_run(t)
    set_font(r, cn="黑体", size=10.5, bold=True)
for row in lat_rows[1:]:
    cs = ltbl.add_row().cells
    for i, t in enumerate(row):
        r = cs[i].paragraphs[0].add_run(t)
        set_font(r, cn="宋体", size=10)

add_para(
    "优化措施：键盘扫描节拍由 1 ms/行降至 250 µs/行，位图由整轮锁存改为逐行立即更新，"
    "使键盘检测延迟由 4 ms 降至 1 ms。全同步设计无 CPU 调度与中断，延迟恒定无抖动。", size=11)

add_heading_cn("4.3 频率准确度", 2)
add_para(
    "DDS 采用 32 位相位累加，频率分辨率 0.011 Hz；采样率由相位累加小数分频精确生成，误差 < 0.001%；"
    "音符映射采用十二平均律（相邻半音比 2^(1/12)）。理论最大误差仅来源于小数分频的舍入，"
    "实测各音误差应远小于 0.5%（详见随附《音准测量表》）。", size=12)

add_heading_cn("4.4 资源占用", 2)
res_rows = [
    ("资源", "占用", "利用率"),
    ("Logic", "10582 / 20736", "52%"),
    ("Register", "1392 / 15552", "9%"),
    ("CLS (进位链)", "5896 / 10368", "57%"),
    ("BSRAM", "6 / 46", "14%"),
    ("DSP (18×18)", "16.5 / 24", "69%"),
    ("I/O", "19 / 207", "10%"),
]
rtbl = doc.add_table(rows=1, cols=3)
rtbl.style = "Table Grid"
hh = rtbl.rows[0].cells
for i, t in enumerate(res_rows[0]):
    r = hh[i].paragraphs[0].add_run(t)
    set_font(r, cn="黑体", size=10.5, bold=True)
for row in res_rows[1:]:
    cs = rtbl.add_row().cells
    for i, t in enumerate(row):
        r = cs[i].paragraphs[0].add_run(t)
        set_font(r, cn="宋体", size=10)

add_para(
    "时序约束已配置（27 MHz 主时钟），综合布局布线无警告。资源仍有较大余量，"
    "具备扩展（如复音数、更多效果器）的空间。", size=11)

# ================= 五、创新点 =================
add_heading_cn("五、技术亮点与创新点", 1)
highlights = [
    ("三态矩阵扫描", "未扫描行输出高阻而非高电平，彻底消除同列多键同时按下造成的短路，支持任意组合键并发识别。"),
    ("精确 48kHz 小数分频", "相位累加小数分频（K=3817749）替代整数分频，采样率误差 < 0.001%，从时基根除音准漂移。"),
    ("指数 ADSR", "env - (env >> N) 实现指数衰减，比线性衰减更接近真实乐器的起音/尾音听感。"),
    ("软削顶 headroom 设计", "单声部预设为满幅 50%，混音预留电平余量，多声部叠加不削顶，保证和弦音色清晰。"),
    ("效果器参数化", "同一条 BRAM 延迟线，通过反馈系数与延迟长度区分「回声」与「混响」，合唱另用 LFO 调制，三种效果器共享架构。"),
    ("事件化录音", "不录 PCM 音频，只记录 20ms 采样的按键事件（40 秒仅 2KB），回放时实时重合成，既合规又极省资源。"),
]
for title, desc in highlights:
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(title + "：")
    set_font(r, cn="黑体", size=11, bold=True)
    r2 = p.add_run(desc)
    set_font(r2, cn="宋体", size=11)

# ================= 六、结论 =================
add_heading_cn("六、总结", 1)
add_para(
    "本作品完整实现了基于 FPGA 的实时多音色合成电子乐器引擎，基础要求全部达成，"
    "拓展要求（多维表情、效果器、低延迟可视化）基本达成。系统以纯硬件并行流水线架构，"
    "实现 8 声部复音、4 维表情、4 音色、3 效果器，端到端延迟约 2.7 ms，充分发挥了 FPGA "
    "并行计算的实时性优势。后续可通过增加键盘位宽或采用电容触摸阵列扩大复音数，"
    "进一步逼近拓展要求中的 32 复音并发目标。", size=12)

add_para("", size=8)
add_para("（附：源码与工程文件见随附压缩包 / GitHub 仓库，含顶层模块、各子模块 HDL、"
         "引脚与时序约束、资源报告。）", cn="宋体", size=10, color=RGBColor(0x66, 0x66, 0x66))

doc.save(r"D:\download\gaoyun\day3\作品设计报告.docx")
print("已生成 作品设计报告.docx")