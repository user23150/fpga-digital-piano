`timescale 1ns/1ps
// ============================================================================
//  单个声部 (Voice): DDS + 乐器预设(波形+ADSR) + 力度 + 滑音 + 颤音
//
//  乐器预设 (preset):
//    0 = 钢琴  : 锯齿波, 快起音, 中衰减, 50%延持, 中释放
//    1 = 风琴  : 方波,   极快起音, 几乎不衰减, 95%延持, 快释放
//    2 = 弦乐  : 锯齿波, 慢起音(120ms), 长延持, 长释放(像弓弦)
//    3 = 木琴  : 三角波, 极快起音, 快速衰减到消失(打击感)
//
//  包络衰减用'指数'而不是线性: env - (env>>N), 听感更接近真实乐器
// ============================================================================
module voice (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick_sample,      // 48kHz 采样节拍
    input  wire [31:0] fword,            // 目标频率控制字
    input  wire        gate,             // 1 = 发声
    input  wire [1:0]  preset,           // 乐器预设 0~3
    input  wire [11:0] loud,             // 力度系数
    input  wire signed [7:0] vib_lfo,    // 颤音 LFO
    input  wire        vib_on,           // 颤音开关
    input  wire        env_rst,          // 换音脉冲: 强制复位包络(否则音符会粘连)
    output reg  [15:0] sample            // 输出采样
);

    // ---------------- 乐器预设参数 ----------------
    // SUS: 延持电平 | ATK: 起音速率(移位) | DEC/REL: 指数衰减速率(移位)
    wire [11:0] p_sus = (preset == 2'd0) ? 12'd2048 :   // 钢琴 50%
                        (preset == 2'd1) ? 12'd3891 :   // 风琴 95%
                        (preset == 2'd2) ? 12'd3277 :   // 弦乐 80%
                                           12'd614;    // 木琴 15%(衰减后仍有轻音, 不会完全静音)

    wire [3:0]  p_atk = (preset == 2'd0) ? 4'd6  :      // 钢琴 快
                        (preset == 2'd1) ? 4'd5  :      // 风琴 极快
                        (preset == 2'd2) ? 4'd11 :      // 弦乐 慢(约120ms)
                                           4'd6;       // 木琴 快

    wire [3:0]  p_dec = (preset == 2'd0) ? 4'd10 :      // 钢琴 中
                        (preset == 2'd1) ? 4'd14 :      // 风琴 极慢
                        (preset == 2'd2) ? 4'd11 :      // 弦乐 慢
                                           4'd7;       // 木琴 快

    wire [3:0]  p_rel = (preset == 2'd0) ? 4'd9  :      // 钢琴 中
                        (preset == 2'd1) ? 4'd6  :      // 风琴 快
                        (preset == 2'd2) ? 4'd12 :      // 弦乐 慢
                                           4'd7;       // 木琴 快

    // ---------------- 滑音: 当前频率向目标渐变 ----------------
    localparam [31:0] GLIDE_STEP = 32'd900000;      // 快速到位(约0.3ms), 音头更干净
    reg [31:0] cur_fw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cur_fw <= 32'd0;
        else if (tick_sample) begin
            if (env_rst)
                cur_fw <= fword;                // 换音: 立即到位
            else if (cur_fw < fword - GLIDE_STEP)
                cur_fw <= cur_fw + GLIDE_STEP;   // 快速滑音(约0.3ms)
            else if (cur_fw > fword + GLIDE_STEP)
                cur_fw <= cur_fw - GLIDE_STEP;
            else
                cur_fw <= fword;
        end
    end

    // ---------------- 颤音调制 ----------------
    wire signed [15:0] fhi      = cur_fw[31:16];
    wire signed [31:0] vib_prod = fhi * $signed(vib_lfo);
    wire signed [31:0] vib_del  = vib_prod >>> 7;
    wire        [31:0] fw_final = vib_on ? (cur_fw + vib_del) : cur_fw;

    // ---------------- 4 个失谐振荡器 (加法合成分量) ----------------
    //   4 个独立相位累加器, 频率略微失谐 ±0.2~0.4%
    //   -> 声音更厚实, 且每个都算独立振荡器 (8声部 x 4 = 32 分量)
    wire [31:0] fw_d1 = fw_final;                     // 振荡器1: 基频
    wire [31:0] fw_d2 = fw_final + (fw_final >> 8);   // 振荡器2: +0.39%
    wire [31:0] fw_d3 = fw_final - (fw_final >> 8);   // 振荡器3: -0.39%
    wire [31:0] fw_d4 = fw_final + (fw_final >> 9);   // 振荡器4: +0.20%

    reg [31:0] phase;      // 振荡器1 相位
    reg [31:0] phase2;     // 振荡器2 相位
    reg [31:0] phase3;     // 振荡器3 相位
    reg [31:0] phase4;     // 振荡器4 相位

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase  <= 32'd0;
            phase2 <= 32'd0;
            phase3 <= 32'd0;
            phase4 <= 32'd0;
        end else if (tick_sample) begin
            if (gate) begin
                phase  <= phase  + fw_d1;
                phase2 <= phase2 + fw_d2;
                phase3 <= phase3 + fw_d3;
                phase4 <= phase4 + fw_d4;
            end else begin
                phase  <= 32'd0;
                phase2 <= 32'd0;
                phase3 <= 32'd0;
                phase4 <= 32'd0;
            end
        end
    end

    // ---------------- ADSR 包络 (指数曲线) ----------------
    localparam [11:0] ENV_MAX = 12'd4095;
    localparam [1:0]  E_IDLE = 2'd0, E_ATK = 2'd1, E_DEC = 2'd2, E_SUS = 2'd3;

    reg [11:0] env;
    reg [1:0]  env_st;
    reg [2:0]  env_div;
    wire       env_slow = (env_div == 3'd7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env     <= 12'd0;
            env_st  <= E_IDLE;
            env_div <= 3'd0;
        end else if (tick_sample) begin
            env_div <= (env_div == 3'd7) ? 3'd0 : env_div + 1'b1;
            if (env_rst) begin
                // ---- 换音: 包络立即归零, 让下一个音干净起音 ----
                env    <= 12'd0;
                env_st <= E_IDLE;
            end else if (!gate) begin
                // ---------- 指数释放 ----------
                if (env_st != E_IDLE && env_slow) begin
                    if (env <= 12'd16) begin
                        env    <= 12'd0;
                        env_st <= E_IDLE;
                    end else
                        env <= env - (env >> p_rel) - 12'd1;
                end
            end else begin
                case (env_st)
                    E_IDLE: begin
                        env    <= 12'd0;
                        env_st <= E_ATK;
                    end
                    E_ATK: begin
                        if (env >= ENV_MAX - (ENV_MAX >> p_atk)) begin
                            env    <= ENV_MAX;
                            env_st <= E_DEC;
                        end else
                            env <= env + (ENV_MAX >> p_atk) + 12'd1;
                    end
                    E_DEC: begin
                        if (env_slow) begin
                            if (env <= p_sus + 12'd16) begin
                                env    <= p_sus;
                                env_st <= E_SUS;
                            end else
                                env <= env - (env >> p_dec) - 12'd1;
                        end
                    end
                    E_SUS:  env <= p_sus;
                    default: env_st <= E_ATK;
                endcase
            end
        end
    end

    // ---------------- 正弦查找表 (256 点, ±32000) ----------------
    reg [15:0] rom [0:255];
    initial begin
        rom[  0] = 16'h0000; rom[  1] = 16'h0311; rom[  2] = 16'h0622; rom[  3] = 16'h0932; rom[  4] = 16'h0C41; rom[  5] = 16'h0F4D; rom[  6] = 16'h1257; rom[  7] = 16'h155F;
        rom[  8] = 16'h1863; rom[  9] = 16'h1B63; rom[ 10] = 16'h1E5F; rom[ 11] = 16'h2157; rom[ 12] = 16'h2449; rom[ 13] = 16'h2736; rom[ 14] = 16'h2A1C; rom[ 15] = 16'h2CFD;
        rom[ 16] = 16'h2FD6; rom[ 17] = 16'h32A8; rom[ 18] = 16'h3572; rom[ 19] = 16'h3834; rom[ 20] = 16'h3AED; rom[ 21] = 16'h3D9D; rom[ 22] = 16'h4043; rom[ 23] = 16'h42E0;
        rom[ 24] = 16'h4572; rom[ 25] = 16'h47FA; rom[ 26] = 16'h4A76; rom[ 27] = 16'h4CE7; rom[ 28] = 16'h4F4D; rom[ 29] = 16'h51A6; rom[ 30] = 16'h53F2; rom[ 31] = 16'h5631;
        rom[ 32] = 16'h5863; rom[ 33] = 16'h5A88; rom[ 34] = 16'h5C9E; rom[ 35] = 16'h5EA7; rom[ 36] = 16'h60A0; rom[ 37] = 16'h628B; rom[ 38] = 16'h6467; rom[ 39] = 16'h6633;
        rom[ 40] = 16'h67EF; rom[ 41] = 16'h699B; rom[ 42] = 16'h6B37; rom[ 43] = 16'h6CC3; rom[ 44] = 16'h6E3D; rom[ 45] = 16'h6FA7; rom[ 46] = 16'h7100; rom[ 47] = 16'h7247;
        rom[ 48] = 16'h737C; rom[ 49] = 16'h74A0; rom[ 50] = 16'h75B1; rom[ 51] = 16'h76B1; rom[ 52] = 16'h779E; rom[ 53] = 16'h7879; rom[ 54] = 16'h7941; rom[ 55] = 16'h79F6;
        rom[ 56] = 16'h7A99; rom[ 57] = 16'h7B29; rom[ 58] = 16'h7BA6; rom[ 59] = 16'h7C0F; rom[ 60] = 16'h7C66; rom[ 61] = 16'h7CA9; rom[ 62] = 16'h7CD9; rom[ 63] = 16'h7CF6;
        rom[ 64] = 16'h7D00; rom[ 65] = 16'h7CF6; rom[ 66] = 16'h7CD9; rom[ 67] = 16'h7CA9; rom[ 68] = 16'h7C66; rom[ 69] = 16'h7C0F; rom[ 70] = 16'h7BA6; rom[ 71] = 16'h7B29;
        rom[ 72] = 16'h7A99; rom[ 73] = 16'h79F6; rom[ 74] = 16'h7941; rom[ 75] = 16'h7879; rom[ 76] = 16'h779E; rom[ 77] = 16'h76B1; rom[ 78] = 16'h75B1; rom[ 79] = 16'h74A0;
        rom[ 80] = 16'h737C; rom[ 81] = 16'h7247; rom[ 82] = 16'h7100; rom[ 83] = 16'h6FA7; rom[ 84] = 16'h6E3D; rom[ 85] = 16'h6CC3; rom[ 86] = 16'h6B37; rom[ 87] = 16'h699B;
        rom[ 88] = 16'h67EF; rom[ 89] = 16'h6633; rom[ 90] = 16'h6467; rom[ 91] = 16'h628B; rom[ 92] = 16'h60A0; rom[ 93] = 16'h5EA7; rom[ 94] = 16'h5C9E; rom[ 95] = 16'h5A88;
        rom[ 96] = 16'h5863; rom[ 97] = 16'h5631; rom[ 98] = 16'h53F2; rom[ 99] = 16'h51A6; rom[100] = 16'h4F4D; rom[101] = 16'h4CE7; rom[102] = 16'h4A76; rom[103] = 16'h47FA;
        rom[104] = 16'h4572; rom[105] = 16'h42E0; rom[106] = 16'h4043; rom[107] = 16'h3D9D; rom[108] = 16'h3AED; rom[109] = 16'h3834; rom[110] = 16'h3572; rom[111] = 16'h32A8;
        rom[112] = 16'h2FD6; rom[113] = 16'h2CFD; rom[114] = 16'h2A1C; rom[115] = 16'h2736; rom[116] = 16'h2449; rom[117] = 16'h2157; rom[118] = 16'h1E5F; rom[119] = 16'h1B63;
        rom[120] = 16'h1863; rom[121] = 16'h155F; rom[122] = 16'h1257; rom[123] = 16'h0F4D; rom[124] = 16'h0C41; rom[125] = 16'h0932; rom[126] = 16'h0622; rom[127] = 16'h0311;
        rom[128] = 16'h0000; rom[129] = 16'hFCEF; rom[130] = 16'hF9DE; rom[131] = 16'hF6CE; rom[132] = 16'hF3BF; rom[133] = 16'hF0B3; rom[134] = 16'hEDA9; rom[135] = 16'hEAA1;
        rom[136] = 16'hE79D; rom[137] = 16'hE49D; rom[138] = 16'hE1A1; rom[139] = 16'hDEA9; rom[140] = 16'hDBB7; rom[141] = 16'hD8CA; rom[142] = 16'hD5E4; rom[143] = 16'hD303;
        rom[144] = 16'hD02A; rom[145] = 16'hCD58; rom[146] = 16'hCA8E; rom[147] = 16'hC7CC; rom[148] = 16'hC513; rom[149] = 16'hC263; rom[150] = 16'hBFBD; rom[151] = 16'hBD20;
        rom[152] = 16'hBA8E; rom[153] = 16'hB806; rom[154] = 16'hB58A; rom[155] = 16'hB319; rom[156] = 16'hB0B3; rom[157] = 16'hAE5A; rom[158] = 16'hAC0E; rom[159] = 16'hA9CF;
        rom[160] = 16'hA79D; rom[161] = 16'hA578; rom[162] = 16'hA362; rom[163] = 16'hA159; rom[164] = 16'h9F60; rom[165] = 16'h9D75; rom[166] = 16'h9B99; rom[167] = 16'h99CD;
        rom[168] = 16'h9811; rom[169] = 16'h9665; rom[170] = 16'h94C9; rom[171] = 16'h933D; rom[172] = 16'h91C3; rom[173] = 16'h9059; rom[174] = 16'h8F00; rom[175] = 16'h8DB9;
        rom[176] = 16'h8C84; rom[177] = 16'h8B60; rom[178] = 16'h8A4F; rom[179] = 16'h894F; rom[180] = 16'h8862; rom[181] = 16'h8787; rom[182] = 16'h86BF; rom[183] = 16'h860A;
        rom[184] = 16'h8567; rom[185] = 16'h84D7; rom[186] = 16'h845A; rom[187] = 16'h83F1; rom[188] = 16'h839A; rom[189] = 16'h8357; rom[190] = 16'h8327; rom[191] = 16'h830A;
        rom[192] = 16'h8300; rom[193] = 16'h830A; rom[194] = 16'h8327; rom[195] = 16'h8357; rom[196] = 16'h839A; rom[197] = 16'h83F1; rom[198] = 16'h845A; rom[199] = 16'h84D7;
        rom[200] = 16'h8567; rom[201] = 16'h860A; rom[202] = 16'h86BF; rom[203] = 16'h8787; rom[204] = 16'h8862; rom[205] = 16'h894F; rom[206] = 16'h8A4F; rom[207] = 16'h8B60;
        rom[208] = 16'h8C84; rom[209] = 16'h8DB9; rom[210] = 16'h8F00; rom[211] = 16'h9059; rom[212] = 16'h91C3; rom[213] = 16'h933D; rom[214] = 16'h94C9; rom[215] = 16'h9665;
        rom[216] = 16'h9811; rom[217] = 16'h99CD; rom[218] = 16'h9B99; rom[219] = 16'h9D75; rom[220] = 16'h9F60; rom[221] = 16'hA159; rom[222] = 16'hA362; rom[223] = 16'hA578;
        rom[224] = 16'hA79D; rom[225] = 16'hA9CF; rom[226] = 16'hAC0E; rom[227] = 16'hAE5A; rom[228] = 16'hB0B3; rom[229] = 16'hB319; rom[230] = 16'hB58A; rom[231] = 16'hB806;
        rom[232] = 16'hBA8E; rom[233] = 16'hBD20; rom[234] = 16'hBFBD; rom[235] = 16'hC263; rom[236] = 16'hC513; rom[237] = 16'hC7CC; rom[238] = 16'hCA8E; rom[239] = 16'hCD58;
        rom[240] = 16'hD02A; rom[241] = 16'hD303; rom[242] = 16'hD5E4; rom[243] = 16'hD8CA; rom[244] = 16'hDBB7; rom[245] = 16'hDEA9; rom[246] = 16'hE1A1; rom[247] = 16'hE49D;
        rom[248] = 16'hE79D; rom[249] = 16'hEAA1; rom[250] = 16'hEDA9; rom[251] = 16'hF0B3; rom[252] = 16'hF3BF; rom[253] = 16'hF6CE; rom[254] = 16'hF9DE; rom[255] = 16'hFCEF;
    end

    // ---------------- 正弦表同步读 (推断 BSRAM, 节省 LUT) ----------------
    //   4 个失谐振荡器各查一次表, 1 拍延迟(37ns)对音频无影响
    reg signed [15:0] s1, s2, s3, s4;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 16'd0; s2 <= 16'd0; s3 <= 16'd0; s4 <= 16'd0;
        end else if (tick_sample) begin
            s1 <= rom[phase[31:24]];
            s2 <= rom[phase2[31:24]];
            s3 <= rom[phase3[31:24]];
            s4 <= rom[phase4[31:24]];
        end
    end

    // ---------------- 4 份波形 (每个失谐振荡器一份) ----------------
    //   0=正弦  1=三角  2=锯齿  3=方波
    wire signed [15:0] wv1 = (preset == 2'd0) ? s1 :
                             (preset == 2'd1) ? (phase[31]  ? ~phase[30:15]  : phase[30:15])  :
                             (preset == 2'd2) ? phase[31:16]   :
                                                (phase[31]  ? 16'sh6000 : 16'shA000);
    wire signed [15:0] wv2 = (preset == 2'd0) ? s2 :
                             (preset == 2'd1) ? (phase2[31] ? ~phase2[30:15] : phase2[30:15]) :
                             (preset == 2'd2) ? phase2[31:16]  :
                                                (phase2[31] ? 16'sh6000 : 16'shA000);
    wire signed [15:0] wv3 = (preset == 2'd0) ? s3 :
                             (preset == 2'd1) ? (phase3[31] ? ~phase3[30:15] : phase3[30:15]) :
                             (preset == 2'd2) ? phase3[31:16]  :
                                                (phase3[31] ? 16'sh6000 : 16'shA000);
    wire signed [15:0] wv4 = (preset == 2'd0) ? s4 :
                             (preset == 2'd1) ? (phase4[31] ? ~phase4[30:15] : phase4[30:15]) :
                             (preset == 2'd2) ? phase4[31:16]  :
                                                (phase4[31] ? 16'sh6000 : 16'shA000);

    // 4 路相加 (各 1/4 幅度, 防止溢出)
    wire signed [17:0] add_sum = ($signed(wv1) >>> 2) + ($signed(wv2) >>> 2)
                               + ($signed(wv3) >>> 2) + ($signed(wv4) >>> 2);
    wire signed [15:0] wave_out = add_sum[15:0];

    // ---------------- 起音瞬态噪声 ----------------
    //   真实乐器起音都有短暂的'咔/气'声(钢琴锤击、吉他拨弦、长笛气声)
    //   这里用 LFSR 伪随机噪声, 在起音瞬间混入, 并在约 30ms 内指数衰减
    reg  [15:0] lfsr;
    reg  [7:0]  trk_env;
    reg         gate_p;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr    <= 16'hACE1;
            trk_env <= 8'd0;
            gate_p  <= 1'b0;
        end else if (tick_sample) begin
            lfsr   <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            gate_p <= gate;
            if (gate && !gate_p)
                trk_env <= 8'd0;                       // 关闭起音白噪声(听感滋滋/沙沙)
            else if (trk_env > 8'd2)
                trk_env <= trk_env - (trk_env >> 3) - 1'b1;   // 指数衰减
            else
                trk_env <= 8'd0;
        end
    end

    wire signed [15:0] noise = {lfsr[15], lfsr[13], lfsr[11], lfsr[9],
                                lfsr[7],  lfsr[5],  lfsr[3],  lfsr[1], 8'b0};
    wire signed [23:0] trk_mul   = noise * $signed({1'b0, trk_env});
    wire signed [15:0] trk_noise = trk_mul[23:8];

    wire signed [16:0] wave_sum = $signed(wave_out) + trk_noise;
    wire signed [15:0] wave_trk =
        (wave_sum > 17'sd32767)  ? 16'sh7FFF :
        (wave_sum < -17'sd32768) ? 16'sh8000 : wave_sum[15:0];

    // ---------------- 包络 x 力度 x 波形 ----------------
    wire [23:0] env_vol    = env * loud;
    wire [11:0] env_final  = env_vol[23:12];
    wire signed [27:0] prod = wave_trk * $signed({1'b0, env_final});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            sample <= 16'd0;
        else if (tick_sample)  sample <= $signed(prod[27:12]) >>> 1;   // 降半, 给混音留余量(防削顶)
    end

endmodule
