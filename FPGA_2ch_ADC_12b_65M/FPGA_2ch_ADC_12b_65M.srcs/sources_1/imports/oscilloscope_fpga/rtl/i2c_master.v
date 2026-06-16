// ============================================================
// i2c_master.v - I2C master з таймаутом, cooldown, auto-scan
// v5: clock stretching + timeout + mandatory cooldown after STOP
// ============================================================
module i2c_master #(
    parameter CLK_HZ    = 50_000_000,
    parameter I2C_HZ    = 100_000,
    parameter SLAVE_ADDR= 7'h42,
    parameter DO_SCAN   = 0
) (
    input              clk,
    input              reset_n,
    inout              SCL,
    inout              SDA,
    input              IRQ_N,
    output reg [3:0]   btn_state,
    output reg [3:0]   btn_changed,
    output reg signed [15:0] enc0_pos,
    output reg signed [15:0] enc1_pos,
    output reg signed [15:0] enc2_pos,
    output reg signed [15:0] enc3_pos,
    output reg [3:0]   key_code,
    output reg         key_pressed,
    output reg         update_pulse,
    output reg         i2c_busy,
    output reg         i2c_err,
    output reg [6:0]   found_addr,
    output reg         scan_done,
    output reg [6:0]   scan_cur_addr
);

// ── Тактування ──
localparam integer DIV = (CLK_HZ / (I2C_HZ * 4));
reg [9:0] tick_cnt;
reg       phase_tick;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin tick_cnt<=0; phase_tick<=0; end
    else begin
        phase_tick<=0;
        if (tick_cnt+1 >= DIV[9:0]) begin tick_cnt<=0; phase_tick<=1; end
        else tick_cnt<=tick_cnt+1;
    end
end

// ── Open-drain ──
reg scl_oe, sda_oe;
assign SCL = scl_oe ? 1'b0 : 1'bz;
assign SDA = sda_oe ? 1'b0 : 1'bz;

(* ASYNC_REG="TRUE" *) reg sda_s1, sda_s2;
(* ASYNC_REG="TRUE" *) reg scl_s1, scl_s2;  // для clock stretching detection
(* ASYNC_REG="TRUE" *) reg irq_s1, irq_s2;
always @(posedge clk) begin
    sda_s1<=SDA; sda_s2<=sda_s1;
    scl_s1<=SCL; scl_s2<=scl_s1;
    irq_s1<=IRQ_N; irq_s2<=irq_s1;
end
wire sda_in = sda_s2;

// ── FSM ──
localparam
    S_IDLE       = 5'd0,
    S_COOLDOWN   = 5'd1,
    S_START_SDA  = 5'd2,   // SDA↓ (SCL=high)
    S_START_SCL  = 5'd3,   // SCL↓
    S_LOAD       = 5'd4,   // завантажити shift_out
    S_BIT_SDA    = 5'd5,   // SDA=bit, SCL=low
    S_BIT_SCL_HI = 5'd6,   // SCL↑
    S_BIT_SCL_LO = 5'd7,   // SCL↓, зсув
    S_ACK_SDA    = 5'd8,   // SDA=ack_drive, SCL=low
    S_ACK_SCL_HI = 5'd9,   // SCL↑
    S_ACK_SCL_LO = 5'd10,  // SCL↓, прочитати ACK
    S_RSTART_SDA = 5'd11,  // SDA↑ (для repeated start)
    S_RSTART_SCL = 5'd12,  // SCL↑
    S_RSTART_DROP= 5'd13,  // SDA↓ (repeated START)
    S_STOP_SDA   = 5'd14,  // SDA=low, SCL=low
    S_STOP_SCL   = 5'd15,  // SCL↑
    S_STOP_DONE  = 5'd16,  // SDA↑ = STOP
    S_SCAN_INIT  = 5'd17,
    S_SCAN_NEXT  = 5'd18;

reg [4:0] state;
reg [3:0] bit_cnt;
reg [3:0] byte_cnt;
reg [7:0] shift_out;
reg [7:0] shift_in;
reg       ack_rx;
reg [3:0] step;
reg [15:0] cool_cnt;        // cooldown counter
reg [15:0] timeout_cnt;     // таймаут для stuck bus

localparam BYTES = 11;
localparam COOL_TICKS = 16'd2000;   // ~5 мс cooldown
localparam TIMEOUT    = 16'd10000;  // ~25 мс таймаут

reg [7:0] rx_buf [0:BYTES-1];
integer i;

