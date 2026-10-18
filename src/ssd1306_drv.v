`timescale 1ns/1ps
// ============================================================================
//  SSD1306 OLED 驱动 (0.96寸 I2C, 128x64)
//
//    显示内容: 8 个声部的电平柱状图 (每柱 16 像素宽 x 64 高)
//              —— 直观体现"8 声部复音"的实时状态
//
//    ★ 总线互斥: 与 ADS1115 共享 I2C 总线(H12/G11)
//      - adc_busy = 1 时本模块等待
//      - oled_busy = 1 期间 ADS1115 等待
//
//    I2C: 100kHz, 从地址 0x3C (写地址 0x78)
// ============================================================================
module ssd1306_drv (
    input  wire        clk,          // 27MHz
    input  wire        rst_n,
    inout  wire        sda,
    output wire        scl,
    input  wire        adc_busy,     // ADS1115 正在用总线
    output reg         oled_busy,    // 本模块正在用总线
    input  wire [5:0]  lv0, lv1, lv2, lv3, lv4, lv5, lv6, lv7,
    output reg         ack_ok,       // 1 = 收到过 OLED 的 ACK (证明通信成功)
    output reg [1:0]   phase_dbg     // 0=等上电 1=发初始化命令 2=发显示数据
);

    // ---------------- I2C 位时基: 100kHz ----------------
    localparam [7:0] HALF = 8'd134;         // 135 clk @27MHz = 5us
    reg [7:0] div;
    wire      tick = (div == HALF);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div <= 8'd0;
        else        div <= tick ? 8'd0 : div + 1'b1;
    end

    // ---------------- SDA 三态 / SCL ----------------
    reg sda_o, sda_oe, scl_r;
    assign sda = sda_oe ? sda_o : 1'bz;
    assign scl = scl_r;
    wire   sda_i = sda;

    // ---------------- 上电延时 (~0.6s) ----------------
    reg [23:0] pwr;
    wire       pwr_done = (pwr == 24'hFFFFFF);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            pwr <= 24'd0;
        else if (!pwr_done)    pwr <= pwr + 1'b1;
    end

    // ---------------- 初始化命令表 (31 条) ----------------
    reg [7:0] cmd [0:30];
    initial begin
        cmd[0]  = 8'hAE;                            // display off
        cmd[1]  = 8'hD5; cmd[2]  = 8'h80;           // clock divide
        cmd[3]  = 8'hA8; cmd[4]  = 8'h3F;           // multiplex = 64
        cmd[5]  = 8'hD3; cmd[6]  = 8'h00;           // display offset
        cmd[7]  = 8'h40;                            // start line = 0
        cmd[8]  = 8'h8D; cmd[9]  = 8'h14;           // charge pump ON
        cmd[10] = 8'h20; cmd[11] = 8'h00;           // memory mode = horizontal
        cmd[12] = 8'hA1;                            // segment remap
        cmd[13] = 8'hC8;                            // COM scan dir
        cmd[14] = 8'hDA; cmd[15] = 8'h12;           // COM pins
        cmd[16] = 8'h81; cmd[17] = 8'hCF;           // contrast
        cmd[18] = 8'hD9; cmd[19] = 8'hF1;           // pre-charge
        cmd[20] = 8'hDB; cmd[21] = 8'h40;           // VCOMH
        cmd[22] = 8'hA5;                            // [诊断] entire display ON: 强制全屏点亮
        cmd[23] = 8'hA6;                            // normal (not inverted)
        cmd[24] = 8'hAF;                            // display ON
        cmd[25] = 8'h21; cmd[26] = 8'h00; cmd[27] = 8'h7F;   // 列地址 0~127
        cmd[28] = 8'h22; cmd[29] = 8'h00; cmd[30] = 8'h07;   // 页地址 0~7
    end

    // ---------------- 显示数据生成 ----------------
    //   di: 0~1023 -> 页 = di[9:7], 列 = di[6:0]
    reg [10:0] di;
    wire [2:0] pg   = di[9:7];
    wire [6:0] col  = di[6:0];
    wire [2:0] bar  = col[6:4];                 // 每 16 列一条柱
    wire [5:0] lv   = (bar == 3'd0) ? lv0 :
                      (bar == 3'd1) ? lv1 :
                      (bar == 3'd2) ? lv2 :
                      (bar == 3'd3) ? lv3 :
                      (bar == 3'd4) ? lv4 :
                      (bar == 3'd5) ? lv5 :
                      (bar == 3'd6) ? lv6 : lv7;
    wire [7:0] pix  = (lv > {pg, 3'b111}) ? 8'hFF : 8'h00;
    wire [7:0] pix_show = (boot != 4'd0) ? (boot[0] ? 8'hFF : 8'h00) : pix;  // 自检: 亮灭交替闪烁

    // ---------------- 主状态机 ----------------
    localparam [3:0]
        P_IDLE  = 4'd0,
        P_START = 4'd1,      // START 条件(3 子步)
        P_BYTE  = 4'd2,      // 发送 1 字节(18 子步)
        P_STOP  = 4'd3,      // STOP 条件(3 子步)
        P_WAIT  = 4'd4;      // 帧间延时

    reg [3:0]  st;
    reg [4:0]  sub;          // 子步计数
    reg [7:0]  shf;          // 发送移位
    reg [5:0]  ci;           // 命令索引 0~30
    reg [2:0]  ti;           // 事务内字节号 0/1/2
    reg [3:0]  boot;         // 开机自检帧计数(前几帧全屏点亮, 方便确认屏幕工作)
    reg        after_data;   // 1 = 本事务是"显示数据"事务(发完才进帧间等待)
    reg [23:0] gap;          // 帧间延时计数
    reg        data_phase;   // 0=发初始化命令, 1=发显示数据

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= P_IDLE; sub <= 5'd0; shf <= 8'd0;
            ci <= 6'd0; ti <= 3'd0; di <= 11'd0;
            scl_r <= 1'b1; sda_o <= 1'b1; sda_oe <= 1'b0;
            oled_busy <= 1'b0; gap <= 24'd0; data_phase <= 1'b0;
            boot <= 4'd15;
            phase_dbg <= 2'd0;
            after_data <= 1'b0;
        end else if (tick) begin
            case (st)
                // ---------- 等待上电 + 总线空闲 ----------
                P_IDLE: begin
                    sda_oe <= 1'b0;
                    if (pwr_done && !adc_busy) begin
                        oled_busy <= 1'b1;
                        phase_dbg <= 2'd1;      // 开始发初始化命令
                        st <= P_START;
                        sub <= 5'd0;
                    end
                end

                // ---------- START: SCL 高时 SDA 下降 ----------
                P_START: begin
                    if (sub == 5'd0) begin
                        scl_r <= 1'b1; sda_oe <= 1'b1; sda_o <= 1'b1;
                        sub <= 5'd1;
                    end else if (sub == 5'd1) begin
                        sda_o <= 1'b0;
                        sub <= 5'd2;
                    end else begin
                        scl_r <= 1'b0;
                        sub <= 5'd0;
                        ti <= 3'd0;
                        st <= P_BYTE;
                    end
                end

                // ---------- 发送一个字节 + 收 ACK ----------
                //   sub=0      : 装载待发字节(不能同时发第1位, 因为非阻塞赋值要下一拍才生效)
                //   sub=1..16  : 8 位数据, 奇数子步设数据(SCL低), 偶数子步拉高SCL
                //   sub=17/18  : ACK 位(释放SDA + SCL高)
                //   sub=19     : 本字节结束
                P_BYTE: begin
                    if (sub == 5'd0) begin
                        if (ti == 3'd0)
                            shf <= 8'h78;                      // 从地址 + 写
                        else if (ti == 3'd1)
                            shf <= data_phase ? 8'h40 : 8'h00; // 控制字节
                        else
                            shf <= data_phase ? pix_show : cmd[ci];
                        scl_r <= 1'b0;
                        sub   <= 5'd1;
                    end else if (sub <= 5'd16) begin
                        if (sub[0]) begin                      // 奇数: 设数据, SCL 低
                            scl_r  <= 1'b0;
                            sda_oe <= 1'b1;
                            sda_o  <= shf[3'd7 - sub[4:1]];
                        end else                               // 偶数: SCL 高(从机采样)
                            scl_r <= 1'b1;
                        sub <= sub + 1'b1;
                    end else if (sub == 5'd17) begin
                        scl_r  <= 1'b0;
                        sda_oe <= 1'b0;                        // ACK 位: 释放 SDA
                        sub    <= 5'd18;
                    end else if (sub == 5'd18) begin
                        scl_r <= 1'b1;                         // 读 ACK
                        sub   <= 5'd19;
                    end else begin
                        // ---- sub == 19: 本字节完成 ----
                        sub <= 5'd0;
                        if (ti == 3'd2) begin
                            if (!data_phase) begin
                                // 初始化阶段: 下一条命令, 或切到数据模式
                                if (ci >= 6'd30) begin
                                    data_phase <= 1'b1;
                                    phase_dbg  <= 2'd2;    // 初始化完成, 开始发显示数据
                                    di <= 11'd0;
                                    boot <= 4'd15;          // 前三帧全屏点亮 = 开机自检
                                end else
                                    ci <= ci + 1'b1;
                                st <= P_STOP;
                            end else begin
                                // 数据阶段: 连续发 1024 字节
                                if (di >= 11'd1023) begin
                                    after_data <= 1'b1;   // 数据发完, 本事务结束
                                    st <= P_STOP;
                                end else begin
                                    di <= di + 1'b1;
                                    ti <= 3'd2;
                                    st <= P_BYTE;
                                end
                            end
                        end else begin
                            ti <= ti + 1'b1;
                            st <= P_BYTE;
                        end
                    end
                end

                // ---------- STOP: SCL 高时 SDA 上升 ----------
                P_STOP: begin
                    if (sub == 5'd0) begin
                        scl_r <= 1'b0; sda_oe <= 1'b1; sda_o <= 1'b0;
                        sub <= 5'd1;
                    end else if (sub == 5'd1) begin
                        scl_r <= 1'b1;
                        sub <= 5'd2;
                    end else begin
                        sda_o  <= 1'b1;
                        sda_oe <= 1'b0;         // 事务结束: 释放 SDA
                        sub    <= 5'd0;
                        if (after_data) begin
                            // ---- 显示数据发完一整帧 -> 帧间延时后刷新 ----
                            after_data <= 1'b0;
                            gap <= 24'd0;
                            st  <= P_WAIT;
                        end else
                            st <= P_START;      // 继续下一条命令 / 或开始发显示数据
                    end
                end

                // ---------- 帧间延时 (50ms), 给 ADS1115 让出总线 ----------
                P_WAIT: begin
                    oled_busy <= 1'b0;          // 释放总线
                    sda_oe    <= 1'b0;          // 并释放 SDA(高阻)
                    if (gap == 24'd1350000) begin      // 50ms 帧间延时 -> 刷新率约 7Hz
                        gap <= 24'd0;
                        di  <= 11'd0;
                        if (boot != 4'd0) boot <= boot - 1'b1;
                        st  <= P_IDLE;          // 重新申请总线刷新
                    end else
                        gap <= gap + 1'b1;
                end

                default: st <= P_IDLE;
            endcase
        end
    end

    // ---------------- ACK 检测 ----------------
    //   sub==18 时 SCL 为高, 从机拉低 SDA 表示应答
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ack_ok <= 1'b0;
        else if (tick && (st == P_BYTE) && (sub == 5'd18) && !sda_i)
            ack_ok <= 1'b1;
    end

endmodule
