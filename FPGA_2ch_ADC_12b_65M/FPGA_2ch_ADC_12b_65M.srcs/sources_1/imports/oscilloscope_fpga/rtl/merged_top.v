`include "constants.vh"
// ============================================================
// merged_top.v - Об'єднаний вимірювальний прилад
//   Осцилограф + DDS генератор + 8-канальний логічний аналізатор
//
// Три режими працюють ОДНОЧАСНО. Кнопки 1/2/3 вмикають/вимикають
// показ кожного режиму; екран динамічно перерозподіляється між
// активними режимами (вимкнений віддає свою область сусіднім).
//
// Ввід - через I2C від STM32 (4 енкодери з кнопками + матриця 4×4):
//
// Клавіатура (матриця 4×4):
//   1 - toggle показу Oscilloscope
//   2 - toggle показу DDS
//   3 - toggle показу Logic Analyzer
//   4/6 - прокрутка вікна вліво/вправо
//   5 - run/stop
//   7 - UART-канал декодера
//   8 - UART декодер on/off
//   9 - UART baud cycle
//   0 - тестовий сигнал
//   A/B - курсор цифри DDS вліво/вправо
//   D - одноразове захоплення (scope+LA)
//   E - наступний тип DDS-сигналу (SINE→SQR→TRI→PWM)
//   F - boot menu
//
// Енкодери з кнопками:
//   ENC0 + SW0 - T/div (scope+LA)        / reset T/div
//   ENC1 + SW1 - рівень тригера           / toggle фронт тригера
//   ENC2 + SW2 - значення цифри DDS ±1    / курсор → наступна цифра
//   ENC3 + SW3 - шпаруватість ШИМ         / наступний тип сигналу
//
// clk_wiz_0 (5 виходів, clk_out4 не використовується):
//   clk_out1: 50 МГц  (sys_clk / lcd_clk - також вся обробка введення з I2C)
//   clk_out2: 100 МГц (sdram_clk)
//   clk_out3: 60 МГц  (adc_clk)
//   clk_out4: -       (колишній kbd_clk, тепер вільний)
//   clk_out5: 150 МГц (dac_clk)
// Клавіатуру та енкодери сканує STM32, дані надходять по I2C @ sys_clk.
// ============================================================
module top_level #(parameter DEPTH=32768, parameter DEPTH_W=15, parameter PRETRIG=256) (
    input         clk,
    // Клавіатура та енкодери приходять через I2C від STM32 (i2c_master інстанс)
    // LCD
    output [15:0] LCD_DATA,
    output        LCD_WR, LCD_RS, LCD_CS, LCD_RESET, LCD_BL, LCD_RDX,
    // LED
    output        led_1,
    // ADC (scope mode)
    input  [11:0] adc_ch1,
    input  [11:0] adc_ch2,
    output        adc_clk_out1,
    output        adc_clk_out2,
    // SDRAM (scope mode)
    output [12:0] SDRAM_A,
    output [1:0]  SDRAM_BA,
    output        SDRAM_CKE, SDRAM_CSn, SDRAM_WEn, SDRAM_CASn, SDRAM_RASn,
    output [1:0]  SDRAM_DQM,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_CLK,
    // DAC (DDS mode) - 14-біт паралельний @ 150 МГц
    output [13:0] DAC_DATA,
    output        DAC_CLK,
    // Logic Analyzer - 8 каналів + тригер
    input  [7:0]  la_data,
    input         la_trig,
    // I2C для контролера енкодерів (STM32, addr=0x42)
    inout         I2C_SCL,
    inout         I2C_SDA,
    input         I2C_IRQ_N,    // active-low від MCU
    // Touch (не використовується, пін-комплект)
    output        ts_clk, ts_cs, ts_mosi,
    input         ts_miso, ts_pen
);
assign ts_clk=0; assign ts_cs=1; assign ts_mosi=0;

// ── Параметри екрану (динамічна розмітка) ──
localparam SCREEN_W = 800, SCREEN_H = 480;
// Header: y=0..15 (16px, завжди)
// Footer: y=464..479 (16px, завжди)
// Контент: y=16..463 (448px) - розподіляється між увімкненими режимами

localparam [23:0] CH_BASE    = 24'h00_0000;  // scope дані в SDRAM
localparam [23:0] CH_BASE_LA = 24'h08_0000;  // LA дані в SDRAM (окрема область)

localparam [15:0] COL_CH1  = RED;
localparam [15:0] COL_CH2  = YELLOW;
localparam [15:0] COL_BG   = BLUE;
localparam [15:0] COL_GRID = GRAY;
localparam [15:0] COL_TEXT = GREEN;
localparam [15:0] COL_CURS = RED;
localparam [15:0] COL_OFF  = 16'h1082; // темно-сірий для вимкнених регіонів

localparam NCH     = 40;
localparam CHAR_PX = 16;

// ── Динамічні layout-регістри (обчислюються в M_DISPATCH) ──
reg [8:0] r_dds_y0;       // початок DDS тексту
reg [8:0] r_scope_y0;     // початок scope waveform
reg [8:0] r_scope_ye;     // кінець scope waveform
reg [8:0] r_scope_h;      // висота scope (для map_y)
reg [8:0] r_la_y0;        // початок LA region
reg [8:0] r_la_ye;        // кінець LA region
reg [8:0] r_la_ch_h;      // висота одного LA каналу (la_h/8)
reg [8:0] r_uart_y0;      // початок UART hex рядка
reg [8:0] r_hgrid_y0;     // горизонтальна сітка scope: 25%
reg [8:0] r_hgrid_y1;     // 50%
reg [8:0] r_hgrid_y2;     // 75%

// Scope/HGRID координати тепер динамічні (r_scope_y0, r_hgrid_y*)

// ════ TIME/DIV (oscilloscope) ════
// ADC = 60 МГц, 80 пікс/розподіл → time_per_div = dec * 80 / 60_000_000
// * dec=4  → 5.33µs (+6.7%), dec=8 → 10.67µs (+6.7%) - непарне ділення при 60МГц/80
// * решта 8 кроків - точні (похибка 0%)
localparam TDIV_MAX = 4'd9;
function [15:0] tdiv_decimation; input [3:0] i;
  case(i)
    0: tdiv_decimation=16'd4;    // ~5µs  (+6.7%)
    1: tdiv_decimation=16'd8;    // ~10µs (+6.7%)
    2: tdiv_decimation=16'd15;   // 20µs  (точно)
    3: tdiv_decimation=16'd37;   // ~50µs (-1.3%)
    4: tdiv_decimation=16'd75;   // 100µs (точно)
    5: tdiv_decimation=16'd150;  // 200µs (точно)
    6: tdiv_decimation=16'd375;  // 500µs (точно)
    7: tdiv_decimation=16'd750;  // 1ms   (точно)
    8: tdiv_decimation=16'd1500; // 2ms   (точно)
    9: tdiv_decimation=16'd3750; // 5ms   (точно)
    default: tdiv_decimation=16'd15;
  endcase
endfunction
// T/div мітка: 6 ASCII-символів (значення + одиниця)
function [47:0] tdiv_glyphs; input [3:0] i;
  case(i)
    0: tdiv_glyphs={"   5us"};  // 5µs
    1: tdiv_glyphs={"  10us"};
    2: tdiv_glyphs={"  20us"};
    3: tdiv_glyphs={"  50us"};
    4: tdiv_glyphs={" 100us"};
    5: tdiv_glyphs={" 200us"};
    6: tdiv_glyphs={" 500us"};
    7: tdiv_glyphs={"   1ms"};
    8: tdiv_glyphs={"   2ms"};
    9: tdiv_glyphs={"   5ms"};
    default: tdiv_glyphs={"  20us"};
  endcase
endfunction

// ════ DDS ════
// phase_inc = freq_hz * 2^32 / DAC_HZ
// phase_inc = (freq_chz * K_CHZ) >> 16
// K_CHZ = 2^48 / (DAC_HZ * 100)
// DAC_HZ = 150_000_000 → K_CHZ = 2^48 / 15_000_000_000 = 18764 (похибка 0.005%)
localparam [47:0] K_CHZ = 48'd18764;
localparam DDS_DIGITS = 8;  // 8-значне число частоти у 0.01 Гц
localparam [1:0] WAVE_SINE=0, WAVE_SQUARE=1, WAVE_TRI=2, WAVE_PWM=3;
// Мітки типів сигналу для гліф-буфера (glyph indices):
//   "Sin " = 27(S),30(i),28(n),11( )
//   "Su  " = 27(S),22(u),11( ),11( )  (Square)
//   "Tri " = 25(T),29(r),30(i),11( )
//   "pwM " = 13(p),31(w),20(M),11( )

// ── Шрифт 8×16, повний ASCII (0x20-0x7E) у BRAM-ROM ──
// font8x16.mem: 128 рядків × 128-біт (bits[7:0]=row0 верх ... bits[127:120]=row15)
// bit0=ліва колонка. Індекс = ASCII-код символа.
// Scope:  16×16 (2× гориз, 1× верт); DDS: 32×32 (4×/2×)
(* rom_style = "block" *) reg [127:0] font_rom [0:127];
initial $readmemh("font8x16.mem", font_rom);

// ════ PLL (5 виходів) ════
wire sys_clk, sdram_clk, adc_clk, dac_clk, pll_locked;
reg [19:0] por_cnt = 20'h0;
always @(posedge sys_clk) if (!por_cnt[19]) por_cnt <= por_cnt + 1;
wire reset_n = pll_locked | por_cnt[19];

// clk_wiz_0: clk_out1=50 (sys/lcd), clk_out2=100 (sdram),
//            clk_out3=60 (adc), clk_out5=150 (dac).
// clk_out4 (колишній kbd_clk) більше не використовується -
// клавіатуру/енкодери сканує STM32, вся обробка введення у sys_clk.
clk_wiz_0 pll(
  .clk_in1(clk), .clk_out1(sys_clk), .clk_out2(sdram_clk),
  .clk_out3(adc_clk), .clk_out4(), .clk_out5(dac_clk),
  .locked(pll_locked));
wire lcd_clk = sys_clk;

ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  sdram_clk_oddr(.Q(SDRAM_CLK),.C(sdram_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  adc_oddr1(.Q(adc_clk_out1),.C(adc_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  adc_oddr2(.Q(adc_clk_out2),.C(adc_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  dac_oddr(.Q(DAC_CLK),.C(dac_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));

// LED
reg [24:0] led_cnt; reg led_r; reg sdram_error=0;
always @(posedge sys_clk)
  if(led_cnt==25'd24_999_999) begin led_cnt<=0; led_r<=~led_r; end
  else led_cnt<=led_cnt+1;
// LED: scan=швидко блимає, знайдено=повільно блимає, помилка=горить, не знайдено=не горить
assign led_1 = !i2c_scan_done  ? led_cnt[21] :   // сканування: швидко
               (i2c_found_addr!=0) ? led_cnt[24] : // знайдено: повільно
               i2c_dbg_err     ? 1'b1 :            // помилка: горить
                                  1'b0;             // не знайдено: не горить

// ════ КЛАВІАТУРА + ЕНКОДЕРИ ════
// Замість ексклюзивного app_mode - окремі enable-прапорці для кожного режиму.
// Усі режими захоплюються/відображаються одночасно (якщо увімкнені).
reg en_scope, en_dds, en_la;
// -- Scope controls --
reg run_mode; reg [3:0] tdiv_idx; reg [11:0] trig_level; reg trig_edge;
reg [DEPTH_W-1:0] pan; reg single_req, go_menu, ctrl_changed, test_mode;
// -- DDS controls --
reg [1:0]  wave_type;
reg [3:0]  dds_digit [0:DDS_DIGITS-1];
reg [2:0]  dds_cursor;
reg        dds_updated;
reg [13:0] pwm_threshold;              // ШИМ duty (0..16383, 50%=8192)
// -- LA controls --
reg        la_trig_edge;
reg        la_run;
reg        la_single_req;
// -- UART decode controls --
reg [2:0]  uart_ch;
reg [2:0]  uart_baud_idx;
reg        uart_en;

// ── I2C: вхід від STM32 (енкодери + кнопки + матрична клавіатура) ──
// i2c_master працює на sys_clk, тому вся обробка введення теж у sys_clk.
// Окремий kbd-домен більше не потрібен (клавіатуру сканує STM32).
wire [3:0] btn_state_sys, btn_changed_sys;
wire signed [15:0] enc0_pos_sys, enc1_pos_sys, enc2_pos_sys, enc3_pos_sys;
wire [3:0] key_code_sys;
wire       key_pressed_sys;
wire i2c_update_sys;

// Дельти енкодерів і подія натискання - все в sys_clk.
// При кожному завершеному I2C-читанні (i2c_update_sys) рахуємо різницю
// позицій енкодерів, формуємо разовий strobe для застосування змін.
reg signed [15:0] enc0_prev=0, enc1_prev=0, enc2_prev=0, enc3_prev=0;
reg signed [15:0] enc0_d=0, enc1_d=0, enc2_d=0, enc3_d=0;
reg [3:0] btn_prev=0, btn_press=0;
reg       enc_event=0;     // 1 такт sys_clk: є дельта енкодера/кнопки
reg       key_event=0;     // 1 такт sys_clk: нова клавіша
reg [3:0] key_data=0;      // код останньої клавіші

localparam PAN_STEP = 16'd400;
integer ki;
always @(posedge sys_clk or negedge reset_n) begin
  if(!reset_n) begin
    en_scope<=1; en_dds<=1; en_la<=0;
    run_mode<=1; tdiv_idx<=4'd2; trig_level<=12'd2048; trig_edge<=0;
    pan<=0; single_req<=0; go_menu<=0;
    ctrl_changed<=0; test_mode<=0;
    wave_type<=WAVE_SINE; dds_cursor<=3'd7;
    for(ki=0;ki<DDS_DIGITS;ki=ki+1) dds_digit[ki]<=4'd0;
    dds_updated<=0; pwm_threshold<=14'd8192;
    la_trig_edge<=0; la_run<=1; la_single_req<=0;
    uart_ch<=0; uart_baud_idx<=4; uart_en<=0;
    // input-decode регістри
    enc0_prev<=0; enc1_prev<=0; enc2_prev<=0; enc3_prev<=0;
    enc0_d<=0; enc1_d<=0; enc2_d<=0; enc3_d<=0;
    btn_prev<=0; btn_press<=0; enc_event<=0; key_event<=0; key_data<=0;
  end else begin
    // разові strobe-сигнали скидаємо щотакту
    single_req<=0; ctrl_changed<=0;
    dds_updated<=0; la_single_req<=0;
    enc_event<=0; key_event<=0;

    // ── Декодування I2C-кадру (раз на завершене читання) ──
    if(i2c_update_sys) begin
      // дельти позицій енкодерів від попереднього кадру
      enc0_d <= enc0_pos_sys - enc0_prev;
      enc1_d <= enc1_pos_sys - enc1_prev;
      enc2_d <= enc2_pos_sys - enc2_prev;
      enc3_d <= enc3_pos_sys - enc3_prev;
      enc0_prev<=enc0_pos_sys; enc1_prev<=enc1_pos_sys;
      enc2_prev<=enc2_pos_sys; enc3_prev<=enc3_pos_sys;
      // фронти кнопок енкодерів 0→1
      btn_press<= btn_state_sys & ~btn_prev;
      btn_prev <= btn_state_sys;
      enc_event<=1;            // обробити дельти наступного такту
    end
    // клавіша матриці (один strobe key_pressed від i2c_master)
    if(key_pressed_sys) begin
      key_data <= key_code_sys;
      key_event<=1;
    end

    // ── КЛАВІАТУРА (надходить через I2C від STM32) ──
    if(key_event) begin
      case(key_data)
        4'h1: en_scope<=~en_scope;   // toggle показу scope
        4'h2: en_dds  <=~en_dds;     // toggle показу DDS
        4'h3: en_la   <=~en_la;      // toggle показу LA
        4'h4: begin if(pan>PAN_STEP) pan<=pan-PAN_STEP; else pan<=0; ctrl_changed<=1; end // вікно ←
        4'h6: begin if(pan<DEPTH-SCREEN_W-PAN_STEP) pan<=pan+PAN_STEP; ctrl_changed<=1; end // вікно →
        4'h5: run_mode<=~run_mode;                // run/stop
        4'h7: uart_ch<=uart_ch+1;                 // UART канал
        4'h8: uart_en<=~uart_en;                  // UART декодер on/off
        4'h9: begin if(uart_baud_idx<4) uart_baud_idx<=uart_baud_idx+1;
                    else uart_baud_idx<=0; end    // UART baud cycle
        4'h0: test_mode<=~test_mode;              // тестовий сигнал
        4'hA: if(dds_cursor>0)            dds_cursor<=dds_cursor-1; // курсор DDS ←
        4'hB: if(dds_cursor<DDS_DIGITS-1) dds_cursor<=dds_cursor+1; // курсор DDS →
        4'hD: begin single_req<=1; la_single_req<=1; end // single capture (scope+LA)
        4'hE: begin wave_type<=wave_type+1; dds_updated<=1; end // тип сигналу
        4'hF: go_menu<=1;                         // boot menu
        default:;
      endcase
    end

    // ── ЕНКОДЕРИ (обробка дельт на такт після i2c_update) ──
    if(enc_event) begin
      // ENC0 → T/div
      if(enc0_d > 0 && tdiv_idx < TDIV_MAX) tdiv_idx <= tdiv_idx + 1;
      else if(enc0_d < 0 && tdiv_idx > 0)   tdiv_idx <= tdiv_idx - 1;
      // ENC1 → trigger level
      if(enc1_d > 0 && trig_level < 12'd4080) trig_level <= trig_level + 12'd16;
      else if(enc1_d < 0 && trig_level > 12'd16) trig_level <= trig_level - 12'd16;
      // ENC2 → поточна цифра DDS ±1
      if(enc2_d > 0) begin
        if(dds_digit[dds_cursor]<4'd9) dds_digit[dds_cursor]<=dds_digit[dds_cursor]+1;
        else dds_digit[dds_cursor]<=0;
        dds_updated<=1;
      end else if(enc2_d < 0) begin
        if(dds_digit[dds_cursor]>0) dds_digit[dds_cursor]<=dds_digit[dds_cursor]-1;
        else dds_digit[dds_cursor]<=4'd9;
        dds_updated<=1;
      end
      // ENC3 → PWM duty (крок ~256)
      if(enc3_d > 0 && pwm_threshold < 14'd16128) pwm_threshold <= pwm_threshold + 14'd256;
      else if(enc3_d < 0 && pwm_threshold > 14'd256) pwm_threshold <= pwm_threshold - 14'd256;
      dds_updated <= dds_updated | (enc3_d != 0);
      // ── Кнопки енкодерів SW0..3 ──
      if(btn_press[0]) tdiv_idx<=4'd2;                                  // SW0 = reset T/div
      if(btn_press[1]) begin trig_edge<=~trig_edge; la_trig_edge<=~la_trig_edge; end // SW1 = edge
      if(btn_press[2]) begin                                            // SW2 = курсор DDS →
        if(dds_cursor<DDS_DIGITS-1) dds_cursor<=dds_cursor+1; else dds_cursor<=0;
      end
      if(btn_press[3]) begin wave_type<=wave_type+1; dds_updated<=1; end // SW3 = тип сигналу
    end
  end
end
multiboot mb(.clk(sys_clk),.trigger(go_menu),.target_addr(24'h00_0000));

// ── I2C master для контролера STM32 (зі сканером адрес) ──
wire [6:0] i2c_found_addr;
wire       i2c_scan_done;
wire [6:0] i2c_scan_cur;
wire       i2c_dbg_busy, i2c_dbg_err;

i2c_master #(.CLK_HZ(50_000_000), .I2C_HZ(10_000), .SLAVE_ADDR(7'h42), .DO_SCAN(0)) i2c_enc(
    .clk(sys_clk), .reset_n(reset_n),
    .SCL(I2C_SCL), .SDA(I2C_SDA), .IRQ_N(I2C_IRQ_N),
    .btn_state(btn_state_sys), .btn_changed(btn_changed_sys),
    .enc0_pos(enc0_pos_sys), .enc1_pos(enc1_pos_sys),
    .enc2_pos(enc2_pos_sys), .enc3_pos(enc3_pos_sys),
    .key_code(key_code_sys), .key_pressed(key_pressed_sys),
    .update_pulse(i2c_update_sys),
    .i2c_busy(i2c_dbg_busy), .i2c_err(i2c_dbg_err),
    .found_addr(i2c_found_addr), .scan_done(i2c_scan_done),
    .scan_cur_addr(i2c_scan_cur));

// dds_updated тепер у sys_clk, а lcd_clk == sys_clk - той самий домен,
// тому CDC не потрібен, використовуємо сигнал напряму.
wire dds_upd_lcd = dds_updated;

// ════ DDS: phase_inc calculation ════
// freq_chz = dds_digit[0]*10_000_000 + ... + dds_digit[7]  (unit = 0.01 Hz)
wire [31:0] freq_chz =
    {28'd0,dds_digit[0]}*32'd10_000_000 +
    {28'd0,dds_digit[1]}*32'd1_000_000  +
    {28'd0,dds_digit[2]}*32'd100_000    +
    {28'd0,dds_digit[3]}*32'd10_000     +
    {28'd0,dds_digit[4]}*32'd1_000      +
    {28'd0,dds_digit[5]}*32'd100        +
    {28'd0,dds_digit[6]}*32'd10         +
    {28'd0,dds_digit[7]};

reg [31:0] phase_inc;
always @(posedge sys_clk)
    phase_inc <= ({16'd0, freq_chz} * K_CHZ) >> 16;

// CDC: phase_inc + wave_type (sys_clk → dac_clk)
(* ASYNC_REG="TRUE" *) reg [31:0] phase_inc_s1=0, phase_inc_s2=0;
(* ASYNC_REG="TRUE" *) reg [1:0]  wtype_s1=0, wtype_s2=0;
always @(posedge dac_clk) begin
    phase_inc_s1 <= phase_inc; phase_inc_s2 <= phase_inc_s1;
    wtype_s1     <= wave_type; wtype_s2     <= wtype_s1;
end

// ── DDS модуль ──
// CDC pwm_threshold (sys_clk → dac_clk)
(* ASYNC_REG="TRUE" *) reg [13:0] pwm_s1=14'd8192, pwm_s2=14'd8192;
always @(posedge dac_clk) begin pwm_s1<=pwm_threshold; pwm_s2<=pwm_s1; end

wire [13:0] dac_value;
dds dds_inst(
    .clk(dac_clk), .reset_n(reset_n),
    .phase_inc(phase_inc_s2), .wave_type(wtype_s2),
    .pwm_threshold(pwm_s2),
    .dac_out(dac_value));

(* IOB="TRUE" *) reg [13:0] dac_reg=0;
always @(posedge dac_clk or negedge reset_n)
    if(!reset_n) dac_reg<=14'd8192;
    else         dac_reg<=dac_value;
assign DAC_DATA = dac_reg;

// ════ SDRAM ════
wire cap_cmd_en,cap_cmd_we; wire[23:0]cap_cmd_addr; wire[9:0]cap_cmd_len;
wire[15:0]cap_wr_data; wire cap_wr_valid;
wire la_cmd_en,la_cmd_we; wire[23:0]la_cmd_addr; wire[9:0]la_cmd_len;
wire[15:0]la_wr_data; wire la_wr_valid;
reg  rnd_cmd_en,rnd_cmd_we; reg[23:0]rnd_cmd_addr; reg[9:0]rnd_cmd_len;
wire sd_cmd_ready_w,sd_wr_ready_w,sd_rd_valid,sd_ready; wire[15:0]sd_rd_data;
reg  sd_cmd_en,sd_cmd_we; reg[23:0]sd_cmd_addr; reg[9:0]sd_cmd_len;
reg  [15:0]sd_wr_data; reg sd_wr_valid;
reg  capture_active;
wire capture_is_la;   // 1 = активне захоплення = LA (в sdram domain)
always @(*) begin
  if(capture_active && capture_is_la) begin
    sd_cmd_en=la_cmd_en;   sd_cmd_we=la_cmd_we;
    sd_cmd_addr=la_cmd_addr; sd_cmd_len=la_cmd_len;
    sd_wr_data=la_wr_data; sd_wr_valid=la_wr_valid;
  end else if(capture_active) begin
    sd_cmd_en=cap_cmd_en;  sd_cmd_we=cap_cmd_we;
    sd_cmd_addr=cap_cmd_addr; sd_cmd_len=cap_cmd_len;
    sd_wr_data=cap_wr_data; sd_wr_valid=cap_wr_valid;
  end else begin
    sd_cmd_en=rnd_cmd_en;  sd_cmd_we=rnd_cmd_we;
    sd_cmd_addr=rnd_cmd_addr; sd_cmd_len=rnd_cmd_len;
    sd_wr_data=16'd0; sd_wr_valid=1'b0;
  end
end
sdram_ctrl #(.CLK_MHZ(100),.CL(2)) sdram_inst(
  .clk(sdram_clk),.reset_n(reset_n),
  .cmd_en(sd_cmd_en),.cmd_we(sd_cmd_we),
  .cmd_addr(sd_cmd_addr),.cmd_len(sd_cmd_len),.cmd_ready(sd_cmd_ready_w),
  .wr_data(sd_wr_data),.wr_valid(sd_wr_valid),.wr_ready(sd_wr_ready_w),
  .rd_data(sd_rd_data),.rd_valid(sd_rd_valid),.ready(sd_ready),
  .sa(SDRAM_A),.ba(SDRAM_BA),.cke(SDRAM_CKE),.cs_n(SDRAM_CSn),
  .ras_n(SDRAM_RASn),.cas_n(SDRAM_CASn),.we_n(SDRAM_WEn),
  .dqm(SDRAM_DQM),.dq(SDRAM_DQ));

// ── CDC: arm ──
reg arm_sys;
(* ASYNC_REG="TRUE" *) reg arm_s1,arm_s2,arm_s3;
always @(posedge adc_clk) begin arm_s1<=arm_sys; arm_s2<=arm_s1; arm_s3<=arm_s2; end
wire arm_adc = arm_s2^arm_s3;
wire capture_done_adc;
(* ASYNC_REG="TRUE" *) reg cds1,cds2;
always @(posedge sys_clk) begin cds1<=capture_done_adc; cds2<=cds1; end
wire drain_done_sd;
(* ASYNC_REG="TRUE" *) reg dd1,dd2;
always @(posedge sys_clk) begin dd1<=drain_done_sd; dd2<=dd1; end
wire drain_done_sys=dd2;
(* ASYNC_REG="TRUE" *) reg sd_rdy_s1=0,sd_rdy_s2=0;
always @(posedge lcd_clk) begin sd_rdy_s1<=sd_ready; sd_rdy_s2<=sd_rdy_s1; end
wire sd_ready_lcd=sd_rdy_s2;

// ── Test signal / ADC mux ──
(* ASYNC_REG="TRUE" *) reg tm_s1=0,tm_s2=0;
always @(posedge adc_clk) begin tm_s1<=test_mode; tm_s2<=tm_s1; end
reg [11:0] test_cnt=0;
always @(posedge adc_clk) test_cnt<=test_cnt+12'd13;
wire [11:0] adc_in1=tm_s2?test_cnt:adc_ch1;
wire [11:0] adc_in2=tm_s2?(12'hFFF-test_cnt):adc_ch2;

// ── ADC clock decimation sync ──
(* ASYNC_REG="TRUE" *) reg [3:0] tidx_adc1=2,tidx_adc2=2;
always @(posedge adc_clk) begin tidx_adc1<=tdiv_idx; tidx_adc2<=tidx_adc1; end
wire [15:0] decimation=tdiv_decimation(tidx_adc2);

adc_capture #(.CH_BASE(CH_BASE),.DEPTH(DEPTH),.DEPTH_W(DEPTH_W),.BATCH(256)) adc_cap(
  .adc_clk(adc_clk),.reset_n(reset_n),
  .adc_ch1(adc_in1),.adc_ch2(adc_in2),
  .decimation(decimation),.trig_level(trig_level),.trig_edge(trig_edge),
  .pre_trig(PRETRIG[DEPTH_W-1:0]),.arm(arm_adc_scope),.capture_done(capture_done_adc),
  .sdram_clk(sdram_clk),.sdram_cmd_ready(sd_cmd_ready_w),
  .sdram_cmd_en(cap_cmd_en),.sdram_cmd_we(cap_cmd_we),
  .sdram_cmd_addr(cap_cmd_addr),.sdram_cmd_len(cap_cmd_len),
  .sdram_wr_ready(sd_wr_ready_w),.sdram_wr_data(cap_wr_data),
  .sdram_wr_valid(cap_wr_valid),.drain_done(drain_done_sd));

// ── cap_is_la: яке захоплення активне (встановлюється LCD-FSM при arm) ──
reg cap_is_la_sys;
(* ASYNC_REG="TRUE" *) reg cis_a1,cis_a2;
always @(posedge adc_clk) begin cis_a1<=cap_is_la_sys; cis_a2<=cis_a1; end
wire cap_is_la_adc = cis_a2;
wire arm_adc_scope = arm_adc & ~cap_is_la_adc;
wire arm_adc_la    = arm_adc &  cap_is_la_adc;
// до sdram domain (для арбітра)
(* ASYNC_REG="TRUE" *) reg cis_d1,cis_d2;
always @(posedge sdram_clk) begin cis_d1<=cap_is_la_sys; cis_d2<=cis_d1; end
assign capture_is_la = cis_d2;

// ── LA trigger edge sync ──
(* ASYNC_REG="TRUE" *) reg laedge_s1=0,laedge_s2=0;
always @(posedge adc_clk) begin laedge_s1<=la_trig_edge; laedge_s2<=laedge_s1; end

// ── LA drain_done → sys ──
wire la_drain_done_sd;
(* ASYNC_REG="TRUE" *) reg ladd1,ladd2;
always @(posedge sys_clk) begin ladd1<=la_drain_done_sd; ladd2<=ladd1; end
wire la_drain_done_sys=ladd2;

la_capture #(.CH_BASE(CH_BASE_LA),.DEPTH(DEPTH),.DEPTH_W(DEPTH_W),.BATCH(256)) la_cap(
  .la_clk(adc_clk),.reset_n(reset_n),
  .la_data(la_data),.la_trig(la_trig),
  .decimation(decimation),.trig_edge(laedge_s2),
  .arm(arm_adc_la),.capture_done(),
  .sdram_clk(sdram_clk),.sdram_cmd_ready(sd_cmd_ready_w),
  .sdram_cmd_en(la_cmd_en),.sdram_cmd_we(la_cmd_we),
  .sdram_cmd_addr(la_cmd_addr),.sdram_cmd_len(la_cmd_len),
  .sdram_wr_ready(sd_wr_ready_w),.sdram_wr_data(la_wr_data),
  .sdram_wr_valid(la_wr_valid),.drain_done(la_drain_done_sd));

// ════ TRACE BRAM ════
reg [17:0] trace_bram [0:SCREEN_W-1];
reg [9:0] tb_wa; reg [17:0] tb_wd; reg tb_we;
reg [9:0] tb_ra; reg [17:0] tb_rd;
always @(posedge sdram_clk) if(tb_we) trace_bram[tb_wa]<=tb_wd;
always @(posedge lcd_clk)   tb_rd<=trace_bram[tb_ra];

// ════ RENDER (scope, sdram_clk) ════
reg start_render_sys;
(* ASYNC_REG="TRUE" *) reg srs1,srs2,srs3;
always @(posedge sdram_clk) begin srs1<=start_render_sys;srs2<=srs1;srs3<=srs2; end
wire start_render=srs2^srs3;
reg render_done_sd;
(* ASYNC_REG="TRUE" *) reg rds1,rds2;
always @(posedge sys_clk) begin rds1<=render_done_sd; rds2<=rds1; end
wire render_done_sys=rds2;
(* ASYNC_REG="TRUE" *) reg [DEPTH_W-1:0] pan_s1,pan_s2;
always @(posedge sdram_clk) begin pan_s1<=pan; pan_s2<=pan_s1; end

// режим LA, встановлюється FSM до запуску render (sdram domain)
reg render_la_lcd;
(* ASYNC_REG="TRUE" *) reg rla_s1,rla_s2;
always @(posedge sdram_clk) begin rla_s1<=render_la_lcd; rla_s2<=rla_s1; end
wire render_la = rla_s2;

// map_y: динамічний, використовує r_scope_h та r_scope_ye
// CDC layout registers → sdram_clk (змінюються дуже рідко, safe)
(* ASYNC_REG="TRUE" *) reg [8:0] sc_ye_s1, sc_ye_s2, sc_h_s1, sc_h_s2;
always @(posedge sdram_clk) begin
    sc_ye_s1<=r_scope_ye; sc_ye_s2<=sc_ye_s1;
    sc_h_s1 <=r_scope_h;  sc_h_s2 <=sc_h_s1;
end
// map_y: 12-bit sample → y в scope region. p = s * scope_h; y = scope_ye - p[20:12]
function [8:0] map_y; input [11:0] s; input [8:0] sh; input [8:0] sye;
  reg [20:0] p;
  begin p = s * {12'd0, sh}; map_y = sye - p[20:12]; end
endfunction

localparam R_IDLE=3'd0,R_RD=3'd1,R_W1=3'd2,R_W2=3'd3,R_MAP=3'd4,R_WRITE=3'd5,R_DONE=3'd6;
reg [2:0] rstate; reg [9:0] rx; reg [11:0] rs1,rs2; reg [23:0] rbase;
reg [8:0] my1,my2; reg start_pending;
reg [11:0] m_min1,m_max1,m_min2,m_max2,f_min1,f_max1,f_min2,f_max2;

always @(posedge sdram_clk or negedge reset_n) begin
  if(!reset_n) begin
    rstate<=R_IDLE; rx<=0; rnd_cmd_en<=0; rnd_cmd_we<=0;
    rnd_cmd_addr<=0; rnd_cmd_len<=0; tb_we<=0; tb_wa<=0; tb_wd<=0;
    render_done_sd<=0; rs1<=0; rs2<=0; rbase<=0; my1<=0; my2<=0;
    m_min1<=12'hFFF; m_max1<=0; m_min2<=12'hFFF; m_max2<=0;
    f_min1<=0; f_max1<=0; f_min2<=0; f_max2<=0; start_pending<=0;
  end else begin
    rnd_cmd_en<=0; tb_we<=0;
    case(rstate)
      R_IDLE: if(start_pending&&!capture_active) begin
        start_pending<=0; render_done_sd<=0; rx<=0;
        // LA: 1 слово/семпл, область CH_BASE_LA; Scope: 2 слова/семпл
        rbase <= render_la ? (CH_BASE_LA + pan_s2) : (CH_BASE + {pan_s2,1'b0});
        m_min1<=12'hFFF; m_max1<=0; m_min2<=12'hFFF; m_max2<=0;
        rstate<=R_RD;
      end
      R_RD: begin
        rnd_cmd_we<=0;
        rnd_cmd_addr <= render_la ? (rbase+rx) : (rbase+{rx,1'b0});
        rnd_cmd_len  <= render_la ? 10'd1 : 10'd2;
        rnd_cmd_en<=1;
        if(rnd_cmd_en&&sd_cmd_ready_w) begin rnd_cmd_en<=0; rstate<=R_W1; end
      end
      R_W1: if(sd_rd_valid) begin
        rs1<=sd_rd_data[11:0];
        rstate <= render_la ? R_MAP : R_W2;  // LA: 1 слово → одразу map/write
      end
      R_W2: if(sd_rd_valid) begin rs2<=sd_rd_data[11:0]; rstate<=R_MAP; end
      R_MAP: begin
        if(render_la) begin my1<=0; my2<=0; end  // LA не використовує map_y
        else          begin my1<=map_y(rs1, sc_h_s2, sc_ye_s2); my2<=map_y(rs2, sc_h_s2, sc_ye_s2); end
        rstate<=R_WRITE;
      end
      R_WRITE: begin
        tb_wa<=rx;
        // LA: зберігаємо сирий 8-біт семпл; Scope: {y2,y1}
        tb_wd <= render_la ? {10'b0, rs1[7:0]} : {my2,my1};
        tb_we<=1;
        if(!render_la) begin
          if(rs1<m_min1) m_min1<=rs1; if(rs1>m_max1) m_max1<=rs1;
          if(rs2<m_min2) m_min2<=rs2; if(rs2>m_max2) m_max2<=rs2;
        end
        if(rx+1>=SCREEN_W) rstate<=R_DONE;
        else begin rx<=rx+1; rstate<=R_RD; end
      end
      R_DONE: begin
        f_min1<=m_min1; f_max1<=m_max1; f_min2<=m_min2; f_max2<=m_max2;
        render_done_sd<=1; rstate<=R_IDLE;
      end
      default: rstate<=R_IDLE;
    endcase
    if(start_render) start_pending<=1;
  end
end

// ════ LCD ════
reg [15:0] solid_color,x_start,x_end,y_start,y_end;
reg update_screen,text_mode;
reg [7:0] cur_char;       // ASCII-код символа
wire cmd_ndata_done,init_done,start_read_data,cmd_done,cmd_data_done;
wire [7:0] lcd_state; wire [31:0] data_count;

// cur_glyph реєструється з ROM (1-такт latency).
// cur_char встановлюється у M_TSET; glyph готовий до M_TGO/малювання.
reg [127:0] cur_glyph;
always @(posedge lcd_clk) cur_glyph <= font_rom[cur_char[6:0]];

// Scope 16×16 (2× гориз, 1× верт):
//   Регіон 16×16: x=data_count[3:0] (0..15), y=data_count[7:4] (0..15)
//   glyph row = y         → data_count[7:4]  (без масштабування по вертикалі)
//   glyph col = x/2       → data_count[3:1]  (2× горизонт)
wire [7:0] grow_2x = cur_glyph[{data_count[7:4], 3'b000} +: 8];
wire       fbit_2x = grow_2x[data_count[3:1]];

// DDS 32×32 (4× гориз, 2× верт з 8×16 шрифту):
//   Регіон 32×32: x=data_count[4:0] (0..31), y=data_count[9:5] (0..31)
//   glyph row = y/2 → data_count[9:6]  (4 біти, 0..15)
//   glyph col = x/4 → data_count[4:2]  (3 біти, 0..7)
wire [7:0] grow_4x = cur_glyph[{data_count[9:6], 3'b000} +: 8];
wire       fbit_4x = grow_4x[data_count[4:2]];

// DDS → 16×32, Scope → 16×16
wire fbit = (mode_dds && text_mode) ? fbit_4x : fbit_2x;

// Підсвічення курсору DDS: якщо поточний символ = позиція курсора → инверсія кольорів
reg cursor_char;   // 1 = цей символ під DDS-курсором
wire [15:0] text_fg = cursor_char ? COL_BG   : COL_TEXT;
wire [15:0] text_bg = cursor_char ? COL_CURS : COL_BG;
wire [15:0] pixel_out = text_mode ? (fbit?text_fg:text_bg) : solid_color;

lcd lcd_inst(
  .clk(clk),.reset_n(reset_n),.fill_color(pixel_out),
  .x_start(x_start),.x_end(x_end),.y_start(y_start),.y_end(y_end),
  .update_screen(update_screen),
  .LCD_DATA(LCD_DATA),.LCD_WR(LCD_WR),.LCD_RS(LCD_RS),
  .LCD_CS(LCD_CS),.LCD_RESET(LCD_RESET),.LCD_BL(LCD_BL),.LCD_RDX(LCD_RDX),
  .start_read_data(start_read_data),.cmd_done(cmd_done),
  .cmd_data_done(cmd_data_done),.cmd_ndata_done(cmd_ndata_done),
  .lcd_clk(lcd_clk),.lcd_state(lcd_state),
  .init_done(init_done),.lcd_data_count(data_count));

// ════ Vpp → BCD ════
wire [11:0] vpp1=f_max1-f_min1, vpp2=f_max2-f_min2;
reg bc_start; reg [26:0] bc_in; wire [31:0] bc_out; wire bc_done,bc_busy;
bin2bcd #(.IN_W(27),.DIGITS(8)) bc(
  .clk(lcd_clk),.reset_n(reset_n),.start(bc_start),
  .bin(bc_in),.bcd(bc_out),.done(bc_done),.busy(bc_busy));
reg [15:0] dvpp1,dvpp2;
reg [7:0] text_buf [0:NCH-1];   // ASCII-коди символів рядка

// ── Syncs до lcd_clk ──
(* ASYNC_REG="TRUE" *) reg [3:0] tidx_lcd1=2,tidx_lcd2=2;
always @(posedge lcd_clk) begin tidx_lcd1<=tdiv_idx; tidx_lcd2<=tidx_lcd1; end

(* ASYNC_REG="TRUE" *) reg [1:0] wt_lcd1=0,wt_lcd2=0;
always @(posedge lcd_clk) begin wt_lcd1<=wave_type; wt_lcd2<=wt_lcd1; end

(* ASYNC_REG="TRUE" *) reg [31:0] finc_lcd1=0,finc_lcd2=0;
always @(posedge lcd_clk) begin finc_lcd1<=freq_chz; finc_lcd2<=finc_lcd1; end

(* ASYNC_REG="TRUE" *) reg [2:0] dcur_lcd1=0,dcur_lcd2=0;
always @(posedge lcd_clk) begin dcur_lcd1<=dds_cursor; dcur_lcd2<=dcur_lcd1; end

(* ASYNC_REG="TRUE" *) reg [3:0] ddig_lcd1[0:7],ddig_lcd2[0:7];
integer si;
always @(posedge lcd_clk) begin
  for(si=0;si<8;si=si+1) begin
    ddig_lcd1[si]<=dds_digit[si]; ddig_lcd2[si]<=ddig_lcd1[si];
  end
end

(* ASYNC_REG="TRUE" *) reg en_s1=0,en_s2=0,en_d1=0,en_d2=0,en_l1=0,en_l2=0;
always @(posedge lcd_clk) begin
    en_s1<=en_scope; en_s2<=en_s1;
    en_d1<=en_dds;   en_d2<=en_d1;
    en_l1<=en_la;    en_l2<=en_l1;
end
wire en_scope_lcd = en_s2;
wire en_dds_lcd   = en_d2;
wire en_la_lcd    = en_l2;

// Контекст малювання (для вибору 4× гліфів у DDS і інших mode-залежностей)
reg [1:0] draw_ctx;   // 0=scope, 1=DDS, 2=LA, 3=header/footer
reg [1:0] disp_step;  // лічильник dispatcher: 0→scope, 1→DDS, 2→LA, 3→wrap
wire mode_scope = (draw_ctx==2'd0);
wire mode_dds   = (draw_ctx==2'd1);
wire mode_la    = (draw_ctx==2'd2);
wire mode_hdr   = (draw_ctx==2'd3);

// LA: run + single + trig_edge у lcd domain
(* ASYNC_REG="TRUE" *) reg lar1,lar2;
always @(posedge lcd_clk) begin lar1<=la_run; lar2<=lar1; end
wire la_run_lcd=lar2;
(* ASYNC_REG="TRUE" *) reg las1,las2,las3;
always @(posedge lcd_clk) begin las1<=la_single_req;las2<=las1;las3<=las2; end
wire la_single_lcd=las2&~las3;
(* ASYNC_REG="TRUE" *) reg lae1,lae2;
always @(posedge lcd_clk) begin lae1<=la_trig_edge; lae2<=lae1; end
wire la_edge_lcd=lae2;

// UART decode → lcd_clk
(* ASYNC_REG="TRUE" *) reg [2:0] uch1=0,uch2=0;
always @(posedge lcd_clk) begin uch1<=uart_ch; uch2<=uch1; end
wire [2:0] uart_ch_lcd=uch2;
(* ASYNC_REG="TRUE" *) reg [2:0] ubi1=0,ubi2=0;
always @(posedge lcd_clk) begin ubi1<=uart_baud_idx; ubi2<=ubi1; end
wire [2:0] uart_baud_lcd=ubi2;
(* ASYNC_REG="TRUE" *) reg uen1=0,uen2=0;
always @(posedge lcd_clk) begin uen1<=uart_en; uen2<=uen1; end
wire uart_en_lcd=uen2;

// UART decode: масиви результатів і робочі регістри
localparam UART_MAX = 25;
reg [7:0]  uart_data [0:UART_MAX-1];  // декодовані байти
reg [9:0]  uart_xpos [0:UART_MAX-1];  // x-позиція старт-біта
reg [4:0]  uart_cnt;                   // кількість знайдених байтів
reg [9:0]  uart_scan_x;               // поточна позиція сканування
reg [3:0]  uart_bit_cnt;              // лічильник бітів (0..7)
reg [7:0]  uart_accum;               // акумулятор байта
reg        uart_prev_bit;             // попередній стан лінії
reg [9:0]  uart_start_x;             // x-позиція старт-біта (для зберігання)
reg [4:0]  uart_di;                  // індекс відображення

// UART: baud_period і baud_half для поточних налаштувань
wire [15:0] baud_p  = baud_period(uart_baud_lcd, tidx_lcd2);
wire [15:0] baud_h  = {1'b0, baud_p[15:1]};  // половина періоду
wire [15:0] scan_adv_half = {6'b0, uart_scan_x} + baud_h;
wire [15:0] scan_adv_full = {6'b0, uart_scan_x} + baud_p;
wire uart_ok = (baud_p >= 16'd4);  // достатня роздільна здатність

(* ASYNC_REG="TRUE" *) reg cc1,cc2,cc3;
always @(posedge lcd_clk) begin cc1<=ctrl_changed;cc2<=cc1;cc3<=cc2; end
wire ctrl_changed_lcd=cc2&~cc3;
(* ASYNC_REG="TRUE" *) reg sgg1,sgg2,sgg3;
always @(posedge lcd_clk) begin sgg1<=single_req;sgg2<=sgg1;sgg3<=sgg2; end
wire single_lcd=sgg2&~sgg3;
(* ASYNC_REG="TRUE" *) reg rm1,rm2;
always @(posedge lcd_clk) begin rm1<=run_mode;rm2<=rm1; end
wire run_lcd=rm2;

// Комбінаційні допоміжні сигнали для FSM
wire [47:0] tdg = tdiv_glyphs(tidx_lcd2);  // T/div мітка (6 ASCII)
wire [31:0] wl  = wave_label(wt_lcd2);     // тип DDS-сигналу (4 ASCII)

// ════ MAIN FSM ════
localparam
  M_INIT       = 6'd0,  M_ARM        = 6'd1,  M_WAIT_CAP   = 6'd2,
  M_RENDER     = 6'd3,  M_WAIT_RND   = 6'd4,  M_DRAW_SET   = 6'd5,
  M_DRAW_LAT   = 6'd6,  M_ERASE      = 6'd7,  M_ERASE_W    = 6'd8,
  M_CH1        = 6'd9,  M_CH1_W      = 6'd10, M_CH2        = 6'd11,
  M_CH2_W      = 6'd12, M_NEXTCOL    = 6'd13, M_BCD1       = 6'd14,
  M_BCD1W      = 6'd15, M_BCD2       = 6'd16, M_BCD2W      = 6'd17,
  M_BUILD      = 6'd18, M_TSET       = 6'd19, M_TGO        = 6'd20,
  M_TW         = 6'd21, M_CHECK      = 6'd22, M_WAIT_PAN   = 6'd23,
  M_ARM_LO     = 6'd24, M_RENDER_LO  = 6'd25,
  M_FILL_BG    = 6'd30, M_FILL_BG_W  = 6'd31,
  M_VGRID_DRAW = 6'd32, M_VGRID_W    = 6'd33,
  M_HGRID_DRAW = 6'd34, M_HGRID_W    = 6'd35,
  M_WAIT_SD    = 6'd36,
  // ── DDS-специфічні стани ──
  M_DDS_BLD    = 7'd40, // побудова DDS text_buf
  M_DDS_LOOP   = 7'd41, // idle: чекаємо оновлення
  M_DDS_COLOR  = 7'd42, // кольорова смуга типу сигналу
  M_DDS_COL_W  = 7'd43,
  // ── LA-специфічні стани ──
  M_LA_ARM     = 7'd44, M_LA_ARM_LO  = 7'd45, M_LA_WAIT    = 7'd46,
  M_LA_RENDER  = 7'd47, M_LA_RND_LO  = 7'd48, M_LA_WRND    = 7'd49,
  M_LA_DSET    = 7'd50, M_LA_DLAT    = 7'd51, M_LA_ERASE   = 7'd52,
  M_LA_ERASE_W = 7'd53, M_LA_CH      = 7'd54, M_LA_CH_W    = 7'd55,
  M_LA_NEXT    = 7'd56, M_LA_LOOP    = 7'd57, M_LA_WAIT_PAN= 7'd58,
  // ── UART decode стани ──
  M_UART_INIT   = 7'd64,  // ініціалізація сканування
  M_UART_SC0    = 7'd65,  // встановити tb_ra=scan_x
  M_UART_SC1    = 7'd66,  // читати tb_rd, перевірити фронт
  M_UART_BT0    = 7'd67,  // встановити tb_ra для біта
  M_UART_BT1    = 7'd68,  // зчитати біт, накопичити
  M_UART_SP0    = 7'd69,  // tb_ra для стоп-біта
  M_UART_SP1    = 7'd70,  // перевірити стоп, зберегти
  M_UART_DW_INI = 7'd71,  // ініціалізація відображення
  M_UART_DW_HI  = 7'd72,  // малювати старший ніббл
  M_UART_DW_HIW = 7'd73,  // чекати
  M_UART_DW_LO  = 7'd74,  // малювати молодший ніббл
  M_UART_DW_LOW = 7'd75,  // чекати
  M_UART_DW_NXT = 7'd76,  // наступний байт
  // ── Dispatcher (одночасні режими) ──
  M_DISPATCH    = 7'd77;  // вибір наступного увімкненого режиму

// ── UART: семплів/біт ──────────────────────────────────────
// baud_period(baud_idx[2:0], tdiv_idx[3:0]) = 0 якщо недостатньо роздільної здатності
function [15:0] baud_period; input [2:0] bi; input [3:0] di;
  case({bi,di})
    7'd 0: baud_period=16'd1562; 7'd 1: baud_period=16'd781;
    7'd 2: baud_period=16'd417;  7'd 3: baud_period=16'd169;
    7'd 4: baud_period=16'd83;   7'd 5: baud_period=16'd42;
    7'd 6: baud_period=16'd17;   7'd 7: baud_period=16'd8;
    7'd 8: baud_period=16'd4;    7'd 9: baud_period=16'd0;
    7'd10: baud_period=16'd781;  7'd11: baud_period=16'd391;
    7'd12: baud_period=16'd208;  7'd13: baud_period=16'd84;
    7'd14: baud_period=16'd42;   7'd15: baud_period=16'd21;
    7'd16: baud_period=16'd8;    7'd17: baud_period=16'd4;
    7'd18: baud_period=16'd0;    7'd19: baud_period=16'd0;
    7'd20: baud_period=16'd391;  7'd21: baud_period=16'd195;
    7'd22: baud_period=16'd104;  7'd23: baud_period=16'd42;
    7'd24: baud_period=16'd21;   7'd25: baud_period=16'd10;
    7'd26: baud_period=16'd4;    7'd27: baud_period=16'd0;
    7'd28: baud_period=16'd0;    7'd29: baud_period=16'd0;
    7'd30: baud_period=16'd260;  7'd31: baud_period=16'd130;
    7'd32: baud_period=16'd69;   7'd33: baud_period=16'd28;
    7'd34: baud_period=16'd14;   7'd35: baud_period=16'd7;
    7'd36: baud_period=16'd0;    7'd37: baud_period=16'd0;
    7'd38: baud_period=16'd0;    7'd39: baud_period=16'd0;
    7'd40: baud_period=16'd130;  7'd41: baud_period=16'd65;
    7'd42: baud_period=16'd35;   7'd43: baud_period=16'd14;
    7'd44: baud_period=16'd7;    default: baud_period=16'd0;
  endcase
endfunction

// 4-бітний ніббл → ASCII-hex символ
function [7:0] nibble_to_hex; input [3:0] n;
  nibble_to_hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n); // '0'-'9' або 'A'-'F'
endfunction

reg [6:0] mstate;
reg [9:0] dx; reg [8:0] gy;
reg [8:0] py1,py2,cy1,cy2;
reg capture_active_lcd; reg [5:0] tc;
reg [27:0] wait_sd_cnt;
reg [24:0] dds_loop_cnt;      // таймер оновлення DDS (~0.67с @ 50МГц)
reg [7:0]  la_cur, la_prev;   // поточний/попередній 8-біт семпл (LA draw)
reg [2:0]  la_ch;             // лічильник каналів 0..7
localparam SD_TIMEOUT = 28'd150_000_000;

(* ASYNC_REG="TRUE" *) reg cas1,cas2;
always @(posedge sdram_clk) begin cas1<=capture_active_lcd; cas2<=cas1; end
always @(*) capture_active=cas2;

wire [8:0] s1_lo=(cy1<py1)?cy1:py1, s1_hi=(cy1<py1)?py1:cy1;
wire [8:0] s2_lo=(cy2<py2)?cy2:py2, s2_hi=(cy2<py2)?py2:cy2;

// ── LA: рівні каналів у LA-регіоні (динамічні) ──
// канал ch: y = r_la_y0 + ch*r_la_ch_h + offset
wire [8:0] la_ch_base = r_la_y0 + la_ch * r_la_ch_h;
wire [8:0] la_cy = la_cur[la_ch]  ? (la_ch_base + 9'd3) : (la_ch_base + r_la_ch_h - 9'd5);
wire [8:0] la_py = la_prev[la_ch] ? (la_ch_base + 9'd3) : (la_ch_base + r_la_ch_h - 9'd5);
wire [8:0] la_lo = (la_cy<la_py)?la_cy:la_py;
wire [8:0] la_hi = (la_cy<la_py)?la_py:la_cy;

// DDS колір фону (за типом сигналу)
wire [15:0] dds_mode_color =
    wt_lcd2==WAVE_SINE   ? 16'h07FF :  // блакитний
    wt_lcd2==WAVE_SQUARE ? 16'hFFE0 :  // жовтий
    wt_lcd2==WAVE_TRI    ? 16'hF81F :  // пурпуровий
                           16'hFD20;   // оранжевий (PWM)

// Мітка типу сигналу: 4 ASCII-символи
function [31:0] wave_label; input [1:0] wt;
  case(wt)
    WAVE_SINE:   wave_label={"Sine"};
    WAVE_SQUARE: wave_label={"Sqr "};
    WAVE_TRI:    wave_label={"Tri "};
    WAVE_PWM:    wave_label={"Pwm "};
    default:     wave_label={"    "};
  endcase
endfunction

integer ti;
always @(posedge lcd_clk or negedge reset_n) begin
  if(!reset_n) begin
    mstate<=M_INIT; dx<=0; gy<=0; wait_sd_cnt<=0; dds_loop_cnt<=0;
    py1<=240; py2<=240; cy1<=240; cy2<=240;
    update_screen<=0; solid_color<=COL_BG; text_mode<=0; cur_char<=" ";
    x_start<=0; x_end<=0; y_start<=0; y_end<=0;
    arm_sys<=0; start_render_sys<=0; capture_active_lcd<=0;
    tb_ra<=0; bc_start<=0; bc_in<=0;
    dvpp1<=0; dvpp2<=0; tc<=0; sdram_error<=0; cursor_char<=0;
    cap_is_la_sys<=0; la_ch<=0; la_cur<=0; la_prev<=0;
    uart_cnt<=0; uart_scan_x<=0; uart_bit_cnt<=0; uart_accum<=0;
    uart_prev_bit<=1; uart_start_x<=0; uart_di<=0;
    draw_ctx<=2'd0; disp_step<=2'd0; render_la_lcd<=0;
    // layout defaults (all modes on)
    r_dds_y0<=9'd16; r_scope_y0<=9'd48; r_scope_ye<=9'd255; r_scope_h<=9'd208;
    r_la_y0<=9'd256; r_la_ye<=9'd447; r_la_ch_h<=9'd24;
    r_uart_y0<=9'd448;
    r_hgrid_y0<=9'd100; r_hgrid_y1<=9'd152; r_hgrid_y2<=9'd204;
    for(ti=0;ti<NCH;ti=ti+1) text_buf[ti]<=" ";
  end else begin
    update_screen<=0; bc_start<=0;
    // cursor_char НЕ скидається тут - утримується між M_TSET і кінцем малювання символу
    case(mstate)
      M_INIT: if(init_done) mstate<=M_FILL_BG;

      // ── Початковий фон (одноразово, темно-сірий по всьому екрану) ──
      M_FILL_BG: begin
        text_mode<=0;
        solid_color<= COL_OFF;
        x_start<=0; x_end<=SCREEN_W-1; y_start<=0; y_end<=SCREEN_H-1;
        update_screen<=1; mstate<=M_FILL_BG_W;
      end
      M_FILL_BG_W: if(cmd_ndata_done) begin
        wait_sd_cnt<=0; mstate<=M_WAIT_SD;   // далі - чекати SDRAM, потім dispatcher
      end

      // ── Вертикальна сітка (scope) ──
      M_VGRID_DRAW: begin
        solid_color<=COL_GRID; x_start<=dx; x_end<=dx;
        y_start<=r_scope_y0; y_end<=r_scope_ye;
        update_screen<=1; mstate<=M_VGRID_W;
      end
      M_VGRID_W: if(cmd_ndata_done) begin
        if(dx>=720) begin gy<=r_hgrid_y0; mstate<=M_HGRID_DRAW; end
        else        begin dx<=dx+80; mstate<=M_VGRID_DRAW; end
      end

      // ── Горизонтальна сітка (scope) ──
      M_HGRID_DRAW: begin
        solid_color<=COL_GRID; x_start<=0; x_end<=SCREEN_W-1;
        y_start<=gy; y_end<=gy; update_screen<=1; mstate<=M_HGRID_W;
      end
      M_HGRID_W: if(cmd_ndata_done) begin
        if     (gy>=r_hgrid_y2) begin wait_sd_cnt<=0; mstate<=M_WAIT_SD; end
        else if(gy>=r_hgrid_y1) begin gy<=r_hgrid_y2; mstate<=M_HGRID_DRAW; end
        else                     begin gy<=r_hgrid_y1; mstate<=M_HGRID_DRAW; end
      end

      // ── Очікування SDRAM ──
      M_WAIT_SD: begin
        if(sd_ready_lcd) begin
          sdram_error<=0;
          mstate <= M_DISPATCH;
        end else begin
          if(wait_sd_cnt<SD_TIMEOUT) wait_sd_cnt<=wait_sd_cnt+1;
          else sdram_error<=1;
        end
      end

      // ── DISPATCHER: обчислює layout і вибирає наступний режим ──
      M_DISPATCH: begin
        // ── Обчислення розмітки при початку нового циклу ──
        if(disp_step==2'd0) begin
          // Контент: y=16..463 (448px). DDS=32px, UART=16px (якщо LA).
          // Решта - між scope і LA.
          case({en_scope_lcd, en_dds_lcd, en_la_lcd})
            3'b111: begin // Scope+DDS+LA
              r_dds_y0<=9'd16;
              r_scope_y0<=9'd48;  r_scope_ye<=9'd255; r_scope_h<=9'd208;
              r_la_y0<=9'd256;    r_la_ye<=9'd447;    r_la_ch_h<=9'd24;
              r_uart_y0<=9'd448;
            end
            3'b110: begin // Scope+DDS
              r_dds_y0<=9'd16;
              r_scope_y0<=9'd48;  r_scope_ye<=9'd463; r_scope_h<=9'd416;
              r_la_y0<=0; r_la_ye<=0; r_la_ch_h<=9'd24; r_uart_y0<=0;
            end
            3'b101: begin // Scope+LA
              r_dds_y0<=0;
              r_scope_y0<=9'd16;  r_scope_ye<=9'd231; r_scope_h<=9'd216;
              r_la_y0<=9'd232;    r_la_ye<=9'd447;    r_la_ch_h<=9'd27;
              r_uart_y0<=9'd448;
            end
            3'b100: begin // Scope only
              r_dds_y0<=0;
              r_scope_y0<=9'd16;  r_scope_ye<=9'd463; r_scope_h<=9'd448;
              r_la_y0<=0; r_la_ye<=0; r_la_ch_h<=9'd24; r_uart_y0<=0;
            end
            3'b011: begin // DDS+LA
              r_dds_y0<=9'd16;
              r_scope_y0<=0; r_scope_ye<=0; r_scope_h<=9'd208;
              r_la_y0<=9'd48;     r_la_ye<=9'd447;    r_la_ch_h<=9'd50;
              r_uart_y0<=9'd448;
            end
            3'b010: begin // DDS only
              r_dds_y0<=9'd16;
              r_scope_y0<=0; r_scope_ye<=0; r_scope_h<=9'd208;
              r_la_y0<=0; r_la_ye<=0; r_la_ch_h<=9'd24; r_uart_y0<=0;
            end
            3'b001: begin // LA only
              r_dds_y0<=0;
              r_scope_y0<=0; r_scope_ye<=0; r_scope_h<=9'd208;
              r_la_y0<=9'd16;     r_la_ye<=9'd447;    r_la_ch_h<=9'd54;
              r_uart_y0<=9'd448;
            end
            default: begin // none
              r_dds_y0<=0; r_scope_y0<=0; r_scope_ye<=0; r_scope_h<=9'd208;
              r_la_y0<=0; r_la_ye<=0; r_la_ch_h<=9'd24; r_uart_y0<=0;
            end
          endcase
          // HGRID (обчислюються наступний такт коли scope_y0/h стабілізуються)
          r_hgrid_y0 <= r_scope_y0 + (r_scope_h >> 2);
          r_hgrid_y1 <= r_scope_y0 + (r_scope_h >> 1);
          r_hgrid_y2 <= r_scope_y0 + r_scope_h - (r_scope_h >> 2);
        end

        // ── Диспетчеризація режимів ──
        if(disp_step==2'd0 && en_scope_lcd) begin
          disp_step<=2'd1; draw_ctx<=2'd0; render_la_lcd<=0;
          mstate<=M_ARM;
        end
        else if(disp_step<=2'd1 && en_dds_lcd) begin
          disp_step<=2'd2; draw_ctx<=2'd1;
          mstate<=M_DDS_BLD;
        end
        else if(disp_step<=2'd2 && en_la_lcd) begin
          disp_step<=2'd3; draw_ctx<=2'd2; render_la_lcd<=1;
          mstate<=M_LA_ARM;
        end
        else begin
          disp_step<=2'd0;
        end
      end

      // ═══ SCOPE FSM ═══
      M_ARM:     begin cap_is_la_sys<=0; capture_active_lcd<=1; arm_sys<=~arm_sys; mstate<=M_ARM_LO; end
      M_ARM_LO:  if(!drain_done_sys) mstate<=M_WAIT_CAP;
      M_WAIT_CAP:if(drain_done_sys) begin capture_active_lcd<=0; mstate<=M_RENDER; end
      M_RENDER:  begin start_render_sys<=~start_render_sys; mstate<=M_RENDER_LO; end
      M_RENDER_LO:if(!render_done_sys) mstate<=M_WAIT_RND;
      M_WAIT_RND:if(render_done_sys) begin dx<=0; mstate<=M_DRAW_SET; end
      M_DRAW_SET:begin tb_ra<=dx; mstate<=M_DRAW_LAT; end
      M_DRAW_LAT:begin
        cy1<=tb_rd[8:0]; cy2<=tb_rd[17:9];
        if(dx==0) begin py1<=tb_rd[8:0]; py2<=tb_rd[17:9]; end
        mstate<=M_ERASE;
      end
      M_ERASE: begin
        text_mode<=0;
        solid_color<=(dx[6:0]==7'd0)?COL_GRID:COL_BG;
        x_start<=dx; x_end<=dx; y_start<=r_scope_y0; y_end<=r_scope_ye;
        update_screen<=1; mstate<=M_ERASE_W;
      end
      M_ERASE_W: if(cmd_ndata_done) mstate<=M_CH1;
      M_CH1: begin
        solid_color<=COL_CH1; x_start<=dx; x_end<=dx;
        y_start<={7'd0,s1_lo}; y_end<={7'd0,s1_hi};
        update_screen<=1; mstate<=M_CH1_W;
      end
      M_CH1_W: if(cmd_ndata_done) mstate<=M_CH2;
      M_CH2: begin
        solid_color<=COL_CH2; x_start<=dx; x_end<=dx;
        y_start<={7'd0,s2_lo}; y_end<={7'd0,s2_hi};
        update_screen<=1; mstate<=M_CH2_W;
      end
      M_CH2_W:if(cmd_ndata_done) mstate<=M_NEXTCOL;
      M_NEXTCOL: begin
        py1<=cy1; py2<=cy2;
        if(dx+1>=SCREEN_W) mstate<=M_BCD1;
        else begin dx<=dx+1; mstate<=M_DRAW_SET; end
      end
      M_BCD1:  begin bc_in<={15'd0,vpp1}; bc_start<=1; mstate<=M_BCD1W; end
      M_BCD1W: if(bc_done) begin dvpp1<=bc_out[15:0]; mstate<=M_BCD2; end
      M_BCD2:  begin bc_in<={15'd0,vpp2}; bc_start<=1; mstate<=M_BCD2W; end
      M_BCD2W: if(bc_done) begin dvpp2<=bc_out[15:0]; mstate<=M_BUILD; end

      // ── Текстовий рядок (SCOPE) ──
      M_BUILD: begin
        // "CH1 Vpp:VVVV  CH2 Vpp:VVVV  T:NNNus     "
        text_buf[0]<="C"; text_buf[1]<="H"; text_buf[2]<="1"; text_buf[3]<=" ";
        text_buf[4]<="V"; text_buf[5]<="p"; text_buf[6]<="p"; text_buf[7]<=":";
        text_buf[8] <=8'h30+dvpp1[15:12]; text_buf[9] <=8'h30+dvpp1[11:8];
        text_buf[10]<=8'h30+dvpp1[7:4];   text_buf[11]<=8'h30+dvpp1[3:0];
        text_buf[12]<=" "; text_buf[13]<=" ";
        text_buf[14]<="C"; text_buf[15]<="H"; text_buf[16]<="2"; text_buf[17]<=" ";
        text_buf[18]<="V"; text_buf[19]<="p"; text_buf[20]<="p"; text_buf[21]<=":";
        text_buf[22]<=8'h30+dvpp2[15:12]; text_buf[23]<=8'h30+dvpp2[11:8];
        text_buf[24]<=8'h30+dvpp2[7:4];   text_buf[25]<=8'h30+dvpp2[3:0];
        text_buf[26]<=" "; text_buf[27]<=" ";
        text_buf[28]<="T"; text_buf[29]<=":";
        text_buf[30]<=tdg[47:40]; text_buf[31]<=tdg[39:32];
        text_buf[32]<=tdg[31:24]; text_buf[33]<=tdg[23:16];
        text_buf[34]<=tdg[15:8];  text_buf[35]<=tdg[7:0];
        text_buf[36]<="I"; text_buf[37]<=":";
        // I2C знайдена адреса: "I:42" або "I:--" або "I:.." (сканування)
        if (!i2c_scan_done) begin
          text_buf[38]<="."; text_buf[39]<=".";
        end else if (i2c_found_addr==0) begin
          text_buf[38]<="-"; text_buf[39]<="-";
        end else begin
          text_buf[38]<=nibble_to_hex(i2c_found_addr[6:4]);
          text_buf[39]<=nibble_to_hex({1'b0, i2c_found_addr[3:0]});
        end
        tc<=0; mstate<=M_TSET;
      end

      // ── Відображення тексту (SCOPE/LA: 16×16, 40 симв; DDS: 32×32, 18 симв) ──
      M_TSET: begin
        text_mode<=1; cur_char<=text_buf[tc[5:0]];
        // Підсвічення курсора лише в DDS (цифри chars 8-15)
        cursor_char <= mode_dds && (tc >= 8) && (tc < 16)
                       && ((tc - 6'd8) == {3'd0, dcur_lcd2});
        if(mode_dds) begin
          x_start <= {tc, 5'b0}; x_end <= {tc, 5'b0} + 16'd31;  // 32 пікс
          y_start <= r_dds_y0;     y_end <= r_dds_y0 + 9'd31;
        end else begin
          x_start <= {tc, 4'b0}; x_end <= {tc, 4'b0} + CHAR_PX - 1; // 16 пікс
          y_start <= 0; y_end <= CHAR_PX - 1;
        end
        mstate<=M_TGO;
      end
      M_TGO: begin update_screen<=1; mstate<=M_TW; end
      M_TW: if(cmd_ndata_done) begin
        if(mode_dds) begin
          if(tc+1 >= 18) begin text_mode<=0; mstate<=M_CHECK; end
          else begin tc<=tc+1; mstate<=M_TSET; end
        end else begin
          if(tc+1>=NCH) begin text_mode<=0; mstate<=M_CHECK; end
          else begin tc<=tc+1; mstate<=M_TSET; end
        end
      end

      M_CHECK: begin
        mstate <= M_DISPATCH;        // dispatcher вибере наступний увімкнений режим
      end
      M_WAIT_PAN: begin
        // legacy state, dispatcher вирішує що далі
        mstate <= M_DISPATCH;
      end

      // ═══ DDS FSM ═══
      M_DDS_BLD: begin
        // "DDS Sine 00000000Hz"  (18 символів × 32px)
        text_buf[0]<="D"; text_buf[1]<="D"; text_buf[2]<="S"; text_buf[3]<=" ";
        text_buf[4]<=wl[31:24]; text_buf[5]<=wl[23:16];
        text_buf[6]<=wl[15:8];  text_buf[7]<=wl[7:0];
        text_buf[8] <=8'h30+ddig_lcd2[0]; text_buf[9] <=8'h30+ddig_lcd2[1];
        text_buf[10]<=8'h30+ddig_lcd2[2]; text_buf[11]<=8'h30+ddig_lcd2[3];
        text_buf[12]<=8'h30+ddig_lcd2[4]; text_buf[13]<=8'h30+ddig_lcd2[5];
        text_buf[14]<=8'h30+ddig_lcd2[6]; text_buf[15]<=8'h30+ddig_lcd2[7];
        text_buf[16]<="H"; text_buf[17]<="z";
        for(ti=18;ti<NCH;ti=ti+1) text_buf[ti]<=" ";
        tc<=0; mstate<=M_TSET;
      end

      // DDS пост-малювання → dispatcher
      M_DDS_LOOP: begin
        mstate <= M_DISPATCH;
      end

      // ═══ LOGIC ANALYZER FSM ═══
      // Захоплення: arm la_capture → чекати drain → рендер → малювати 8 каналів
      M_LA_ARM: begin
        cap_is_la_sys<=1; capture_active_lcd<=1;
        arm_sys<=~arm_sys; mstate<=M_LA_ARM_LO;
      end
      M_LA_ARM_LO:  if(!la_drain_done_sys) mstate<=M_LA_WAIT;
      M_LA_WAIT:    if(la_drain_done_sys) begin capture_active_lcd<=0; mstate<=M_LA_RENDER; end
      M_LA_RENDER:  begin start_render_sys<=~start_render_sys; mstate<=M_LA_RND_LO; end
      M_LA_RND_LO:  if(!render_done_sys) mstate<=M_LA_WRND;
      M_LA_WRND: if(render_done_sys) begin
        dx<=0;
        // якщо UART декодер увімкнений - спочатку декодуємо, потім малюємо
        mstate <= (uart_en_lcd && uart_ok) ? M_UART_INIT : M_LA_DSET;
      end

      // ═══ UART DECODE FSM ═══════════════════════════════════════
      // Алгоритм: сканувати trace_bram[0..799], шукати старт-біт (падаючий фронт
      // на uart_ch_lcd), зчитати 8 бітів через baud_p семплів, перевірити стоп-біт.
      // Результат: uart_data[i] + uart_xpos[i], кількість = uart_cnt.
      M_UART_INIT: begin
        uart_scan_x<=0; uart_cnt<=0; uart_prev_bit<=1;
        uart_bit_cnt<=0; uart_accum<=0;
        mstate<=M_UART_SC0;
      end
      // ── Сканування: шукаємо падаючий фронт (старт-біт) ──
      M_UART_SC0: begin tb_ra<=uart_scan_x; mstate<=M_UART_SC1; end
      M_UART_SC1: begin
        if (uart_prev_bit==1 && tb_rd[uart_ch_lcd]==1'b0) begin
          // Знайшли старт-біт! Зберігаємо позицію, стрибаємо до центру
          uart_start_x <= uart_scan_x;
          if (scan_adv_half[15:10] != 0) begin // scan_x+baud_h >= 1024 (>799)
            mstate <= M_UART_DW_INI; // виходимо за межі - кінець
          end else begin
            uart_scan_x <= scan_adv_half[9:0];
            uart_bit_cnt <= 0; uart_accum <= 0;
            mstate <= M_UART_BT0;
          end
        end else begin
          uart_prev_bit <= tb_rd[uart_ch_lcd];
          if (uart_scan_x >= 10'd799) mstate<=M_UART_DW_INI;
          else begin uart_scan_x<=uart_scan_x+1; mstate<=M_UART_SC0; end
        end
      end
      // ── Читання 8 бітів даних ──
      M_UART_BT0: begin
        if (uart_scan_x >= 10'd800) mstate<=M_UART_DW_INI;  // за межами
        else begin tb_ra<=uart_scan_x; mstate<=M_UART_BT1; end
      end
      M_UART_BT1: begin
        uart_accum[uart_bit_cnt] <= tb_rd[uart_ch_lcd]; // LSB first
        uart_bit_cnt <= uart_bit_cnt+1;
        if (scan_adv_full[15:10] != 0) mstate<=M_UART_DW_INI;
        else begin
          uart_scan_x <= scan_adv_full[9:0];
          mstate <= (uart_bit_cnt==3'd7) ? M_UART_SP0 : M_UART_BT0;
        end
      end
      // ── Стоп-біт ──
      M_UART_SP0: begin
        if (uart_scan_x >= 10'd800) mstate<=M_UART_DW_INI;
        else begin tb_ra<=uart_scan_x; mstate<=M_UART_SP1; end
      end
      M_UART_SP1: begin
        if (tb_rd[uart_ch_lcd]==1'b1 && uart_cnt<UART_MAX) begin  // стоп = 1: валідно
          uart_data[uart_cnt] <= uart_accum;
          uart_xpos[uart_cnt] <= uart_start_x;
          uart_cnt <= uart_cnt+1;
        end
        uart_prev_bit <= 1;  // після стоп-біта лінія висока
        if (scan_adv_full[15:10] != 0) mstate<=M_UART_DW_INI;
        else begin uart_scan_x<=scan_adv_full[9:0]; mstate<=M_UART_SC0; end
      end

      // ═══ UART DRAW FSM ══════════════════════════════════════════
      // Малює декодовані байти hex під відповідним каналом
      M_UART_DW_INI: begin
        uart_di<=0;
        mstate <= (uart_cnt > 0) ? M_UART_DW_HI : M_LA_DSET;
      end
      M_UART_DW_HI: begin
        text_mode<=1;
        cur_char  <= nibble_to_hex(uart_data[uart_di][7:4]);
        x_start   <= {6'b0, uart_xpos[uart_di]};
        x_end     <= {6'b0, uart_xpos[uart_di]} + 16'd15;
        y_start   <= r_uart_y0;
        y_end     <= r_uart_y0 + 9'd15;
        update_screen<=1; mstate<=M_UART_DW_HIW;
      end
      M_UART_DW_HIW: if(cmd_ndata_done) mstate<=M_UART_DW_LO;
      M_UART_DW_LO: begin
        cur_char  <= nibble_to_hex(uart_data[uart_di][3:0]);
        x_start   <= {6'b0, uart_xpos[uart_di]} + 16'd16;
        x_end     <= {6'b0, uart_xpos[uart_di]} + 16'd31;
        update_screen<=1; mstate<=M_UART_DW_LOW;
      end
      M_UART_DW_LOW: if(cmd_ndata_done) mstate<=M_UART_DW_NXT;
      M_UART_DW_NXT: begin
        text_mode<=0;
        if (uart_di+1 >= uart_cnt || uart_di+1 >= UART_MAX)
          mstate<=M_LA_DSET;   // всі відображено → малювати трасу
        else begin
          uart_di<=uart_di+1;
          mstate<= ({6'b0,uart_xpos[uart_di+1]}+32 <= SCREEN_W) ? M_UART_DW_HI : M_LA_DSET;
        end
      end
      M_LA_DSET:    begin tb_ra<=dx; mstate<=M_LA_DLAT; end
      M_LA_DLAT: begin
        la_cur<=tb_rd[7:0];
        if(dx==0) la_prev<=tb_rd[7:0];
        la_ch<=0; mstate<=M_LA_ERASE;
      end
      M_LA_ERASE: begin
        text_mode<=0;
        solid_color<=COL_OFF;
        x_start<=dx; x_end<=dx; y_start<=r_la_y0; y_end<=r_la_ye;
        update_screen<=1; mstate<=M_LA_ERASE_W;
      end
      M_LA_ERASE_W: if(cmd_ndata_done) mstate<=M_LA_CH;
      // Малюємо вертикальний сегмент каналу la_ch (фронти + рівні)
      M_LA_CH: begin
        solid_color<=COL_TEXT;             // зелений трас
        x_start<=dx; x_end<=dx;
        y_start<={7'd0,la_lo}; y_end<={7'd0,la_hi};
        update_screen<=1; mstate<=M_LA_CH_W;
      end
      M_LA_CH_W: if(cmd_ndata_done) begin
        if(la_ch==3'd7) mstate<=M_LA_NEXT;
        else begin la_ch<=la_ch+1; mstate<=M_LA_CH; end
      end
      M_LA_NEXT: begin
        la_prev<=la_cur;
        if(dx+1>=SCREEN_W) begin
          // LA закінчила малювання, dispatcher вирішує що далі
          mstate <= M_CHECK;
        end else begin
          dx<=dx+1; mstate<=M_LA_DSET;
        end
      end
      // LA idle: повтор / single / window scroll
      M_LA_LOOP: begin
        mstate <= M_DISPATCH;
      end
      M_LA_WAIT_PAN: begin
        mstate <= M_DISPATCH;
      end

      default: mstate<=M_INIT;
    endcase
  end
end
endmodule