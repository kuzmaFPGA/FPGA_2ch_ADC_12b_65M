// ============================================================
// sdram_ctrl.v — SDR SDRAM контролер для Winbond W9825G6KH-6
//   256Мбіт, 32МБ: 4 банки x 8192 рядки x 512 стовпців x 16 біт
//   -6 grade: до 166МГц/CL3.  ЗА ЗАМОВЧУВАННЯМ: 166МГц/CL3.
//   (для 100/133МГц виставити CLK_MHZ і CL=2)
//   УВАГА: Winbond вимагає 200мкс power-up (не 100мкс як MT48LC).
//
// Плата: QMTECH XC7A35T SDRAM  |  32 MB (4×8192×512×16)
// Таймінги рахуються з CLK_MHZ автоматично (ceil від нс).
//
// Адреса (24-біт word): col=[8:0], row=[21:9], bank=[23:22]
//
// Інтерфейс:
//   cmd_en/cmd_we/cmd_addr/cmd_len → старт burst (len ≤ 512, в межах рядка)
//   WRITE: wr_data+wr_valid (1 word/такт коли wr_ready) — швидко
//   READ:  rd_data+rd_valid (по одному слову, ~CL+2 такти) — для дисплея
//   Refresh — автоматично в IDLE (між командами)
//
// SDRAM clock форвардиться через ODDR ззовні. На 166МГц фаза SDRAM_CLK
// та захоплення DQ критичні — тюнити на HW.
// ============================================================
module sdram_ctrl #(
    parameter CLK_MHZ = 166,   // частота sdram_clk (МГц)
    parameter CL      = 3      // CAS latency: 3 для 166МГц, 2 для ≤133МГц
) (
    input             clk,
    input             reset_n,
    input             cmd_en,
    input             cmd_we,
    input      [23:0] cmd_addr,
    input      [9:0]  cmd_len,
    output            cmd_ready,
    input      [15:0] wr_data,
    input             wr_valid,
    output reg        wr_ready,
    output reg [15:0] rd_data,
    output reg        rd_valid,
    output reg        ready,
    output reg [12:0] sa,
    output reg [1:0]  ba,
    output reg        cke,
    output reg        cs_n,
    output reg        ras_n,
    output reg        cas_n,
    output reg        we_n,
    output reg [1:0]  dqm,
    inout      [15:0] dq
);

// Таймінги: ceil(нс * CLK_MHZ / 1000)
localparam INIT_WAIT   = (200000*CLK_MHZ)/1000;       // 200мкс power-up (Winbond)
localparam T_RCD       = (18*CLK_MHZ + 999)/1000;     // tRCD 18нс
localparam T_RP        = (18*CLK_MHZ + 999)/1000;     // tRP  18нс
localparam T_RFC       = (60*CLK_MHZ + 999)/1000;     // tRC/tRFC 60нс
localparam T_MRD       = 2;                            // tMRD 2 такти
localparam CAS_LAT     = CL;
localparam REFRESH_INT = (7800*CLK_MHZ)/1000;         // <tREF/8192=7.81мкс
localparam [12:0] MODE_REG = CL << 4;                 // BL=1, seq, CL (A6:A4)
// @166МГц: INIT=33200 RCD=3 RP=3 RFC=10 REF=1294 CL=3 MODE=0x030
// @100МГц(CL2): INIT=20000 RCD=2 RP=2 RFC=6 REF=780 MODE=0x020

localparam CMD_NOP      = 4'b0111;
localparam CMD_ACTIVE   = 4'b0011;
localparam CMD_READ     = 4'b0101;
localparam CMD_WRITE    = 4'b0100;
localparam CMD_PRECHARGE= 4'b0010;
localparam CMD_REFRESH  = 4'b0001;
localparam CMD_LOADMODE = 4'b0000;

reg [3:0] cmd_r;
always @(*) {cs_n, ras_n, cas_n, we_n} = cmd_r;

reg [15:0] dq_out;
reg        dq_oe;
assign dq = dq_oe ? dq_out : 16'hZZZZ;
(* IOB = "TRUE" *) reg [15:0] dq_in_r;  // вхідний регістр у IOB (таймінг @166МГц)
always @(posedge clk) dq_in_r <= dq;

reg [23:0] addr_r;
reg [9:0]  len_r;
reg        we_op;
wire [8:0]  col  = addr_r[8:0];
wire [12:0] row  = addr_r[21:9];
wire [1:0]  bank = addr_r[23:22];

localparam
    S_INIT_WAIT  = 5'd0,  S_INIT_PRE  = 5'd1,  S_INIT_PRE_W = 5'd2,
    S_INIT_REF   = 5'd3,  S_INIT_REF_W= 5'd4,  S_INIT_MODE  = 5'd5,
    S_INIT_MODE_W= 5'd6,  S_IDLE      = 5'd7,  S_REFRESH    = 5'd8,
    S_REFRESH_W  = 5'd9,  S_ACTIVE    = 5'd10, S_ACTIVE_W   = 5'd11,
    S_WRITE      = 5'd12, S_WRITE_END = 5'd13, S_READ_CMD   = 5'd14,
    S_READ_WAIT  = 5'd15, S_READ_CAP  = 5'd16, S_PRECHARGE  = 5'd17,
    S_PRE_W      = 5'd18;