reg [6:0] active_addr;
reg       scan_mode;
reg [7:0] scan_delay;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state<=S_IDLE; bit_cnt<=0; byte_cnt<=0; step<=0;
        scl_oe<=0; sda_oe<=0; shift_out<=0; shift_in<=0; ack_rx<=0;
        i2c_busy<=0; i2c_err<=0; update_pulse<=0;
        btn_state<=0; btn_changed<=0;
        enc0_pos<=0; enc1_pos<=0; enc2_pos<=0; enc3_pos<=0;
        key_code<=0; key_pressed<=0;
        for(i=0;i<BYTES;i=i+1) rx_buf[i]<=0;
        found_addr<=0; scan_done<=(DO_SCAN==0); scan_cur_addr<=7'h03;
        active_addr<=SLAVE_ADDR;
        scan_mode<=(DO_SCAN!=0);
        scan_delay<=0; cool_cnt<=0; timeout_cnt<=0;
        if (DO_SCAN != 0) state<=S_SCAN_INIT;
    end else begin
        update_pulse<=0;
        key_pressed<=0;
        if (phase_tick) begin
            case (state)

            // ── IDLE: чекаємо IRQ LOW ──
            S_IDLE: begin
                scl_oe<=0; sda_oe<=0;
                timeout_cnt<=0;
                if (!scan_mode && scan_done && !irq_s2) begin
                    i2c_busy<=1; i2c_err<=0;
                    step<=0; byte_cnt<=0; bit_cnt<=0;
                    ack_rx<=0;            // ← очистити залишок від попередньої транзакції!
                    state<=S_START_SDA;
                end
            end

            // ── COOLDOWN: обов'язкова пауза після STOP ──
            S_COOLDOWN: begin
                scl_oe<=0; sda_oe<=0;
                if (cool_cnt >= COOL_TICKS) begin
                    cool_cnt<=0;
                    i2c_busy<=0;
                    state<=S_IDLE;
                end else
                    cool_cnt<=cool_cnt+1;
            end

            // ── START condition ──
            S_START_SDA: begin
                scl_oe<=0; sda_oe<=1;    // SDA↓ поки SCL=high
                state<=S_START_SCL;
            end
            S_START_SCL: begin
                scl_oe<=1;               // SCL↓
                state<=S_LOAD;
            end

            // ── Завантаження байта ──
            S_LOAD: begin
                bit_cnt<=0;
                if (scan_mode)
                    shift_out<={scan_cur_addr, 1'b0};
                else begin
                    case(step)
                        0: shift_out<={active_addr, 1'b0};
                        1: shift_out<=8'h00;
                        3: shift_out<={active_addr, 1'b1};
                        default: shift_out<=8'hFF;  // read: SDA high (master releases)
                    endcase
                end
                state<=S_BIT_SDA;
            end

            // ── Передача/прийом 8 біт ──
            S_BIT_SDA: begin
                scl_oe<=1;
                // write: drive SDA; read (step>=4): release SDA
                if (!scan_mode && step>=4)
                    sda_oe<=0;
                else
                    sda_oe<=~shift_out[7];
                state<=S_BIT_SCL_HI;
            end
            S_BIT_SCL_HI: begin
                scl_oe<=0;                // SCL release
                if (scl_s2) begin         // SCL реально high
                    shift_in<={shift_in[6:0], sda_in};  // читати SDA поки SCL=high
                    state<=S_BIT_SCL_LO;
                end
            end
            S_BIT_SCL_LO: begin
                scl_oe<=1;                // SCL↓
                shift_out<={shift_out[6:0], 1'b1};
                bit_cnt<=bit_cnt+1;
                if (bit_cnt==4'd7) state<=S_ACK_SDA;
                else               state<=S_BIT_SDA;
            end

            // ── ACK/NACK ──
            S_ACK_SDA: begin
                scl_oe<=1;
                if (scan_mode)
                    sda_oe<=0;    // scan: read slave ACK
                else if (step>=4 && step<4+BYTES)
                    // master reading: ACK (drive low) except last byte NACK
                    sda_oe<=(byte_cnt<BYTES-1) ? 1'b1 : 1'b0;
                else
                    sda_oe<=0;    // master writing: release for slave ACK
                state<=S_ACK_SCL_HI;
            end
            S_ACK_SCL_HI: begin
                scl_oe<=0;                // SCL release
                if (scl_s2) begin         // SCL реально high
                    ack_rx<=sda_in;        // читати ACK поки SCL=high
                    state<=S_ACK_SCL_LO;
                end
            end
            S_ACK_SCL_LO: begin
                scl_oe<=1;                // SCL↓
                sda_oe<=0;
                if (scan_mode)
                    state<=S_STOP_SDA;
                else begin
                    if (step>=4 && step<4+BYTES) begin
                        rx_buf[byte_cnt]<=shift_in;
                        byte_cnt<=byte_cnt+1;
                    end
                    // ack_rx тепер свіжий (зчитаний у S_ACK_SCL_HI)
                    if ((step==0 || step==3) && ack_rx) begin
                        i2c_err<=1;
                        state<=S_STOP_SDA;
                    end else begin
                        case(step)
                            0: begin step<=1; state<=S_LOAD; end
                            1: begin step<=2; state<=S_RSTART_SDA; end
                            3: begin step<=4; byte_cnt<=0; state<=S_LOAD; end
                            default: begin
                                if (byte_cnt<BYTES) state<=S_LOAD;
                                else                state<=S_STOP_SDA;
                            end
                        endcase
                    end
                end
            end

            // ── Repeated START ──
            S_RSTART_SDA: begin
                sda_oe<=0; scl_oe<=1;     // SDA↑ (release), SCL=low
                state<=S_RSTART_SCL;
            end
            S_RSTART_SCL: begin
                scl_oe<=0;                // SCL release
                if (scl_s2) state<=S_RSTART_DROP;  // чекати реального SCL high
            end
            S_RSTART_DROP: begin
                sda_oe<=1;               // SDA↓ при SCL=high → repeated START
                step<=3;
                state<=S_START_SCL;       // SCL↓ → LOAD
            end

            // ── STOP ──
            S_STOP_SDA: begin
                sda_oe<=1; scl_oe<=1;     // SDA=low, SCL=low
                state<=S_STOP_SCL;
            end
            S_STOP_SCL: begin
                scl_oe<=0;  state<=S_STOP_DONE;
            end
            S_STOP_DONE: begin
                sda_oe<=0;               // SDA↑ при SCL=high → STOP
                if (scan_mode) begin
                    state<=S_SCAN_NEXT;
                end else begin
                    // Розбір даних
                    if (!i2c_err) begin
                        btn_changed<=rx_buf[0][7:4];
                        btn_state  <=rx_buf[1][3:0];
                        enc0_pos   <={rx_buf[3], rx_buf[2]};
                        enc1_pos   <={rx_buf[5], rx_buf[4]};
                        enc2_pos   <={rx_buf[7], rx_buf[6]};
                        enc3_pos   <={rx_buf[9], rx_buf[8]};
                        if (rx_buf[10][7]) begin
                            key_code   <=rx_buf[10][3:0];
                            key_pressed<=1;
                        end
                        update_pulse<=1;
                    end
                    cool_cnt<=0;
                    state<=S_COOLDOWN;
                end
            end

            // ── SCAN ──
            S_SCAN_INIT: begin
                scan_cur_addr<=7'h03; found_addr<=0; scan_done<=0;
                scan_delay<=0;
                state<=S_SCAN_NEXT;
            end
            S_SCAN_NEXT: begin
                if (scan_delay<8'd40) begin
                    scan_delay<=scan_delay+1;
                    scl_oe<=0; sda_oe<=0;
                end else begin
                    scan_delay<=0;
                    if (!ack_rx && scan_cur_addr>=7'h03) begin
                        // ACK - знайшли!
                        found_addr<=scan_cur_addr;
                        active_addr<=scan_cur_addr;
                        scan_done<=1; scan_mode<=0;
                        cool_cnt<=0; state<=S_COOLDOWN;
                    end else if (scan_cur_addr>=7'h77) begin
                        // Кінець діапазону
                        active_addr<=SLAVE_ADDR;
                        found_addr<=0;
                        scan_done<=1; scan_mode<=0;
                        cool_cnt<=0; state<=S_COOLDOWN;
                    end else begin
                        if (scan_cur_addr>=7'h03)
                            scan_cur_addr<=scan_cur_addr+1;
                        scan_mode<=1;
                        state<=S_START_SDA;
                    end
                end
            end

            default: begin
                scl_oe<=0; sda_oe<=0;
                state<=S_COOLDOWN; cool_cnt<=0;
            end
            endcase

            // ── Глобальний таймаут: якщо FSM зависла ──
            if (state!=S_IDLE && state!=S_COOLDOWN && state!=S_SCAN_INIT && state!=S_SCAN_NEXT) begin
                timeout_cnt<=timeout_cnt+1;
                if (timeout_cnt>=TIMEOUT) begin
                    scl_oe<=0; sda_oe<=0;
                    i2c_err<=1; i2c_busy<=0;
                    cool_cnt<=0;
                    state<=S_COOLDOWN;
                end
            end

        end // phase_tick
    end
end

endmodule