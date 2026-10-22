# -*- coding: utf-8 -*-
"""
Markdown -> Word (.docx) 转换器（针对本报告定制）
支持: 标题/表格/代码块/列表/粗体/行内代码/分隔线/引用块
注意: 每个分支必须自行推进 i, 否则死循环
"""
import re
from docx import Document
from docx.shared import Pt, RGBColor, Cm
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

SRC = r"D:\download\gaoyun\day3\作品设计报告.md"
DST = r"D:\download\gaoyun\day3\作品设计报告.docx"

CN_FONT = "微软雅黑"
MONO_FONT = "Consolas"


def set_run_font(run, name=CN_FONT, size=10.5, bold=False, color=None):
    run.font.name = name
    run.font.size = Pt(size)
    run.bold = bold
    if color is not None:
        run.font.color.rgb = color
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = OxmlElement('w:rFonts')
        rPr.append(rFonts)
    rFonts.set(qn('w:eastAsia'), name)
    rFonts.set(qn('w:ascii'), name)
    rFonts.set(qn('w:hAnsi'), name)


def add_rich_text(par, text, base_bold=False, size=10.5):
    tokens = re.split(r'(\*\*.+?\*\*|`[^`]+`)', text)
    for tok in tokens:
        if not tok:
            continue
        if tok.startswith('**') and tok.endswith('**') and len(tok) > 4:
            r = par.add_run(tok[2:-2])
            set_run_font(r, size=size, bold=True)
        elif tok.startswith('`') and tok.endswith('`') and len(tok) > 2:
            r = par.add_run(tok[1:-1])
            set_run_font(r, name=MONO_FONT, size=size - 1, bold=base_bold)
            r.font.color.rgb = RGBColor(0xC0, 0x30, 0x30)
        else:
            r = par.add_run(tok)
            set_run_font(r, size=size, bold=base_bold)


def shade_cell(cell, hex_color="F2F2F2"):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), hex_color)
    tcPr.append(shd)


def add_code_block(doc, code_lines):
    for ln in code_lines:
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(0)
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1.0
        p.paragraph_format.left_indent = Cm(0.4)
        r = p.add_run(ln if ln else ' ')
        set_run_font(r, name=MONO_FONT, size=8.5)
        pPr = p._p.get_or_add_pPr()
        shd = OxmlElement('w:shd')
        shd.set(qn('w:val'), 'clear')
        shd.set(qn('w:color'), 'auto')
        shd.set(qn('w:fill'), 'F5F5F5')
        pPr.append(shd)


def split_table_row(line):
    s = line.strip()
    if s.startswith('|'):
        s = s[1:]
    if s.endswith('|'):
        s = s[:-1]
    return [c.strip() for c in s.split('|')]


def is_sep_row(line):
    return bool(re.match(r'^\s*\|?[\s:\-|]+\|?\s*$', line)) and '-' in line


def convert():
    with open(SRC, encoding='utf-8') as f:
        lines = f.read().split('\n')

    doc = Document()
    for section in doc.sections:
        section.top_margin = Cm(2.0)
        section.bottom_margin = Cm(2.0)
        section.left_margin = Cm(2.2)
        section.right_margin = Cm(2.2)

    normal = doc.styles['Normal']
    normal.font.name = CN_FONT
    normal.font.size = Pt(10.5)
    normal.element.rPr.rFonts.set(qn('w:eastAsia'), CN_FONT)

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()

        # ---------- 代码块 (多行, 自行推进) ----------
        if stripped.startswith('```'):
            i += 1
            code = []
            while i < n and not lines[i].strip().startswith('```'):
                code.append(lines[i])
                i += 1
            i += 1  # 跳过结束的 ```
            add_code_block(doc, code)
            doc.add_paragraph()
            continue

        # ---------- 表格 (多行, 自行推进) ----------
        if stripped.startswith('|') and i + 1 < n and is_sep_row(lines[i + 1]):
            header = split_table_row(lines[i])
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith('|'):
                rows.append(split_table_row(lines[i]))
                i += 1
            ncols = max(1, len(header))
            table = doc.add_table(rows=1, cols=ncols)
            table.style = 'Table Grid'
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            for c, txt in enumerate(header[:ncols]):
                cell = table.rows[0].cells[c]
                cell.text = ''
                p = cell.paragraphs[0]
                add_rich_text(p, txt, base_bold=True, size=9.5)
                shade_cell(cell, "DDEBF7")
            for row in rows:
                cells = table.add_row().cells
                for c in range(ncols):
                    txt = row[c] if c < len(row) else ''
                    cells[c].text = ''
                    add_rich_text(cells[c].paragraphs[0], txt, size=9)
            doc.add_paragraph()
            continue

        # ---------- 分隔线 ----------
        if stripped == '---':
            p = doc.add_paragraph()
            pPr = p._p.get_or_add_pPr()
            pbdr = OxmlElement('w:pBdr')
            bottom = OxmlElement('w:bottom')
            bottom.set(qn('w:val'), 'single')
            bottom.set(qn('w:sz'), '6')
            bottom.set(qn('w:color'), 'BFBFBF')
            pbdr.append(bottom)
            pPr.append(pbdr)
            i += 1
            continue

        # ---------- 标题 ----------
        m = re.match(r'^(#{1,4})\s+(.*)$', line)
        if m:
            level = min(len(m.group(1)), 4)
            text = m.group(2).strip()
            h = doc.add_heading(level=level)
            h.text = ''
            size = {1: 19, 2: 15, 3: 12.5, 4: 11}[level]
            color = RGBColor(0x1F, 0x3B, 0x63) if level <= 2 else RGBColor(0x2E, 0x54, 0x8A)
            r = h.add_run(text)
            set_run_font(r, size=size, bold=True, color=color)
            i += 1
            continue

        # ---------- 引用块 ----------
        if stripped.startswith('>'):
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Cm(0.6)
            add_rich_text(p, stripped.lstrip('>').strip(), size=10)
            for r in p.runs:
                r.font.color.rgb = RGBColor(0x55, 0x55, 0x55)
            i += 1
            continue

        # ---------- 无序列表 ----------
        m = re.match(r'^(\s*)[-*]\s+(.*)$', line)
        if m:
            indent = len(m.group(1)) // 2
            p = doc.add_paragraph(style='List Bullet')
            p.paragraph_format.left_indent = Cm(0.75 + indent * 0.5)
            add_rich_text(p, m.group(2).strip(), size=10.5)
            i += 1
            continue

        # ---------- 有序列表 ----------
        m = re.match(r'^(\s*)\d+\.\s+(.*)$', line)
        if m:
            indent = len(m.group(1)) // 2
            p = doc.add_paragraph(style='List Number')
            p.paragraph_format.left_indent = Cm(0.75 + indent * 0.5)
            add_rich_text(p, m.group(2).strip(), size=10.5)
            i += 1
            continue

        # ---------- 空行 ----------
        if not stripped:
            i += 1
            continue

        # ---------- 普通段落 ----------
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(4)
        add_rich_text(p, stripped, size=10.5)
        i += 1

    doc.save(DST)
    print(f"已生成: {DST}")
    print(f"段落数: {len(doc.paragraphs)}, 表格数: {len(doc.tables)}")


if __name__ == '__main__':
    convert()
