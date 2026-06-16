// ============================================================
// dds.v - DDS генератор на основі VHDL алгоритму (dds_synthesizer)
//
// Синус: quarter-wave LUT + quadrant symmetry (як у VHDL проекті).
//   Фаза 12-біт → розбивається на:
//     bit 11 = quadrant_3_or_4 (від'ємна напіввісь)
//     bit 10 = quadrant_2_or_4 (відбита напівхвиля в квадранті)
//     bits 9:0 = позиція всередині квадранту (0..1023)
//
//   Відбиття для Q2,Q4: addr = ~raw (= 1023-raw, без виходу за межі)
//   Центрування: LUT повертає 0..8191, додаємо 8192 → вихід 8192..16383
//   Від'ємна напіввісь: 8192 - LUT_val → вихід 8192..1
//
// Вихід DAC (straight binary для DAC904):
//   0x0000 = мін (від'ємний пік синуса)
//   0x2000 = 8192 = нуль (середня шкала)
//   0x3FFF = 16383 = макс (позитивний пік)
//
// Режими:
//   SINE     (0) - квадрантний синус
//   SQUARE   (1) - меандр (phase_acc[31])
//   TRIANGLE (2) - трикутний (phase_acc[30:17] з інверсією)
//   PWM      (3) - ШИМ (comparator з pwm_threshold)
// ============================================================
module dds (
    input             clk,             // 165 МГц (clk_dac)
    input             reset_n,
    input      [31:0] phase_inc,       // = freq * 2^32 / f_clk
    input      [1:0]  wave_type,
    input      [13:0] pwm_threshold,   // 0..16383 для ШИМ
    output reg [13:0] dac_out
);

localparam WAVE_SINE     = 2'd0;
localparam WAVE_SQUARE   = 2'd1;
localparam WAVE_TRIANGLE = 2'd2;
localparam WAVE_PWM      = 2'd3;

// ── Phase accumulator ─────────────────────────────────────────
reg [31:0] phase_acc;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) phase_acc <= 32'd0;
    else          phase_acc <= phase_acc + phase_inc;
end

// ── Розбивка фази на 12 біт (top 12 of accumulator) ──────────
wire [11:0] phase_12  = phase_acc[31:20];
wire        q3_or_4   = phase_12[11];   // від'ємна напіввісь
wire        q2_or_4   = phase_12[10];   // відбита напівхвиля
wire [9:0]  raw_idx   = phase_12[9:0];  // позиція в квадранті

// ── Відбиття індексу для Q2 і Q4 ─────────────────────────────
// Q1,Q3: addr = raw_idx       (зростає  0..1023)
// Q2,Q4: addr = ~raw_idx      (спадає  1023..0)
// ~raw_idx = 1023 - raw_idx для 10-біт - без виходу за межі
wire [9:0] lut_addr = q2_or_4 ? ~raw_idx : raw_idx;

// ── Quarter-wave sine LUT (1024 × 13-біт) ────────────────────
wire [12:0] lut_val;
sine_lut_q sine_lut_q_inst (
    .clk (clk),
    .addr(lut_addr),
    .val (lut_val)      // затримка 1 такт
);

// ── Pipeline: центрування + знак ─────────────────────────────
// Цикл T+1 → lut_val готовий з addr, що відповідає phase_acc[T]
// Затримуємо q3_or_4 на 2 цикли щоб синхронізувати з LUT+обчисленням
reg [13:0] lut_pos;      // позитивна напіввісь
reg [13:0] lut_neg;      // від'ємна напіввісь
reg        q34_d1, q34_d2;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        lut_pos  <= 14'd8192;
        lut_neg  <= 14'd8192;
        q34_d1   <= 1'b0;
        q34_d2   <= 1'b0;
    end else begin
        // Цикл T+2: lut_val має значення для phase_acc[T]
        lut_pos  <= 14'd8192 + {1'b0, lut_val};  // 8192..16383
        lut_neg  <= 14'd8192 - {1'b0, lut_val};  // 8192..1
        q34_d1   <= q3_or_4;
        q34_d2   <= q34_d1;
    end
end

// Комбінаційний вибір: neg або pos (обидва синхронні)
wire [13:0] sine_out = q34_d2 ? lut_neg : lut_pos;

// ── Трикутний сигнал (з phase_acc) ───────────────────────────
wire [13:0] tri_val = phase_acc[31]
    ? ~phase_acc[30:17]   // спадаюча частина: 16383..0
    :  phase_acc[30:17];  // зростаюча частина: 0..16383

// ── Вибір форми і реєстрація виходу ──────────────────────────
always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
        dac_out <= 14'd8192;  // нуль на середині шкали
    else begin
        case (wave_type)
            WAVE_SINE:     dac_out <= sine_out;
            WAVE_SQUARE:   dac_out <= phase_acc[31] ? 14'h3FFF : 14'h0000;
            WAVE_TRIANGLE: dac_out <= tri_val;
            WAVE_PWM:      dac_out <= (phase_acc[31:18] < pwm_threshold)
                                         ? 14'h3FFF : 14'h0000;
            default:       dac_out <= 14'd8192;
        endcase
    end
end

endmodule