reg [4:0]  state;
reg [15:0] wait_cnt;
reg [2:0]  init_ref_cnt;
reg [9:0]  burst_cnt;
reg [10:0] refresh_timer;
reg        refresh_pending;
assign cmd_ready = (state == S_IDLE) && !refresh_pending && ready;
reg [2:0]  lat_cnt;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= S_INIT_WAIT; cmd_r <= CMD_NOP;
        cke <= 0; sa <= 0; ba <= 0; dqm <= 2'b11;
        dq_oe <= 0; dq_out <= 0; ready <= 0;
        wr_ready <= 0; rd_valid <= 0; rd_data <= 0;
        wait_cnt <= 0; init_ref_cnt <= 0; burst_cnt <= 0;
        lat_cnt <= 0; refresh_timer <= 0; refresh_pending <= 0;
        addr_r <= 0; len_r <= 0; we_op <= 0;
    end else begin
        cmd_r <= CMD_NOP;
        wr_ready <= 0; rd_valid <= 0; dq_oe <= 0;

        if (refresh_timer >= REFRESH_INT) begin
            refresh_pending <= 1; refresh_timer <= 0;
        end else if (ready) refresh_timer <= refresh_timer + 1;

        case (state)
            S_INIT_WAIT: begin
                cke <= 1; dqm <= 2'b11;
                if (wait_cnt >= INIT_WAIT) begin
                    wait_cnt <= 0; state <= S_INIT_PRE;
                end else wait_cnt <= wait_cnt + 1;
            end
            S_INIT_PRE: begin
                cmd_r <= CMD_PRECHARGE; sa <= 13'h400;
                wait_cnt <= 0; state <= S_INIT_PRE_W;
            end
            S_INIT_PRE_W: begin
                if (wait_cnt >= T_RP) begin
                    wait_cnt <= 0; init_ref_cnt <= 0; state <= S_INIT_REF;
                end else wait_cnt <= wait_cnt + 1;
            end
            S_INIT_REF: begin
                cmd_r <= CMD_REFRESH; wait_cnt <= 0; state <= S_INIT_REF_W;
            end
            S_INIT_REF_W: begin
                if (wait_cnt >= T_RFC) begin
                    wait_cnt <= 0;
                    if (init_ref_cnt >= 3'd7) state <= S_INIT_MODE;
                    else begin init_ref_cnt <= init_ref_cnt + 1; state <= S_INIT_REF; end
                end else wait_cnt <= wait_cnt + 1;
            end
            S_INIT_MODE: begin
                cmd_r <= CMD_LOADMODE; ba <= 2'b00; sa <= MODE_REG;
                wait_cnt <= 0; state <= S_INIT_MODE_W;
            end
            S_INIT_MODE_W: begin
                if (wait_cnt >= T_MRD) begin
                    ready <= 1; dqm <= 2'b00; state <= S_IDLE;
                end else wait_cnt <= wait_cnt + 1;
            end
            S_IDLE: begin
                dqm <= 2'b00;
                if (refresh_pending) begin
                    state <= S_REFRESH;
                end else if (cmd_en) begin
                    // accepted (cmd_ready комбінаційний)
                    addr_r <= cmd_addr; len_r <= cmd_len; we_op <= cmd_we;
                    burst_cnt <= 0; state <= S_ACTIVE;
                end
            end
            S_REFRESH: begin
                cmd_r <= CMD_REFRESH; refresh_pending <= 0;
                wait_cnt <= 0; state <= S_REFRESH_W;
            end
            S_REFRESH_W: begin
                if (wait_cnt >= T_RFC) state <= S_IDLE;
                else wait_cnt <= wait_cnt + 1;
            end
            S_ACTIVE: begin
                cmd_r <= CMD_ACTIVE; ba <= bank; sa <= row;
                wait_cnt <= 0; state <= S_ACTIVE_W;
            end
            S_ACTIVE_W: begin
                if (wait_cnt >= T_RCD)
                    state <= we_op ? S_WRITE : S_READ_CMD;
                else wait_cnt <= wait_cnt + 1;
            end
            S_WRITE: begin
                wr_ready <= 1;
                if (wr_valid) begin
                    cmd_r  <= CMD_WRITE;
                    ba     <= bank;
                    sa     <= {4'd0, (col + burst_cnt[8:0])};
                    dq_oe  <= 1;
                    dq_out <= wr_data;
                    burst_cnt <= burst_cnt + 1;
                    if (burst_cnt + 1 >= len_r) begin
                        wr_ready <= 0; wait_cnt <= 0; state <= S_WRITE_END;
                    end
                end
            end
            S_WRITE_END: begin
                if (wait_cnt >= 14'd2) state <= S_PRECHARGE;
                else wait_cnt <= wait_cnt + 1;
            end
            S_READ_CMD: begin
                cmd_r  <= CMD_READ;
                ba     <= bank;
                sa     <= {4'd0, (col + burst_cnt[8:0])};
                lat_cnt<= 0;
                state  <= S_READ_WAIT;
            end
            S_READ_WAIT: begin
                // CAS_LAT + 1 (реєстр dq_in_r додає 1 такт)
                if (lat_cnt >= CAS_LAT + 3'd1) state <= S_READ_CAP;
                else lat_cnt <= lat_cnt + 1;
            end
            S_READ_CAP: begin
                rd_data  <= dq_in_r;
                rd_valid <= 1;
                burst_cnt <= burst_cnt + 1;
                if (burst_cnt + 1 >= len_r) begin
                    wait_cnt <= 0; state <= S_PRECHARGE;
                end else state <= S_READ_CMD;
            end
            S_PRECHARGE: begin
                cmd_r <= CMD_PRECHARGE; ba <= bank; sa <= 13'h400;
                wait_cnt <= 0; state <= S_PRE_W;
            end
            S_PRE_W: begin
                if (wait_cnt >= T_RP) state <= S_IDLE;
                else wait_cnt <= wait_cnt + 1;
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
