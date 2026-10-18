import os
"""生成 48kHz 采样率下的 note_lut.v（十二平均律，A4=440Hz）"""
names = ['C4','C#4','D4','D#4','E4','F4','F#4','G4','G#4','A4','A#4','B4','C5','C#5','D5','D#5']
FS = 48000.0
lines = []
print("键号  音名     频率(Hz)      FWORD")
for i, n in enumerate(names):
    semis = i - 9                      # 相对 A4 的半音数
    f = 440.0 * (2.0 ** (semis / 12.0))
    fw = int(round(f * (2**32) / FS))
    print(f"{i:2d}   {n:5s}  {f:10.4f}   {fw}")
    lines.append((i, n, f, fw))

# 生成 Verilog
out = []
out.append("`timescale 1ns/1ps")
out.append("// 键号 -> 频率控制字 (fs=48000Hz, 十二平均律, A4=440Hz)")
out.append("// FWORD = 2^32 * fout / fs")
out.append("module note_lut (")
out.append("    input  wire [5:0]  key,      // 0~15 有效, 16=无键")
out.append("    output reg  [31:0] fword")
out.append(");")
out.append("    always @(*) begin")
out.append("        case (key)")
for i, n, f, fw in lines:
    out.append(f"            6'd{i}:  fword = 32'd{fw};   // {n}  {f:.2f} Hz")
out.append("            default: fword = 32'd0;        // 静音")
out.append("        endcase")
out.append("    end")
out.append("endmodule")
out.append("")

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "src", "note_lut.v"), "w", encoding="utf-8", newline="\n") as fp:
    fp.write("\n".join(out))

print("\n已写入 src/note_lut.v")
print(f"\nA4 (440Hz) 的 FWORD = {lines[9][3]}")
