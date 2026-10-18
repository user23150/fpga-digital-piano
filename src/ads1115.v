`timescale 1ns/1ps
// ============================================================================
//  ADS1115 读取器 (I2C 主机, 100kHz)
//
//    循环读取 A0 单端电压, 输出 16bit 有符号值:
//        0x0000 ~ 0x7FFF  =  0 ~ +4.096V
//
//    接线:  SDA <-> H12      SCL -> G11
//
//    操作序列:
//      1) START, 写地址0x90, 配置寄存器0x01, 0xC3, 0x83, STOP
//         (OS=1开始转换, MUX=A0/GND, PGA=±4.096V, 单次模式, 128SPS)
//      2) 等待 10ms
//      3) START, 0x90, 0x00, 重复START, 0x91, 读2字节, STOP
// ============================================================================
module ads1115 (
    input  wire        clk,        // 27MHz
    input  wire        rst_n,
    inout  wire        sda,
    output wire        scl,
    output reg  [15:0] adc,        // ADC 结果 (有符号)
    output reg         adc_ok      // 新数据到位脉冲
);

    // ---------------- I2C 位时序: 半周期 5us -> 100kHz ----------------
    localparam [7:0] HALF = 8'd134;        // 135 clk @27MHz = 5us
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

    // ---------------- 操作码序列 ----------------
    //   0xF0 = START    0xF1 = STOP    0xF2 = 等待
    //   0xF3 = 读字节+ACK            0xF4 = 读字节+NACK
    //   其他 = 发送该字节
    reg [3:0] seq;
    reg [7:0] op;
    always @(*) begin
        case (seq)
            4'd0:    op = 8'hF0;    // START
            4'd1:    op = 8'h90;    // 写地址 (0x48<<1)
            4'd2:    op = 8'h01;    // 配置寄存器指针
            4'd3:    op = 8'hC3;    // 配置高字节
            4'd4:    op = 8'h83;    // 配置低字节
            4'd5:    op = 8'hF1;    // STOP
            4'd6:    op = 8'hF2;    // WAIT
            4'd7:    op = 8'hF0;    // START
            4'd8:    op = 8'h90;    // 写地址
            4'd9:    op = 8'h00;    // 转换寄存器指针
            4'd10:   op = 8'hF0;    // 重复 START
            4'd11:   op = 8'h91;    // 读地址
            4'd12:   op = 8'hF3;    // 读高字节 + ACK
            4'd13:   op = 8'hF4;    // 读低字节 + NACK
            4'd14:   op = 8'hF1;    // STOP
            default: op = 8'hFF;    // 结束
        endcase
    end

    // ---------------- 状态机 ----------------
    localparam [2:0]
        ST_IDLE  = 3'd0,
        ST_NEXT  = 3'd1,
        ST_START = 3'd2,
        ST_TX    = 3'd3,
        ST_RX    = 3'd4,
        ST_STOP  = 3'd5,
        ST_WAIT  = 3'd6;

    reg [2:0]  st;
    reg [4:0]  sub;         // 状态内步骤
    reg [7:0]  sh;          // 发送移位
    reg [7:0]  rx;          // 接收移位
    reg [7:0]  rx_hi;       // 高字节暂存
    reg [21:0] waitc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= ST_IDLE;
            sub    <= 5'd0;
            seq    <= 4'd0;
            scl_r  <= 1'b1;
            sda_o  <= 1'b1;
            sda_oe <= 1'b0;          // 空闲必须释放 SDA(高阻), 否则会钳住总线
            adc    <= 16'd0;
            adc_ok <= 1'b0;
            waitc  <= 22'd0;
            rx_hi  <= 8'd0;
        end else if (tick) begin
            adc_ok <= 1'b0;

            case (st)
                // ------------------------------------------------
                ST_IDLE: begin
                    st  <= ST_NEXT;
                    sub <= 5'd0;
                end
                // ------------------------------------------------
                ST_NEXT: begin
                    if (op == 8'hFF) begin
                        seq <= 4'd0;
                        st  <= ST_IDLE;
                    end else if (op == 8'hF0) begin          // START
                        st  <= ST_START;
                        sub <= 5'd0;
                    end else if (op == 8'hF1) begin          // STOP
                        st  <= ST_STOP;
                        sub <= 5'd0;
                    end else if (op == 8'hF2) begin          // WAIT
                        st    <= ST_WAIT;
                        waitc <= 22'd0;
                    end else if (op == 8'hF3 || op == 8'hF4) begin  // 读字节
                        st  <= ST_RX;
                        sub <= 5'd0;
                        rx  <= 8'd0;
                    end else begin                           // 发送字节
                        st  <= ST_TX;
                        sub <= 5'd0;
                        sh  <= op;
                    end
                end
                // ------------------------------------------------
                // START 条件 (3 步)
                ST_START: begin
                    if (sub == 5'd0) begin
                        scl_r <= 1'b1; sda_oe <= 1'b1; sda_o <= 1'b1;
                        sub   <= 5'd1;
                    end else if (sub == 5'd1) begin
                        sda_o <= 1'b0;              // SCL 高时 SDA 下降
                        sub   <= 5'd2;
                    end else begin
                        scl_r <= 1'b0;              // 拉低 SCL
                        sub   <= 5'd0;
                        seq   <= seq + 1'b1;
                        st    <= ST_NEXT;
                    end
                end
                // ------------------------------------------------
                // 发送 8 位 + ACK  (每位 2 步, 共 18 步)
                ST_TX: begin
                    if (sub[0] == 1'b0) begin
                        scl_r <= 1'b0;
                        if (sub < 5'd16) begin
                            sda_oe <= 1'b1;
                            sda_o  <= sh[3'd7 - sub[4:1]];
                        end else begin
                            sda_oe <= 1'b0;         // ACK 位释放 SDA
                        end
                    end else begin
                        scl_r <= 1'b1;
                    end

                    if (sub == 5'd17) begin
                        sub <= 5'd0;
                        seq <= seq + 1'b1;
                        st  <= ST_NEXT;
                    end else
                        sub <= sub + 1'b1;
                end
                // ------------------------------------------------
                // 接收 8 位 + 发送 ACK/NACK
                ST_RX: begin
                    if (sub < 5'd16) begin
                        if (sub[0] == 1'b0) begin
                            scl_r  <= 1'b0;
                            sda_oe <= 1'b0;
                        end else begin
                            scl_r <= 1'b1;
                            rx    <= {rx[6:0], sda_i};
                        end
                    end else if (sub == 5'd16) begin
                        scl_r  <= 1'b0;
                        sda_oe <= 1'b1;
                        sda_o  <= (op == 8'hF3) ? 1'b0 : 1'b1;   // ACK / NACK
                    end else begin
                        scl_r <= 1'b1;
                    end

                    if (sub == 5'd17) begin
                        sub <= 5'd0;
                        if (seq == 4'd12) rx_hi <= rx;           // 高字节
                        if (seq == 4'd13) begin                  // 低字节 -> 输出
                            adc    <= {rx_hi, rx};
                            adc_ok <= 1'b1;
                        end
                        seq <= seq + 1'b1;
                        st  <= ST_NEXT;
                    end else
                        sub <= sub + 1'b1;
                end
                // ------------------------------------------------
                // STOP 条件 (3 步)
                ST_STOP: begin
                    if (sub == 5'd0) begin
                        scl_r <= 1'b0; sda_oe <= 1'b1; sda_o <= 1'b0;
                        sub   <= 5'd1;
                    end else if (sub == 5'd1) begin
                        scl_r <= 1'b1;              // SCL 拉高 (SDA 仍低)
                        sub   <= 5'd2;
                    end else begin
                        sda_o  <= 1'b1;             // SCL 高时 SDA 上升
                        sda_oe <= 1'b0;             // 事务结束: 释放 SDA
                        sub    <= 5'd0;
                        seq    <= seq + 1'b1;
                        st    <= ST_NEXT;
                    end
                end
                // ------------------------------------------------
                ST_WAIT: begin
                    sda_oe <= 1'b0;                 // 等待期间释放总线
                    if (waitc >= 22'd269999) begin  // 10ms
                        waitc <= 22'd0;
                        seq   <= seq + 1'b1;
                        st    <= ST_NEXT;
                    end else
                        waitc <= waitc + 1'b1;
                end
                // ------------------------------------------------
                default: st <= ST_IDLE;
            endcase
        end
    end

endmodule
