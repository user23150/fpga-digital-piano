`timescale 1ns/1ps
// ============================================================================
//  FPGA 电子琴 —— 8 声部复音版
//
//  信号链: 4x4键盘 -> 按键位图 -> 8个独立声部(DDS+ADSR+波形) -> 混音限幅
//          -> I2S -> PCM5102A -> 功放 -> 喇叭
//
//  键盘布局(4x4):
//    行0:  哆 唻 咪 发        (C4 D4 E4 F4)
//    行1:  唆 拉 西 哆        (G4 A4 B4 C5)
//    行2:  正弦 方波 三角 锯齿 (音色切换)
//    行3:  预留功能键
//
//  板载按键 T6: 自动播放开关 (按一下播放音阶, 再按停止)
//  采样率: 精确 48000Hz   音准: A4 = 440.00Hz
// ============================================================================
module top (
    input  wire       clk,        // 27MHz 晶振
    input  wire       key_t6,     // 板载按键 T6: 自动播放开关
    input  wire [3:0] key_col,    // 矩阵键盘 列输入
    output wire [3:0] key_row,    // 矩阵键盘 行输出 (三态: 扫描行拉低, 其余高阻)
    output wire       i2s_bck,    // I2S 位时钟   -> PCM5102A
    output wire       i2s_lrck,   // I2S 声道时钟 -> PCM5102A
    output wire       i2s_din,    // I2S 数据     -> PCM5102A
    inout  wire       i2c_sda,    // ADS1115 SDA  <-> H12
    output wire       i2c_scl,    // ADS1115 SCL  ->  G11
    output wire [3:0] led         // 4 路 LED 电平表 (可视化反馈)
);

    // ========================================================================
    // 0) 上电自动复位 (约 39ms), T6 不再做复位, 改为功能按键
    // ========================================================================
    reg [19:0] por_cnt;
    reg        rst_n;
    always @(posedge clk) begin
        if (por_cnt != 20'hFFFFF) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else
            rst_n   <= 1'b1;
    end

    // ========================================================================
    // 1) 板载按键 T6: 消抖 + 按下沿 -> 切换自动播放
    // ========================================================================
    reg  [1:0]  t6_sync;
    reg  [19:0] t6_cnt;
    reg         t6_deb, t6_deb_p;
    reg  [2:0]  play_mode;      // 0=停 1=音阶 2=小星星 3=琵琶曲 4=音准测试
    wire        play_on = (play_mode != 2'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t6_sync  <= 2'b11;
            t6_cnt   <= 20'd0;
            t6_deb   <= 1'b1;
            t6_deb_p <= 1'b1;
            play_mode <= 2'd0;
        end else begin
            t6_sync <= {t6_sync[0], key_t6};
            if (t6_sync[1] == t6_deb)
                t6_cnt <= 20'd0;
            else begin
                t6_cnt <= t6_cnt + 1'b1;
                if (t6_cnt >= 20'd269999) begin    // 10ms
                    t6_deb <= t6_sync[1];
                    t6_cnt <= 20'd0;
                end
            end
            t6_deb_p <= t6_deb;
            if (t6_deb_p && !t6_deb)
                play_mode <= (play_mode == 3'd4) ? 3'd0 : play_mode + 1'b1;  // 五态循环
        end
    end

    // ========================================================================
    // 2) 键盘扫描: 1ms 换一行, 输出 16 位按键状态位图(支持多键同时按)
    // ========================================================================
    reg [14:0] cnt_ms;
    wire tick_ms = (cnt_ms == 15'd26999);

    // ---- 键盘扫描节拍: 250us (每行 250us, 一轮 1ms) ----
    //      原来是 1ms/行(一轮 4ms), 这是演奏延迟的主要来源
    reg [13:0] cnt_scan;
    wire tick_scan = (cnt_scan == 14'd6749);      // 250us @27MHz
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          cnt_scan <= 14'd0;
        else if (tick_scan)  cnt_scan <= 14'd0;
        else                 cnt_scan <= cnt_scan + 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        cnt_ms <= 15'd0;
        else if (tick_ms)  cnt_ms <= 15'd0;
        else               cnt_ms <= cnt_ms + 1'b1;
    end

    reg [1:0] scan_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        scan_row <= 2'd0;
        else if (tick_scan) scan_row <= scan_row + 1'b1;
    end

    // ---- 三态行驱动: 只有当前扫描行输出低, 其余行输出高阻 ----
    //      推挽输出(1110/1101...)会让'同列两键齐按'时列线被 0V 和 3.3V
    //      同时强驱 -> 短路 -> 读不到。改三态后不再冲突。
    wire [3:0] row_oe = 4'b0001 << scan_row;
    assign key_row[0] = row_oe[0] ? 1'b0 : 1'bz;
    assign key_row[1] = row_oe[1] ? 1'b0 : 1'bz;
    assign key_row[2] = row_oe[2] ? 1'b0 : 1'bz;
    assign key_row[3] = row_oe[3] ? 1'b0 : 1'bz;

    // 按键位图: 逐行采样 + 3 轮消抖
    //   raw: 每 250us 更新对应 4 位;  kst: 连续 3 轮(3ms)相同才更新
    //   -> 消除机械抖动造成的 gate 抖动(长按断续 / 啵啵声)
    reg [15:0] kst_raw;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) kst_raw <= 16'd0;
        else if (tick_scan) begin
            case (scan_row)
                2'd0: kst_raw[3:0]   <= ~key_col;
                2'd1: kst_raw[7:4]   <= ~key_col;
                2'd2: kst_raw[11:8]  <= ~key_col;
                2'd3: kst_raw[15:12] <= ~key_col;
            endcase
        end
    end

    reg [15:0] kst, kst_p1, kst_p2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kst <= 16'd0; kst_p1 <= 16'd0; kst_p2 <= 16'd0;
        end else if (tick_scan && scan_row == 2'd0) begin   // 每轮末尾比较
            kst_p1 <= kst_raw;
            kst_p2 <= kst_p1;
            if (kst_raw == kst_p1 && kst_p1 == kst_p2)
                kst <= kst_raw;                              // 3 轮稳定 -> 生效
        end
    end

    // ---- 乐器预设: 键8=钢琴 键9=风琴 键10=弦乐 键11=木琴 ----
    reg [1:0] preset;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       preset <= 2'd3;   // 默认正弦(最柔和, 无''滋滋''谐波)
        else if (kst[8])  preset <= 2'd0;   // 钢琴(锯齿)
        else if (kst[9])  preset <= 2'd1;   // 风琴(方波)
        else if (kst[10]) preset <= 2'd2;   // 弦乐(锯齿)
        else if (kst[11]) preset <= 2'd3;   // 木琴(三角)
    end

    // ========================================================================
    // 3) 8 个音符的频率控制字 (键0~7)
    // ========================================================================
    wire [31:0] fw0 = 32'd23409859;   // C4 哆
    wire [31:0] fw1 = 32'd26276679;   // D4 唻
    wire [31:0] fw2 = 32'd29494575;   // E4 咪
    wire [31:0] fw3 = 32'd31248413;   // F4 发
    wire [31:0] fw4 = 32'd35075158;   // G4 唆
    wire [31:0] fw5 = 32'd39370534;   // A4 拉
    wire [31:0] fw6 = 32'd44191930;   // B4 西
    wire [31:0] fw7 = 32'd46819719;   // C5 哆高

    // ========================================================================
    // 4) 自动音阶播放 (T6 开关): 哆 唻 咪 发 唆 拉 西 哆, 每音 0.5 秒
    // ========================================================================
    reg [23:0] cnt_note;
    reg [2:0]  note_idx;
    wire tick_note = (cnt_note == 24'd13499999);   // 0.5s @27MHz
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_note <= 24'd0;
            note_idx <= 3'd0;
        end else if (!play_on) begin
            cnt_note <= 24'd0;
            note_idx <= 3'd0;
        end else if (tick_note) begin
            cnt_note <= 24'd0;
            note_idx <= note_idx + 1'b1;
        end else
            cnt_note <= cnt_note + 1'b1;
    end

    reg [31:0] fword_scale;
    always @(*) begin
        case (note_idx)
            3'd0:    fword_scale = 32'd23409859;   // C4 哆
            3'd1:    fword_scale = 32'd26276679;   // D4 唻
            3'd2:    fword_scale = 32'd29494575;   // E4 咪
            3'd3:    fword_scale = 32'd31248413;   // F4 发
            3'd4:    fword_scale = 32'd35075158;   // G4 唆
            3'd5:    fword_scale = 32'd39370534;   // A4 拉
            3'd6:    fword_scale = 32'd44191930;   // B4 西
            3'd7:    fword_scale = 32'd46819719;   // C5 哆高
            default: fword_scale = 32'd0;
        endcase
    end

    // ========================================================================
    // 4a) 内置演示曲目《小星星》
    //     每个音符 8 位: [7:4]=音名索引(0~7), [3:0]=时长(0.25s 为单位)
    // ========================================================================
    reg [7:0] song_rom [0:255];     // [0:41]=小星星  [64:142]=琵琶曲
    initial begin
        song_rom[ 0] = 8'h02;
        song_rom[ 1] = 8'h02;
        song_rom[ 2] = 8'h42;
        song_rom[ 3] = 8'h42;
        song_rom[ 4] = 8'h52;
        song_rom[ 5] = 8'h52;
        song_rom[ 6] = 8'h43;
        song_rom[ 7] = 8'h32;
        song_rom[ 8] = 8'h32;
        song_rom[ 9] = 8'h22;
        song_rom[10] = 8'h22;
        song_rom[11] = 8'h12;
        song_rom[12] = 8'h12;
        song_rom[13] = 8'h03;
        song_rom[14] = 8'h42;
        song_rom[15] = 8'h42;
        song_rom[16] = 8'h32;
        song_rom[17] = 8'h32;
        song_rom[18] = 8'h22;
        song_rom[19] = 8'h22;
        song_rom[20] = 8'h13;
        song_rom[21] = 8'h42;
        song_rom[22] = 8'h42;
        song_rom[23] = 8'h32;
        song_rom[24] = 8'h32;
        song_rom[25] = 8'h22;
        song_rom[26] = 8'h22;
        song_rom[27] = 8'h13;
        song_rom[28] = 8'h02;
        song_rom[29] = 8'h02;
        song_rom[30] = 8'h42;
        song_rom[31] = 8'h42;
        song_rom[32] = 8'h52;
        song_rom[33] = 8'h52;
        song_rom[34] = 8'h43;
        song_rom[35] = 8'h32;
        song_rom[36] = 8'h32;
        song_rom[37] = 8'h22;
        song_rom[38] = 8'h22;
        song_rom[39] = 8'h12;
        song_rom[40] = 8'h12;
        song_rom[41] = 8'h03;
        song_rom[42] = 8'hFF;
        song_rom[43] = 8'hFF;
        song_rom[44] = 8'hFF;
        song_rom[45] = 8'hFF;
        song_rom[46] = 8'hFF;
        song_rom[47] = 8'hFF;
        song_rom[48] = 8'hFF;
        song_rom[49] = 8'hFF;
        song_rom[50] = 8'hFF;
        song_rom[51] = 8'hFF;
        song_rom[52] = 8'hFF;
        song_rom[53] = 8'hFF;
        song_rom[54] = 8'hFF;
        song_rom[55] = 8'hFF;
        song_rom[56] = 8'hFF;
        song_rom[57] = 8'hFF;
        song_rom[58] = 8'hFF;
        song_rom[59] = 8'hFF;
        song_rom[60] = 8'hFF;
        song_rom[61] = 8'hFF;
        song_rom[62] = 8'hFF;
        song_rom[63] = 8'hFF;
        song_rom[ 64] = 8'h42;
        song_rom[ 65] = 8'h52;
        song_rom[ 66] = 8'h42;
        song_rom[ 67] = 8'h22;
        song_rom[ 68] = 8'h42;
        song_rom[ 69] = 8'h22;
        song_rom[ 70] = 8'h52;
        song_rom[ 71] = 8'h42;
        song_rom[ 72] = 8'h52;
        song_rom[ 73] = 8'h42;
        song_rom[ 74] = 8'h22;
        song_rom[ 75] = 8'h42;
        song_rom[ 76] = 8'h22;
        song_rom[ 77] = 8'h12;
        song_rom[ 78] = 8'h22;
        song_rom[ 79] = 8'h12;
        song_rom[ 80] = 8'h52;
        song_rom[ 81] = 8'h22;
        song_rom[ 82] = 8'h12;
        song_rom[ 83] = 8'h42;
        song_rom[ 84] = 8'h52;
        song_rom[ 85] = 8'h42;
        song_rom[ 86] = 8'h22;
        song_rom[ 87] = 8'h42;
        song_rom[ 88] = 8'h22;
        song_rom[ 89] = 8'h52;
        song_rom[ 90] = 8'h22;
        song_rom[ 91] = 8'h51;
        song_rom[ 92] = 8'h41;
        song_rom[ 93] = 8'h21;
        song_rom[ 94] = 8'h41;
        song_rom[ 95] = 8'h21;
        song_rom[ 96] = 8'h51;
        song_rom[ 97] = 8'h41;
        song_rom[ 98] = 8'h51;
        song_rom[ 99] = 8'h41;
        song_rom[100] = 8'h21;
        song_rom[101] = 8'h41;
        song_rom[102] = 8'h21;
        song_rom[103] = 8'h21;
        song_rom[104] = 8'h21;
        song_rom[105] = 8'h51;
        song_rom[106] = 8'h21;
        song_rom[107] = 8'h11;
        song_rom[108] = 8'h41;
        song_rom[109] = 8'h51;
        song_rom[110] = 8'h41;
        song_rom[111] = 8'h21;
        song_rom[112] = 8'h41;
        song_rom[113] = 8'h21;
        song_rom[114] = 8'h11;
        song_rom[115] = 8'h21;
        song_rom[116] = 8'h11;
        song_rom[117] = 8'h21;
        song_rom[118] = 8'h51;
        song_rom[119] = 8'hF1;
        song_rom[120] = 8'h41;
        song_rom[121] = 8'h51;
        song_rom[122] = 8'h01;
        song_rom[123] = 8'h11;
        song_rom[124] = 8'h21;
        song_rom[125] = 8'h51;
        song_rom[126] = 8'hF1;
        song_rom[127] = 8'h41;
        song_rom[128] = 8'h51;
        song_rom[129] = 8'h01;
        song_rom[130] = 8'h11;
        song_rom[131] = 8'h21;
        song_rom[132] = 8'h51;
        song_rom[133] = 8'h01;
        song_rom[134] = 8'h51;
        song_rom[135] = 8'h41;
        song_rom[136] = 8'h51;
        song_rom[137] = 8'h01;
        song_rom[138] = 8'h11;
        song_rom[139] = 8'h21;
        song_rom[140] = 8'h41;
        song_rom[141] = 8'hF1;
        song_rom[142] = 8'h51;
        song_rom[143] = 8'h41;
        song_rom[144] = 8'h21;
        song_rom[145] = 8'h41;
        song_rom[146] = 8'h51;
        song_rom[147] = 8'h21;
        song_rom[148] = 8'h11;
        song_rom[149] = 8'hF1;
        song_rom[150] = 8'h51;
        song_rom[151] = 8'h41;
        song_rom[152] = 8'h21;
        song_rom[153] = 8'h41;
        song_rom[154] = 8'h21;
        song_rom[155] = 8'h11;
        song_rom[156] = 8'h01;
        song_rom[157] = 8'hF1;
        song_rom[158] = 8'h21;
        song_rom[159] = 8'h11;
        song_rom[160] = 8'h21;
        song_rom[161] = 8'h51;
        song_rom[162] = 8'h41;
        song_rom[163] = 8'h51;
        song_rom[164] = 8'h01;
        song_rom[165] = 8'h11;
        song_rom[166] = 8'h51;
        song_rom[167] = 8'h11;
        song_rom[168] = 8'h01;
        song_rom[169] = 8'h51;
        song_rom[170] = 8'hFF;
        song_rom[171] = 8'hFF;
        song_rom[172] = 8'hFF;
        song_rom[173] = 8'hFF;
        song_rom[174] = 8'hFF;
        song_rom[175] = 8'hFF;
        song_rom[176] = 8'hFF;
        song_rom[177] = 8'hFF;
        song_rom[178] = 8'hFF;
        song_rom[179] = 8'hFF;
        song_rom[180] = 8'hFF;
        song_rom[181] = 8'hFF;
        song_rom[182] = 8'hFF;
        song_rom[183] = 8'hFF;
        song_rom[184] = 8'hFF;
        song_rom[185] = 8'hFF;
        song_rom[186] = 8'hFF;
        song_rom[187] = 8'hFF;
        song_rom[188] = 8'hFF;
        song_rom[189] = 8'hFF;
        song_rom[190] = 8'hFF;
        song_rom[191] = 8'hFF;
    end

    reg [7:0]  song_ptr;

    // 播放范围: 模式3 = 琵琶曲(64起,79音), 其它 = 小星星(0起,42音)
    wire [7:0] song_start = (play_mode == 3'd3) ? 8'd64 : 8'd0;
    wire [7:0] song_last  = (play_mode == 3'd3) ? 8'd142 : 8'd41;
    reg [2:0]  play_mode_s;   // 播放逻辑的模式快照
    reg [3:0]  song_beat;
    reg [23:0] unit_cnt;
    localparam [23:0] UNIT = 24'd6749999;    // 0.25s @27MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            song_ptr    <= 8'd0;
            song_beat   <= 4'd0;
            unit_cnt    <= 24'd0;
            play_mode_s <= 2'd0;
        end else if (play_mode != play_mode_s) begin
            // ---- 模式切换: 必须从新曲目起点开始(否则会先静音很多秒) ----
            song_ptr    <= song_start;
            song_beat   <= 4'd0;
            unit_cnt    <= 24'd0;
            play_mode_s <= play_mode;
        end else if (play_mode != 3'd2 && play_mode != 3'd3) begin
            song_ptr  <= 8'd0;              // 非曲目模式: 回到开头
            song_beat <= 4'd0;
            unit_cnt  <= 24'd0;
        end else if (unit_cnt >= UNIT) begin
            unit_cnt <= 24'd0;
            if (song_beat <= 4'd1) begin
                song_beat <= song_rom[song_ptr][3:0];
                song_ptr  <= (song_ptr >= song_last) ? song_start : song_ptr + 1'b1;
            end else
                song_beat <= song_beat - 1'b1;
        end else
            unit_cnt <= unit_cnt + 1'b1;
    end

    // 曲目音名 -> 频率控制字
    reg [31:0] fword_song;
    always @(*) begin
        case (song_rom[song_ptr][7:4])
            4'd0: fword_song = fw0;
            4'd1: fword_song = fw1;
            4'd2: fword_song = fw2;
            4'd3: fword_song = fw3;
            4'd4: fword_song = fw4;
            4'd5: fword_song = fw5;
            4'd6: fword_song = fw6;
            4'd7: fword_song = fw7;
            default: fword_song = 32'd0;    // 休止符
        endcase
    end

    // ========================================================================
    // 4a2) 音准测试模式: 每 2 秒换一个音, C4 D4 E4 F4 G4 A4 B4 C5 循环
    //      用途: 手机装个调音器 App, 逐个音测频率误差, 填验收表格
    // ========================================================================
    reg [25:0] cal_cnt;
    reg [2:0]  cal_idx;
    wire       cal_tick = (cal_cnt == 26'd53999999);   // 2s @27MHz (26位才能装下)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cal_cnt <= 26'd0;
            cal_idx <= 3'd0;
        end else if (play_mode != 3'd4) begin
            cal_cnt <= 26'd0;
            cal_idx <= 3'd0;
        end else if (cal_tick) begin
            cal_cnt <= 26'd0;
            cal_idx <= cal_idx + 1'b1;
        end else
            cal_cnt <= cal_cnt + 1'b1;
    end

    reg [31:0] fword_cal;
    always @(*) begin
        case (cal_idx)
            3'd0: fword_cal = fw0;   // C4  261.63Hz
            3'd1: fword_cal = fw1;   // D4  293.66Hz
            3'd2: fword_cal = fw2;   // E4  329.63Hz
            3'd3: fword_cal = fw3;   // F4  349.23Hz
            3'd4: fword_cal = fw4;   // G4  392.00Hz
            3'd5: fword_cal = fw5;   // A4  440.00Hz
            3'd6: fword_cal = fw6;   // B4  493.88Hz
            3'd7: fword_cal = fw7;   // C5  523.25Hz
            default: fword_cal = fw0;
        endcase
    end

    // 播放源选择: 音准测试 / 曲目 / 音阶
    wire [31:0] fword_play = (play_mode == 3'd4) ? fword_cal :
                             (play_mode == 2'd2 || play_mode == 2'd3) ? fword_song : fword_scale;

    // ========================================================================
    // 4b) 颤音 LFO: 6Hz 正弦, 幅度 ±127 (调制音高)
    // ========================================================================
    localparam [31:0] VIB_K = 32'd536871;      // 2^32 x 6 / 48000
    reg [31:0] vib_phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            vib_phase <= 32'd0;
        else if (tick_sample)  vib_phase <= vib_phase + VIB_K;
    end

    reg signed [7:0] vib_rom [0:255];
    initial begin
        vib_rom[  0] = 8'h00; vib_rom[  1] = 8'h03; vib_rom[  2] = 8'h06; vib_rom[  3] = 8'h09; vib_rom[  4] = 8'h0C; vib_rom[  5] = 8'h10; vib_rom[  6] = 8'h13; vib_rom[  7] = 8'h16; vib_rom[  8] = 8'h19; vib_rom[  9] = 8'h1C; vib_rom[ 10] = 8'h1F; vib_rom[ 11] = 8'h22; vib_rom[ 12] = 8'h25; vib_rom[ 13] = 8'h28; vib_rom[ 14] = 8'h2B; vib_rom[ 15] = 8'h2E;
        vib_rom[ 16] = 8'h31; vib_rom[ 17] = 8'h33; vib_rom[ 18] = 8'h36; vib_rom[ 19] = 8'h39; vib_rom[ 20] = 8'h3C; vib_rom[ 21] = 8'h3F; vib_rom[ 22] = 8'h41; vib_rom[ 23] = 8'h44; vib_rom[ 24] = 8'h47; vib_rom[ 25] = 8'h49; vib_rom[ 26] = 8'h4C; vib_rom[ 27] = 8'h4E; vib_rom[ 28] = 8'h51; vib_rom[ 29] = 8'h53; vib_rom[ 30] = 8'h55; vib_rom[ 31] = 8'h58;
        vib_rom[ 32] = 8'h5A; vib_rom[ 33] = 8'h5C; vib_rom[ 34] = 8'h5E; vib_rom[ 35] = 8'h60; vib_rom[ 36] = 8'h62; vib_rom[ 37] = 8'h64; vib_rom[ 38] = 8'h66; vib_rom[ 39] = 8'h68; vib_rom[ 40] = 8'h6A; vib_rom[ 41] = 8'h6B; vib_rom[ 42] = 8'h6D; vib_rom[ 43] = 8'h6F; vib_rom[ 44] = 8'h70; vib_rom[ 45] = 8'h71; vib_rom[ 46] = 8'h73; vib_rom[ 47] = 8'h74;
        vib_rom[ 48] = 8'h75; vib_rom[ 49] = 8'h76; vib_rom[ 50] = 8'h78; vib_rom[ 51] = 8'h79; vib_rom[ 52] = 8'h7A; vib_rom[ 53] = 8'h7A; vib_rom[ 54] = 8'h7B; vib_rom[ 55] = 8'h7C; vib_rom[ 56] = 8'h7D; vib_rom[ 57] = 8'h7D; vib_rom[ 58] = 8'h7E; vib_rom[ 59] = 8'h7E; vib_rom[ 60] = 8'h7E; vib_rom[ 61] = 8'h7F; vib_rom[ 62] = 8'h7F; vib_rom[ 63] = 8'h7F;
        vib_rom[ 64] = 8'h7F; vib_rom[ 65] = 8'h7F; vib_rom[ 66] = 8'h7F; vib_rom[ 67] = 8'h7F; vib_rom[ 68] = 8'h7E; vib_rom[ 69] = 8'h7E; vib_rom[ 70] = 8'h7E; vib_rom[ 71] = 8'h7D; vib_rom[ 72] = 8'h7D; vib_rom[ 73] = 8'h7C; vib_rom[ 74] = 8'h7B; vib_rom[ 75] = 8'h7A; vib_rom[ 76] = 8'h7A; vib_rom[ 77] = 8'h79; vib_rom[ 78] = 8'h78; vib_rom[ 79] = 8'h76;
        vib_rom[ 80] = 8'h75; vib_rom[ 81] = 8'h74; vib_rom[ 82] = 8'h73; vib_rom[ 83] = 8'h71; vib_rom[ 84] = 8'h70; vib_rom[ 85] = 8'h6F; vib_rom[ 86] = 8'h6D; vib_rom[ 87] = 8'h6B; vib_rom[ 88] = 8'h6A; vib_rom[ 89] = 8'h68; vib_rom[ 90] = 8'h66; vib_rom[ 91] = 8'h64; vib_rom[ 92] = 8'h62; vib_rom[ 93] = 8'h60; vib_rom[ 94] = 8'h5E; vib_rom[ 95] = 8'h5C;
        vib_rom[ 96] = 8'h5A; vib_rom[ 97] = 8'h58; vib_rom[ 98] = 8'h55; vib_rom[ 99] = 8'h53; vib_rom[100] = 8'h51; vib_rom[101] = 8'h4E; vib_rom[102] = 8'h4C; vib_rom[103] = 8'h49; vib_rom[104] = 8'h47; vib_rom[105] = 8'h44; vib_rom[106] = 8'h41; vib_rom[107] = 8'h3F; vib_rom[108] = 8'h3C; vib_rom[109] = 8'h39; vib_rom[110] = 8'h36; vib_rom[111] = 8'h33;
        vib_rom[112] = 8'h31; vib_rom[113] = 8'h2E; vib_rom[114] = 8'h2B; vib_rom[115] = 8'h28; vib_rom[116] = 8'h25; vib_rom[117] = 8'h22; vib_rom[118] = 8'h1F; vib_rom[119] = 8'h1C; vib_rom[120] = 8'h19; vib_rom[121] = 8'h16; vib_rom[122] = 8'h13; vib_rom[123] = 8'h10; vib_rom[124] = 8'h0C; vib_rom[125] = 8'h09; vib_rom[126] = 8'h06; vib_rom[127] = 8'h03;
        vib_rom[128] = 8'h00; vib_rom[129] = 8'hFD; vib_rom[130] = 8'hFA; vib_rom[131] = 8'hF7; vib_rom[132] = 8'hF4; vib_rom[133] = 8'hF0; vib_rom[134] = 8'hED; vib_rom[135] = 8'hEA; vib_rom[136] = 8'hE7; vib_rom[137] = 8'hE4; vib_rom[138] = 8'hE1; vib_rom[139] = 8'hDE; vib_rom[140] = 8'hDB; vib_rom[141] = 8'hD8; vib_rom[142] = 8'hD5; vib_rom[143] = 8'hD2;
        vib_rom[144] = 8'hCF; vib_rom[145] = 8'hCD; vib_rom[146] = 8'hCA; vib_rom[147] = 8'hC7; vib_rom[148] = 8'hC4; vib_rom[149] = 8'hC1; vib_rom[150] = 8'hBF; vib_rom[151] = 8'hBC; vib_rom[152] = 8'hB9; vib_rom[153] = 8'hB7; vib_rom[154] = 8'hB4; vib_rom[155] = 8'hB2; vib_rom[156] = 8'hAF; vib_rom[157] = 8'hAD; vib_rom[158] = 8'hAB; vib_rom[159] = 8'hA8;
        vib_rom[160] = 8'hA6; vib_rom[161] = 8'hA4; vib_rom[162] = 8'hA2; vib_rom[163] = 8'hA0; vib_rom[164] = 8'h9E; vib_rom[165] = 8'h9C; vib_rom[166] = 8'h9A; vib_rom[167] = 8'h98; vib_rom[168] = 8'h96; vib_rom[169] = 8'h95; vib_rom[170] = 8'h93; vib_rom[171] = 8'h91; vib_rom[172] = 8'h90; vib_rom[173] = 8'h8F; vib_rom[174] = 8'h8D; vib_rom[175] = 8'h8C;
        vib_rom[176] = 8'h8B; vib_rom[177] = 8'h8A; vib_rom[178] = 8'h88; vib_rom[179] = 8'h87; vib_rom[180] = 8'h86; vib_rom[181] = 8'h86; vib_rom[182] = 8'h85; vib_rom[183] = 8'h84; vib_rom[184] = 8'h83; vib_rom[185] = 8'h83; vib_rom[186] = 8'h82; vib_rom[187] = 8'h82; vib_rom[188] = 8'h82; vib_rom[189] = 8'h81; vib_rom[190] = 8'h81; vib_rom[191] = 8'h81;
        vib_rom[192] = 8'h81; vib_rom[193] = 8'h81; vib_rom[194] = 8'h81; vib_rom[195] = 8'h81; vib_rom[196] = 8'h82; vib_rom[197] = 8'h82; vib_rom[198] = 8'h82; vib_rom[199] = 8'h83; vib_rom[200] = 8'h83; vib_rom[201] = 8'h84; vib_rom[202] = 8'h85; vib_rom[203] = 8'h86; vib_rom[204] = 8'h86; vib_rom[205] = 8'h87; vib_rom[206] = 8'h88; vib_rom[207] = 8'h8A;
        vib_rom[208] = 8'h8B; vib_rom[209] = 8'h8C; vib_rom[210] = 8'h8D; vib_rom[211] = 8'h8F; vib_rom[212] = 8'h90; vib_rom[213] = 8'h91; vib_rom[214] = 8'h93; vib_rom[215] = 8'h95; vib_rom[216] = 8'h96; vib_rom[217] = 8'h98; vib_rom[218] = 8'h9A; vib_rom[219] = 8'h9C; vib_rom[220] = 8'h9E; vib_rom[221] = 8'hA0; vib_rom[222] = 8'hA2; vib_rom[223] = 8'hA4;
        vib_rom[224] = 8'hA6; vib_rom[225] = 8'hA8; vib_rom[226] = 8'hAB; vib_rom[227] = 8'hAD; vib_rom[228] = 8'hAF; vib_rom[229] = 8'hB2; vib_rom[230] = 8'hB4; vib_rom[231] = 8'hB7; vib_rom[232] = 8'hB9; vib_rom[233] = 8'hBC; vib_rom[234] = 8'hBF; vib_rom[235] = 8'hC1; vib_rom[236] = 8'hC4; vib_rom[237] = 8'hC7; vib_rom[238] = 8'hCA; vib_rom[239] = 8'hCD;
        vib_rom[240] = 8'hCF; vib_rom[241] = 8'hD2; vib_rom[242] = 8'hD5; vib_rom[243] = 8'hD8; vib_rom[244] = 8'hDB; vib_rom[245] = 8'hDE; vib_rom[246] = 8'hE1; vib_rom[247] = 8'hE4; vib_rom[248] = 8'hE7; vib_rom[249] = 8'hEA; vib_rom[250] = 8'hED; vib_rom[251] = 8'hF0; vib_rom[252] = 8'hF4; vib_rom[253] = 8'hF7; vib_rom[254] = 8'hFA; vib_rom[255] = 8'hFD;
    end

    wire signed [7:0] vib_lfo = vib_rom[vib_phase[31:24]];

    // ========================================================================
    // 4d) 键15 双功能: 短按=颤音开关  长按=录音/回放循环
    //     录音: 每 20ms 采一次 8 位音符位图, 存 2048 点 = 约 40 秒
    // ========================================================================
    reg [19:0] k15_hold;
    reg        vib_on;
    reg [1:0]  rec_mode;      // 0=空闲 1=录音中 2=回放中

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k15_hold <= 20'd0;
            vib_on   <= 1'b0;
            rec_mode <= 2'd0;
        end else if (tick_ms) begin
            if (kst[15]) begin
                if (k15_hold < 20'd500)
                    k15_hold <= k15_hold + 1'b1;
                else if (k15_hold == 20'd500) begin
                    k15_hold <= 20'd501;                        // 防重复触发
                    rec_mode <= (rec_mode == 2'd2) ? 2'd0 : rec_mode + 1'b1;
                end
            end else begin
                if (k15_hold > 20'd0 && k15_hold < 20'd500)
                    vib_on <= ~vib_on;                          // 短按: 切颤音
                k15_hold <= 20'd0;
            end
        end
    end

    // ---- 录音存储 ----
    reg [7:0]  rec_mem [0:2047];
    reg [10:0] rec_wp;
    reg [10:0] rec_rp;
    reg [19:0] rec_cnt;
    wire       rec_tick = (rec_cnt == 20'd539999);   // 20ms @27MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rec_wp  <= 11'd0;
            rec_rp  <= 11'd0;
            rec_cnt <= 20'd0;
        end else begin
            if (rec_tick) rec_cnt <= 20'd0;
            else          rec_cnt <= rec_cnt + 1'b1;

            if (rec_tick) begin
                if (rec_mode == 2'd1) begin
                    rec_mem[rec_wp] <= kst[7:0];        // 录音
                    rec_wp <= rec_wp + 1'b1;
                end else if (rec_mode == 2'd2)
                    rec_rp <= rec_rp + 1'b1;            // 回放
                else
                    rec_rp <= 11'd0;
            end
        end
    end

    // ========================================================================
    // 4e) 状态提示音: 让用户能'听见'状态变化 (否则不知道有没有在录音)
    //     开始录音 -> 高音嘟(880Hz)  开始回放 -> 中音嘟(440Hz)  停止 -> 低音嘟(220Hz)
    // ========================================================================
    reg [23:0] b_len;          // 提示音剩余时长(采样数)
    reg [31:0] b_ph;           // 提示音相位
    reg [31:0] b_fw;           // 提示音频率控制字
    reg [1:0]  rec_mode_p;     // 上一拍的 rec_mode (用于检测状态变化)

    wire beep_on = (b_len != 24'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_len      <= 24'd0;
            b_ph       <= 32'd0;
            b_fw       <= 32'd0;
            rec_mode_p <= 2'd0;
        end else if (tick_sample) begin
            rec_mode_p <= rec_mode;
            if (rec_mode != rec_mode_p) begin
                // ---- 状态变化 -> 播提示音 ----
                b_len <= 24'd14400;                     // 300ms @48kHz
                b_ph  <= 32'd0;
                b_fw  <= (rec_mode == 2'd1) ? 32'd78643186 :  // 开始录音 -> 880Hz
                         (rec_mode == 2'd2) ? 32'd39370534 :  // 开始回放 -> 440Hz
                                              32'd19685267;   // 停止     -> 220Hz
            end else if (b_len != 24'd0) begin
                b_len <= b_len - 1'b1;
                b_ph  <= b_ph + b_fw;
            end else
                b_ph <= 32'd0;
        end
    end

    // 提示音波形: 方波 (够响亮, 容易听见)
    wire signed [15:0] beep_sig = beep_on ? (b_ph[31] ? 16'sh2800 : -16'sh2800) : 16'sd0;

    // 声部门控: 回放中 -> 用录音数据, 否则 -> 用键盘

    // ========================================================================
    // 4c) 主音量: 键12 = 音量+, 键13 = 音量- (每 100ms 调一档, 共 16 档)
    // ========================================================================
    reg [3:0] mvol;
    reg [6:0] vol_cnt;
    reg       k12_p, k13_p;
    // 按下瞬间立即调一档(不用等 100ms), 按住则每 100ms 连续调
    wire vol_inc_en = (kst[12] && !k12_p) || (kst[12] && vol_cnt >= 7'd99);
    wire vol_dec_en = (kst[13] && !k13_p) || (kst[13] && vol_cnt >= 7'd99);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mvol    <= 4'd13;       // 默认 13/16 (单声部已降半, 这里补回来)
            vol_cnt <= 7'd0;
            k12_p   <= 1'b0;
            k13_p   <= 1'b0;
        end else if (tick_ms) begin
            k12_p <= kst[12];
            k13_p <= kst[13];
            if (vol_cnt >= 7'd99) vol_cnt <= 7'd0;
            else                  vol_cnt <= vol_cnt + 1'b1;
            if (vol_inc_en && mvol < 4'd15) mvol <= mvol + 1'b1;
            if (vol_dec_en && mvol > 4'd0)  mvol <= mvol - 1'b1;
        end
    end

    // ========================================================================
    // 5) I2S 时基: 精确 48kHz (相位累加小数分频)
    //    BCK 翻转频率 = 27MHz x K / 2^24 = 6.144MHz -> BCK 3.072MHz
    //    LRCK = 3.072MHz / 64 = 48000.0Hz
    // ========================================================================
    localparam [23:0] K = 24'd3817749;
    reg  [23:0] acc;
    wire [24:0] acc_next = {1'b0, acc} + {1'b0, K};
    wire        acc_ovf  = acc_next[24];

    reg [5:0]  bit_cnt;
    reg [15:0] sh;
    reg        bck_r, din_r, tick_sample;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc         <= 24'd0;
            bck_r       <= 1'b0;
            bit_cnt     <= 6'd0;
            sh          <= 16'd0;
            din_r       <= 1'b0;
            tick_sample <= 1'b0;
        end else begin
            acc <= acc_next[23:0];
            tick_sample <= 1'b0;

            if (acc_ovf) begin
                if (bck_r) begin
                    // ---------- BCK 下降沿 ----------
                    bck_r <= 1'b0;
                    if (bit_cnt[4:0] == 5'd31)
                        sh <= final_out;        // 装载 (含状态提示音)
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt[4:0] <= 5'd15)
                        din_r <= sh[5'd15 - bit_cnt[4:0]];
                    else
                        din_r <= 1'b0;
                end else
                    bck_r <= 1'b1;
            end

            if (acc_ovf && bck_r && (bit_cnt == 6'd63))
                tick_sample <= 1'b1;
        end
    end

    assign i2s_bck  = bck_r;
    assign i2s_lrck = bit_cnt[5];
    assign i2s_din  = din_r;

    // ========================================================================
    // 6) ADS1115 力度采集 (I2C, 每 10ms 读一次 A0)
    // ========================================================================
    wire [15:0] adc_raw;
    wire        adc_ok;

    ads1115 u_adc (
        .clk       (clk),
        .rst_n     (rst_n),
        .sda       (i2c_sda),
        .scl       (i2c_scl),
        .adc       (adc_raw),
        .adc_ok    (adc_ok)
    );

    wire [15:0] adc_pos  = adc_raw[15] ? 16'd0 : adc_raw;
    wire [15:0] adc_clip = (adc_pos > 16'd26400) ? 16'd26400 : adc_pos;

    // ---- 力度曲线: 平方律 (让听感接近线性) ----
    reg [11:0] vol_curve [0:255];
    initial begin
        vol_curve[  0] = 12'd0; vol_curve[  1] = 12'd0; vol_curve[  2] = 12'd0; vol_curve[  3] = 12'd0; vol_curve[  4] = 12'd1; vol_curve[  5] = 12'd1; vol_curve[  6] = 12'd2; vol_curve[  7] = 12'd2;
        vol_curve[  8] = 12'd3; vol_curve[  9] = 12'd4; vol_curve[ 10] = 12'd5; vol_curve[ 11] = 12'd6; vol_curve[ 12] = 12'd7; vol_curve[ 13] = 12'd8; vol_curve[ 14] = 12'd9; vol_curve[ 15] = 12'd11;
        vol_curve[ 16] = 12'd12; vol_curve[ 17] = 12'd14; vol_curve[ 18] = 12'd15; vol_curve[ 19] = 12'd17; vol_curve[ 20] = 12'd19; vol_curve[ 21] = 12'd21; vol_curve[ 22] = 12'd23; vol_curve[ 23] = 12'd25;
        vol_curve[ 24] = 12'd27; vol_curve[ 25] = 12'd30; vol_curve[ 26] = 12'd32; vol_curve[ 27] = 12'd34; vol_curve[ 28] = 12'd37; vol_curve[ 29] = 12'd40; vol_curve[ 30] = 12'd43; vol_curve[ 31] = 12'd45;
        vol_curve[ 32] = 12'd48; vol_curve[ 33] = 12'd51; vol_curve[ 34] = 12'd55; vol_curve[ 35] = 12'd58; vol_curve[ 36] = 12'd61; vol_curve[ 37] = 12'd65; vol_curve[ 38] = 12'd68; vol_curve[ 39] = 12'd72;
        vol_curve[ 40] = 12'd76; vol_curve[ 41] = 12'd79; vol_curve[ 42] = 12'd83; vol_curve[ 43] = 12'd87; vol_curve[ 44] = 12'd91; vol_curve[ 45] = 12'd96; vol_curve[ 46] = 12'd100; vol_curve[ 47] = 12'd104;
        vol_curve[ 48] = 12'd109; vol_curve[ 49] = 12'd113; vol_curve[ 50] = 12'd118; vol_curve[ 51] = 12'd123; vol_curve[ 52] = 12'd128; vol_curve[ 53] = 12'd133; vol_curve[ 54] = 12'd138; vol_curve[ 55] = 12'd143;
        vol_curve[ 56] = 12'd148; vol_curve[ 57] = 12'd153; vol_curve[ 58] = 12'd159; vol_curve[ 59] = 12'd164; vol_curve[ 60] = 12'd170; vol_curve[ 61] = 12'd176; vol_curve[ 62] = 12'd182; vol_curve[ 63] = 12'd187;
        vol_curve[ 64] = 12'd193; vol_curve[ 65] = 12'd200; vol_curve[ 66] = 12'd206; vol_curve[ 67] = 12'd212; vol_curve[ 68] = 12'd218; vol_curve[ 69] = 12'd225; vol_curve[ 70] = 12'd231; vol_curve[ 71] = 12'd238;
        vol_curve[ 72] = 12'd245; vol_curve[ 73] = 12'd252; vol_curve[ 74] = 12'd259; vol_curve[ 75] = 12'd266; vol_curve[ 76] = 12'd273; vol_curve[ 77] = 12'd280; vol_curve[ 78] = 12'd287; vol_curve[ 79] = 12'd295;
        vol_curve[ 80] = 12'd302; vol_curve[ 81] = 12'd310; vol_curve[ 82] = 12'd318; vol_curve[ 83] = 12'd325; vol_curve[ 84] = 12'd333; vol_curve[ 85] = 12'd341; vol_curve[ 86] = 12'd349; vol_curve[ 87] = 12'd357;
        vol_curve[ 88] = 12'd366; vol_curve[ 89] = 12'd374; vol_curve[ 90] = 12'd383; vol_curve[ 91] = 12'd391; vol_curve[ 92] = 12'd400; vol_curve[ 93] = 12'd408; vol_curve[ 94] = 12'd417; vol_curve[ 95] = 12'd426;
        vol_curve[ 96] = 12'd435; vol_curve[ 97] = 12'd444; vol_curve[ 98] = 12'd454; vol_curve[ 99] = 12'd463; vol_curve[100] = 12'd472; vol_curve[101] = 12'd482; vol_curve[102] = 12'd491; vol_curve[103] = 12'd501;
        vol_curve[104] = 12'd511; vol_curve[105] = 12'd521; vol_curve[106] = 12'd531; vol_curve[107] = 12'd541; vol_curve[108] = 12'd551; vol_curve[109] = 12'd561; vol_curve[110] = 12'd571; vol_curve[111] = 12'd582;
        vol_curve[112] = 12'd592; vol_curve[113] = 12'd603; vol_curve[114] = 12'd614; vol_curve[115] = 12'd625; vol_curve[116] = 12'd635; vol_curve[117] = 12'd647; vol_curve[118] = 12'd658; vol_curve[119] = 12'd669;
        vol_curve[120] = 12'd680; vol_curve[121] = 12'd691; vol_curve[122] = 12'd703; vol_curve[123] = 12'd715; vol_curve[124] = 12'd726; vol_curve[125] = 12'd738; vol_curve[126] = 12'd750; vol_curve[127] = 12'd762;
        vol_curve[128] = 12'd774; vol_curve[129] = 12'd786; vol_curve[130] = 12'd798; vol_curve[131] = 12'd810; vol_curve[132] = 12'd823; vol_curve[133] = 12'd835; vol_curve[134] = 12'd848; vol_curve[135] = 12'd861;
        vol_curve[136] = 12'd874; vol_curve[137] = 12'd886; vol_curve[138] = 12'd899; vol_curve[139] = 12'd912; vol_curve[140] = 12'd926; vol_curve[141] = 12'd939; vol_curve[142] = 12'd952; vol_curve[143] = 12'd966;
        vol_curve[144] = 12'd979; vol_curve[145] = 12'd993; vol_curve[146] = 12'd1007; vol_curve[147] = 12'd1021; vol_curve[148] = 12'd1034; vol_curve[149] = 12'd1049; vol_curve[150] = 12'd1063; vol_curve[151] = 12'd1077;
        vol_curve[152] = 12'd1091; vol_curve[153] = 12'd1106; vol_curve[154] = 12'd1120; vol_curve[155] = 12'd1135; vol_curve[156] = 12'd1149; vol_curve[157] = 12'd1164; vol_curve[158] = 12'd1179; vol_curve[159] = 12'd1194;
        vol_curve[160] = 12'd1209; vol_curve[161] = 12'd1224; vol_curve[162] = 12'd1239; vol_curve[163] = 12'd1255; vol_curve[164] = 12'd1270; vol_curve[165] = 12'd1286; vol_curve[166] = 12'd1301; vol_curve[167] = 12'd1317;
        vol_curve[168] = 12'd1333; vol_curve[169] = 12'd1349; vol_curve[170] = 12'd1365; vol_curve[171] = 12'd1381; vol_curve[172] = 12'd1397; vol_curve[173] = 12'd1413; vol_curve[174] = 12'd1430; vol_curve[175] = 12'd1446;
        vol_curve[176] = 12'd1463; vol_curve[177] = 12'd1480; vol_curve[178] = 12'd1496; vol_curve[179] = 12'd1513; vol_curve[180] = 12'd1530; vol_curve[181] = 12'd1547; vol_curve[182] = 12'd1564; vol_curve[183] = 12'd1582;
        vol_curve[184] = 12'd1599; vol_curve[185] = 12'd1616; vol_curve[186] = 12'd1634; vol_curve[187] = 12'd1652; vol_curve[188] = 12'd1669; vol_curve[189] = 12'd1687; vol_curve[190] = 12'd1705; vol_curve[191] = 12'd1723;
        vol_curve[192] = 12'd1741; vol_curve[193] = 12'd1759; vol_curve[194] = 12'd1777; vol_curve[195] = 12'd1796; vol_curve[196] = 12'd1814; vol_curve[197] = 12'd1833; vol_curve[198] = 12'd1852; vol_curve[199] = 12'd1870;
        vol_curve[200] = 12'd1889; vol_curve[201] = 12'd1908; vol_curve[202] = 12'd1927; vol_curve[203] = 12'd1946; vol_curve[204] = 12'd1965; vol_curve[205] = 12'd1985; vol_curve[206] = 12'd2004; vol_curve[207] = 12'd2024;
        vol_curve[208] = 12'd2043; vol_curve[209] = 12'd2063; vol_curve[210] = 12'd2083; vol_curve[211] = 12'd2103; vol_curve[212] = 12'd2123; vol_curve[213] = 12'd2143; vol_curve[214] = 12'd2163; vol_curve[215] = 12'd2183;
        vol_curve[216] = 12'd2203; vol_curve[217] = 12'd2224; vol_curve[218] = 12'd2244; vol_curve[219] = 12'd2265; vol_curve[220] = 12'd2286; vol_curve[221] = 12'd2307; vol_curve[222] = 12'd2328; vol_curve[223] = 12'd2349;
        vol_curve[224] = 12'd2370; vol_curve[225] = 12'd2391; vol_curve[226] = 12'd2412; vol_curve[227] = 12'd2434; vol_curve[228] = 12'd2455; vol_curve[229] = 12'd2477; vol_curve[230] = 12'd2498; vol_curve[231] = 12'd2520;
        vol_curve[232] = 12'd2542; vol_curve[233] = 12'd2564; vol_curve[234] = 12'd2586; vol_curve[235] = 12'd2608; vol_curve[236] = 12'd2630; vol_curve[237] = 12'd2653; vol_curve[238] = 12'd2675; vol_curve[239] = 12'd2698;
        vol_curve[240] = 12'd2720; vol_curve[241] = 12'd2743; vol_curve[242] = 12'd2766; vol_curve[243] = 12'd2789; vol_curve[244] = 12'd2812; vol_curve[245] = 12'd2835; vol_curve[246] = 12'd2858; vol_curve[247] = 12'd2881;
        vol_curve[248] = 12'd2905; vol_curve[249] = 12'd2928; vol_curve[250] = 12'd2952; vol_curve[251] = 12'd2975; vol_curve[252] = 12'd2999; vol_curve[253] = 12'd3023; vol_curve[254] = 12'd3047; vol_curve[255] = 12'd3071;
    end

    wire [11:0] vol_inc = vol_curve[adc_clip[15:8]];

    // 力度系数: ADC 读数 1/8 步进平滑(防 100Hz 音量抖动)
    reg [11:0] loud;
    wire [11:0] vol_new = 12'd1024 + {1'b0, vol_inc[11:1]};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) loud <= 12'd4095;
        else if (adc_ok) begin
            if (vol_new > loud)
                loud <= loud + ((vol_new - loud) >> 3);
            else
                loud <= loud - ((loud - vol_new) >> 3);
        end
    end

    // ========================================================================
    // 7) 8 个独立声部
    //    声部0 在自动播放时改播音阶, 其余声部固定对应键 1~7
    // ========================================================================
    wire signed [15:0] v0, v1, v2, v3, v4, v5, v6, v7;

    // 8 个音符声部的门控源: 回放中取录音数据, 否则取键盘
    wire [7:0] gate_vec = (rec_mode == 2'd2) ? rec_mem[rec_rp] : kst[7:0];

    // 声部0: 播放模式时播音阶/曲目, 否则弹键0
    // ---- 换音检测 (放在 tick_sample 域, 确保 voice 能可靠捕获) ----
    reg [31:0] fw_play_p;
    reg        note_sw_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fw_play_p <= 32'd0;
            note_sw_r <= 1'b0;
        end else if (tick_sample) begin
            fw_play_p <= fword_play;
            note_sw_r <= (fword_play != fw_play_p);
        end
    end

    wire gate0_raw = (play_mode != 2'd0) ? (fword_play != 32'd0) : gate_vec[0];
    wire gate0     = gate0_raw;
    wire [31:0] fword0 = (play_mode != 2'd0) ? fword_play : fw0;

    // 曲目/音阶换音 -> 复位声部0包络 (关键: 否则音符会粘连成一片)
    wire env_rst0 = note_sw_r && (play_mode == 3'd2 || play_mode == 3'd3 || play_mode == 3'd4);

    voice u_v0 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fword0), .gate(gate0), .env_rst(env_rst0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v0));

    voice u_v1 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw1), .gate(gate_vec[1]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v1));
    voice u_v2 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw2), .gate(gate_vec[2]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v2));
    voice u_v3 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw3), .gate(gate_vec[3]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v3));
    voice u_v4 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw4), .gate(gate_vec[4]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v4));
    voice u_v5 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw5), .gate(gate_vec[5]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v5));
    voice u_v6 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw6), .gate(gate_vec[6]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v6));
    voice u_v7 (.clk(clk), .rst_n(rst_n), .tick_sample(tick_sample),
                .fword(fw7), .gate(gate_vec[7]), .env_rst(1'b0), .preset(preset), .loud(loud), .vib_lfo(vib_lfo), .vib_on(vib_on), .sample(v7));

    // ========================================================================
    // 8) 混音 + 饱和限幅 (8 路求和后防止溢出爆音)
    // ========================================================================
    reg signed [18:0] mix_sum;
    always @(*) begin
        mix_sum = 19'sd0;
        mix_sum = mix_sum + $signed(v0);
        mix_sum = mix_sum + $signed(v1);
        mix_sum = mix_sum + $signed(v2);
        mix_sum = mix_sum + $signed(v3);
        mix_sum = mix_sum + $signed(v4);
        mix_sum = mix_sum + $signed(v5);
        mix_sum = mix_sum + $signed(v6);
        mix_sum = mix_sum + $signed(v7);
    end

    // ---- 软限幅(soft-knee): 超过 knee 的部分只按 1/4 压缩, 而不是硬削平 ----
    //      硬削平会产生大量奇次谐波 -> 听感'工厂嘶哑'; 软限幅谐波少得多
    localparam signed [19:0] KNEE = 20'sd24000;
    wire signed [19:0] mix_soft =
        (mix_sum >  KNEE) ? ( KNEE + ((mix_sum - KNEE) >>> 2)) :
        (mix_sum < -KNEE) ? (-KNEE + ((mix_sum + KNEE) >>> 2)) :
        mix_sum;

    wire signed [15:0] mix_out =
        (mix_soft > 20'sd32767)  ? 16'sh7FFF :
        (mix_soft < -20'sd32768) ? 16'sh8000 :
        mix_soft[15:0];

    // ========================================================================
    // 9) 音频效果器: 键14 循环切换 [关] -> [延迟] -> [混响] -> [关]
    //    延迟: 4096采样(85ms) 反馈1/2 湿声1/4  -> 清晰可数的回声
    //    混响: 1024采样(21ms) 反馈3/4 湿声1/2  -> 密集回声=空间感
    // ========================================================================
    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if (v > 18'sd32767)       sat16 = 16'sh7FFF;
            else if (v < -18'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    // ---- 效果模式: 0=关 1=延迟 2=混响 3=合唱 ----
    reg [2:0] fx_mode;
    reg       k14_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fx_mode <= 3'd0;
            k14_p   <= 1'b0;
        end else if (tick_ms) begin
            k14_p <= kst[14];
            if (kst[14] && !k14_p)          // 键14 按下沿
                fx_mode <= (fx_mode == 3'd3) ? 3'd0 : fx_mode + 1'b1;
        end
    end

    // ---- 延迟线 A: 4096 采样 (延迟效果) ----
    reg [15:0] dlyA [0:4095];
    reg [11:0] wpA;
    reg [15:0] tapA;

    // ---- 延迟线 B: 1024 采样 (混响效果) ----
    reg [15:0] dlyB [0:1023];
    reg [9:0]  wpB;
    reg [15:0] tapB;

    wire signed [15:0] eff_in = mix_out;

    // A 路: 反馈 1/2, 湿声 1/4
    wire signed [17:0] fbA  = $signed(eff_in) + ($signed(tapA) >>> 1);
    wire signed [17:0] wetA = $signed(eff_in) + ($signed(tapA) >>> 2);

    // B 路: 反馈 3/4 (=1/2+1/4), 湿声 1/2
    wire signed [17:0] fbB  = $signed(eff_in) + ($signed(tapB) >>> 1) + ($signed(tapB) >>> 2);
    wire signed [17:0] wetB = $signed(eff_in) + ($signed(tapB) >>> 1);

    // ---- 合唱 (Chorus): 短延迟 12.5ms + LFO 调制 + 与原声混合 ----
    //      原理: 延迟时间被 0.5Hz LFO 缓慢调制, 产生'多个乐器齐奏'的厚度
    reg [15:0] cho_mem [0:1023];
    reg [9:0]  cho_wp;
    reg [9:0]  cho_rd;
    reg [15:0] cho_tap;
    reg [21:0] cho_lfo;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cho_lfo <= 22'd0;
        else if (tick_sample) cho_lfo <= cho_lfo + 1'b1;
    end

    // 三角波 LFO: 0~127, 周期 = 2^22 / 48000 ≈ 87 秒? 太快, 取高位
    wire [7:0] tri8 = cho_lfo[20:13];
    wire [7:0] lfo8 = tri8[7] ? (~tri8) : tri8;
    wire [9:0] cho_rd_a = cho_wp - 10'd600 - {2'b00, lfo8};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cho_wp  <= 10'd0;
            cho_rd  <= 10'd0;
            cho_tap <= 16'd0;
        end else if (tick_sample) begin
            cho_rd  <= cho_rd_a;
            cho_tap <= cho_mem[cho_rd];
            cho_mem[cho_wp] <= mix_out;
            cho_wp  <= cho_wp + 1'b1;
        end
    end

    wire signed [17:0] cho_sum = $signed(mix_out) + ($signed(cho_tap) >>> 1);
    wire signed [15:0] cho_out = sat16(cho_sum);

    // 自动播放默认【不】叠加混响(避免音量过大/糊), 想要空间感请按键14开效果器
    wire signed [15:0] eff_out = (fx_mode == 3'd1) ? sat16(wetA) :
                                 (fx_mode == 3'd2) ? sat16(wetB) :
                                 (fx_mode == 3'd3) ? cho_out     : mix_out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wpA  <= 12'd0;
            tapA <= 16'd0;
            wpB  <= 10'd0;
            tapB <= 16'd0;
        end else if (tick_sample) begin
            tapA      <= dlyA[wpA];       // 同步读旧值
            dlyA[wpA] <= sat16(fbA);      // 写入: 原声 + 反馈
            wpA       <= wpA + 1'b1;
            tapB      <= dlyB[wpB];
            dlyB[wpB] <= sat16(fbB);
            wpB       <= wpB + 1'b1;
        end
    end

    // ========================================================================
    // 10) 主音量缩放 (mvol/16)
    // ========================================================================
    wire signed [20:0] vol_prod = $signed(eff_out) * $signed({1'b0, mvol});
    wire signed [15:0] vol_out  = vol_prod[19:4];    // 除以 16

    // 最终输出 = 主音量 + 状态提示音
    wire signed [16:0] final_sum = $signed(vol_out) + $signed(beep_sig);
    wire signed [15:0] final_out =
        (final_sum > 17'sd32767)  ? 16'sh7FFF :
        (final_sum < -17'sd32768) ? 16'sh8000 : final_sum[15:0];

    // ========================================================================
    // 12) 4 路 LED 演奏指引 (音区指示)
    //     LED1=哆唻  LED2=咪发  LED3=唆拉  LED4=西哆(高)
    //     按哪个音区的键 -> 对应灯亮;  自动播放时跟着旋律跳
    // ========================================================================

    // 自动播放时的当前音符索引(0~7)
    wire [3:0] play_note_idx = (play_mode == 3'd4) ? {1'b0, cal_idx} :
                               (play_mode == 3'd1) ? {1'b0, note_idx} :
                               song_rom[song_ptr][7:4];

    // 键盘: 哪个音区有键按下(每 2 个音符一个音区)
    wire [3:0] key_zone = { |kst[7:6], |kst[5:4], |kst[3:2], |kst[1:0] };

    // ---- 曲目 LED 指引: 提前显示【下一个】音符的音区, 让演奏者有时间准备 ----
    //      这就是题目要求的'脱机演奏 LED 曲目指引, 辅助规范演奏节奏'
    wire [7:0] next_song_ptr = (song_ptr >= song_last) ? song_start : song_ptr + 1'b1;
    wire [3:0] next_note_idx = song_rom[next_song_ptr][7:4];

    wire [3:0] play_zone =
        (play_mode == 3'd2 || play_mode == 3'd3) ? (4'b0001 << next_note_idx[2:1]) :
                                                   (4'b0001 << play_note_idx[2:1]);

    wire [3:0] led_zone = (play_mode != 3'd0) ? play_zone : key_zone;

    // ---- 上电自检: 前 5 秒 4 个 LED 全亮(方便检查每个 LED 是否工作) ----
    reg [27:0] led_boot;
    wire       led_test = (led_boot < 28'd134999999);  // 5s @27MHz
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                           led_boot <= 28'd0;
        else if (led_boot < 28'd134999999)    led_boot <= led_boot + 1'b1;
    end

    assign led[0] = led_test | led_zone[0];   // 哆/唻
    assign led[1] = led_test | led_zone[1];   // 咪/发
    assign led[2] = led_test | led_zone[2];   // 唆/拉
    assign led[3] = led_test | led_zone[3];   // 西/哆(高)

endmodule
