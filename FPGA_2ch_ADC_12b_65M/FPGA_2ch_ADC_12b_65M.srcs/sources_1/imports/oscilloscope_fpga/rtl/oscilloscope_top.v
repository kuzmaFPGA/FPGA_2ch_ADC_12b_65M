`include "constants.vh"
// ============================================================
// oscilloscope_top.v — Двоканальний осцилограф (v5)
//   + time/div: 1-2-5 ряд, кнопки 4/6 для зміни масштабу
//   + відображення "T:NNNus" / "T:NNNms" замість частоти
//   + авто-тригер (кнопка '9' = тест-сигнал)
// ============================================================
module top_level #(parameter DEPTH=32768, parameter DEPTH_W=15, parameter PRETRIG=256) (
    input         clk,
    input  [3:0]  row_data_in,
    output [3:0]  col_data_out,
    output [15:0] LCD_DATA,
    output        LCD_WR, LCD_RS, LCD_CS, LCD_RESET, LCD_BL, LCD_RDX,
    output        led_1,
    input  [11:0] adc_ch1,
    input  [11:0] adc_ch2,
    output        adc_clk_out1,
    output        adc_clk_out2,
    output [12:0] SDRAM_A,
    output [1:0]  SDRAM_BA,
    output        SDRAM_CKE, SDRAM_CSn, SDRAM_WEn, SDRAM_CASn, SDRAM_RASn,
    output [1:0]  SDRAM_DQM,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_CLK,
    output        ts_clk, ts_cs, ts_mosi,
    input         ts_miso, ts_pen
);
assign ts_clk=0; assign ts_cs=1; assign ts_mosi=0;

// ── Параметри ──
localparam SCREEN_W = 800, SCREEN_H = 480;
localparam WAVE_Y0  = 16;
localparam [23:0] CH_BASE = 24'h00_0000;

localparam [15:0] COL_CH1  = RED;
localparam [15:0] COL_CH2  = YELLOW;
localparam [15:0] COL_BG   = BLUE;
localparam [15:0] COL_GRID = GRAY;
localparam [15:0] COL_TEXT = GREEN;

localparam NCH     = 40;
localparam CHAR_PX = 16;

localparam WAVE_H   = SCREEN_H - WAVE_Y0;           // 464
localparam HGRID_Y0 = WAVE_Y0 + WAVE_H / 4;         // 132
localparam HGRID_Y1 = WAVE_Y0 + WAVE_H / 2;         // 248
localparam HGRID_Y2 = WAVE_Y0 + 3 * WAVE_H / 4;     // 364

// ════ TIME/DIV — таблиця ════
// 10 кроків ряду 1-2-5. adc_clk=64 МГц, 80 пікс/розподіл.
// time_per_div = decimation * 80 / 64_000_000 [с]
// 5µs→dec=4, 10µs→8, 20µs→16, 50µs→40, 100µs→80, 200µs→160,
// 500µs→400, 1ms→800, 2ms→1600, 5ms→4000
localparam TDIV_MAX = 4'd9;

function [15:0] tdiv_decimation; input [3:0] i;
  case(i)
    0: tdiv_decimation=16'd4;     // 5µs/div
    1: tdiv_decimation=16'd8;     // 10µs/div
    2: tdiv_decimation=16'd16;    // 20µs/div  ← default
    3: tdiv_decimation=16'd40;    // 50µs/div
    4: tdiv_decimation=16'd80;    // 100µs/div
    5: tdiv_decimation=16'd160;   // 200µs/div
    6: tdiv_decimation=16'd400;   // 500µs/div
    7: tdiv_decimation=16'd800;   // 1ms/div
    8: tdiv_decimation=16'd1600;  // 2ms/div
    9: tdiv_decimation=16'd4000;  // 5ms/div
    default: tdiv_decimation=16'd16;
  endcase
endfunction

// Повертає 6 glyph-індексів [29:25]=g0..[4:0]=g5 для рядка time/div
// glyph 22='u', 23='s', 24='m', 25='T'
function [29:0] tdiv_glyphs; input [3:0] i;
  case(i)
    //                  sp    sp    val   val   unit  's'
    0: tdiv_glyphs={5'd11,5'd11,5'd11,5'd5,5'd22,5'd23}; // "   5us"
    1: tdiv_glyphs={5'd11,5'd11,5'd1, 5'd0,5'd22,5'd23}; // "  10us"
    2: tdiv_glyphs={5'd11,5'd11,5'd2, 5'd0,5'd22,5'd23}; // "  20us"
    3: tdiv_glyphs={5'd11,5'd11,5'd5, 5'd0,5'd22,5'd23}; // "  50us"
    4: tdiv_glyphs={5'd11,5'd1, 5'd0, 5'd0,5'd22,5'd23}; // " 100us"
    5: tdiv_glyphs={5'd11,5'd2, 5'd0, 5'd0,5'd22,5'd23}; // " 200us"
    6: tdiv_glyphs={5'd11,5'd5, 5'd0, 5'd0,5'd22,5'd23}; // " 500us"
    7: tdiv_glyphs={5'd11,5'd11,5'd11,5'd1,5'd24,5'd23}; // "   1ms"
    8: tdiv_glyphs={5'd11,5'd11,5'd11,5'd2,5'd24,5'd23}; // "   2ms"
    9: tdiv_glyphs={5'd11,5'd11,5'd11,5'd5,5'd24,5'd23}; // "   5ms"
    default: tdiv_glyphs={5'd11,5'd11,5'd2,5'd0,5'd22,5'd23};
  endcase
endfunction

// ── Шрифт 8×8 ──
// Нові гліфи: 22='u', 23='s', 24='m', 25='T'
function [63:0] glyph; input [4:0] c;
  case (c)
    5'd 0: glyph=64'h003E676F7B73633E; 5'd 1: glyph=64'h003F0C0C0C0C0E0C;
    5'd 2: glyph=64'h003F33061C30331E; 5'd 3: glyph=64'h001E33301C30331E;
    5'd 4: glyph=64'h0078307F33363C38; 5'd 5: glyph=64'h001E3330301F033F;
    5'd 6: glyph=64'h001E33331F03061C; 5'd 7: glyph=64'h000C0C0C1830333F;
    5'd 8: glyph=64'h001E33331E33331E; 5'd 9: glyph=64'h000E18303E33331E;
    5'd10: glyph=64'h000C0C0000000000; // '.'
    5'd11: glyph=64'h0000000000000000; // ' '
    5'd12: glyph=64'h000C1E3333333333; // 'V'
    5'd13: glyph=64'h000F063E663B0000; // 'p'
    5'd14: glyph=64'h001E33030303331E; // 'C'
    5'd15: glyph=64'h003333333F333333; // 'H'
    5'd16: glyph=64'h0000003F003F0000; // '='
    5'd17: glyph=64'h000F06060F06361C; // 'f'
    5'd18: glyph=64'h003F060C183F0000; // 'z'
    5'd19: glyph=64'h0067361E36660607; // 'k' (unused, kept)
    5'd20: glyph=64'h006363636B7F7763; // 'M' (unused, kept)
    5'd21: glyph=64'h000C0C00000C0C00; // ':'
    5'd22: glyph=64'h007EC3C3C3C30000; // 'u'  µs
    5'd23: glyph=64'h003EC03E033E0000; // 's'
    5'd24: glyph=64'h006B6B6B6B360000; // 'm'  ms
    5'd25: glyph=64'h00181818181818FF; // 'T'  T/div
    default: glyph=64'h0;
  endcase
endfunction

// ════ PLL + ВНУТРІШНІЙ RESET ════
wire sys_clk, sdram_clk, adc_clk, kbd_clk, pll_locked;
reg [19:0] por_cnt = 20'h0;
always @(posedge sys_clk) if (!por_cnt[19]) por_cnt <= por_cnt + 1;
wire reset_n = pll_locked | por_cnt[19];

clk_wiz_0 pll(
  .clk_in1(clk),.clk_out1(sys_clk),.clk_out2(sdram_clk),
  .clk_out3(adc_clk),.clk_out4(kbd_clk),.locked(pll_locked));
wire lcd_clk = sys_clk;

ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  sdram_clk_oddr(.Q(SDRAM_CLK),.C(sdram_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  adc_clk_oddr1(.Q(adc_clk_out1),.C(adc_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));
ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("SYNC"))
  adc_clk_oddr2(.Q(adc_clk_out2),.C(adc_clk),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(1'b0),.S(1'b0));

reg [24:0] led_cnt; reg led_r; reg sdram_error = 0;
always @(posedge sys_clk)
  if(led_cnt==25'd24_999_999) begin led_cnt<=0; led_r<=~led_r; end
  else led_cnt<=led_cnt+1;
assign led_1 = sdram_error ? led_cnt[22] : led_r;

// ════ КЕРУВАННЯ (kbd 8 МГц) ════
// Кнопки: 1=RUN/STOP, D=single, 4/6=time/div↑↓, 2/8=trig↑↓,
//         5=edge, A/B=pan, F=boot, 9=test-signal
reg run_mode; reg [3:0] tdiv_idx; reg [11:0] trig_level; reg trig_edge;
reg [DEPTH_W-1:0] pan; reg single_req, go_menu, ctrl_changed;
reg test_mode;
wire key_ready; wire [3:0] key_data_out; reg key_prev_ready, key_read;
wire press_count;
KeyPadInterpreter keypad_inst (
    .Clock(kbd_clk),.ResetButton(reset_n),.KeyRead(key_read),
    .RowDataIn(row_data_in),.KeyReady(key_ready),.DataOut(key_data_out),
    .ColDataOut(col_data_out),.PressCount(press_count));
localparam PAN_STEP = 16'd400;
always @(posedge kbd_clk or negedge reset_n) begin
  if(!reset_n) begin
    run_mode<=1; tdiv_idx<=4'd2; trig_level<=12'd2048; trig_edge<=0;
    pan<=0; single_req<=0; go_menu<=0; key_read<=0; key_prev_ready<=0;
    ctrl_changed<=0; test_mode<=0;
  end else begin
    key_read<=0; single_req<=0; ctrl_changed<=0;
    if(key_ready && !key_prev_ready) begin
      key_read<=1;
      case(key_data_out)
        4'h1: run_mode<=~run_mode;
        4'hD: single_req<=1;
        4'h4: if(tdiv_idx>0)        tdiv_idx<=tdiv_idx-1; // швидше
        4'h6: if(tdiv_idx<TDIV_MAX) tdiv_idx<=tdiv_idx+1; // повільніше
        4'h2: if(trig_level<12'd4080) trig_level<=trig_level+12'd16;
        4'h8: if(trig_level>12'd16)   trig_level<=trig_level-12'd16;
        4'h5: trig_edge<=~trig_edge;
        4'hA: begin if(pan>PAN_STEP) pan<=pan-PAN_STEP; else pan<=0; ctrl_changed<=1; end
        4'hB: begin if(pan<DEPTH-SCREEN_W-PAN_STEP) pan<=pan+PAN_STEP; ctrl_changed<=1; end
        4'hF: go_menu<=1;
        4'h9: test_mode<=~test_mode;
        default:;
      endcase
    end
    key_prev_ready<=key_ready;
  end
end
multiboot mb(.clk(sys_clk),.trigger(go_menu),.target_addr(24'h00_0000));

// Синхронізація tdiv_idx → adc_clk (для decimation в adc_capture)
(* ASYNC_REG="TRUE" *) reg [3:0] tidx_adc1=2, tidx_adc2=2;
always @(posedge adc_clk) begin tidx_adc1<=tdiv_idx; tidx_adc2<=tidx_adc1; end
wire [15:0] decimation = tdiv_decimation(tidx_adc2); // стабільне в adc домені

// Синхронізація tdiv_idx → lcd_clk (для відображення)
(* ASYNC_REG="TRUE" *) reg [3:0] tidx_lcd1=2, tidx_lcd2=2;
always @(posedge lcd_clk) begin tidx_lcd1<=tdiv_idx; tidx_lcd2<=tidx_lcd1; end

// ════ SDRAM + арбітр ════
wire cap_cmd_en,cap_cmd_we; wire[23:0]cap_cmd_addr; wire[9:0]cap_cmd_len;
wire[15:0]cap_wr_data; wire cap_wr_valid;
reg  rnd_cmd_en,rnd_cmd_we; reg[23:0]rnd_cmd_addr; reg[9:0]rnd_cmd_len;
wire sd_cmd_ready_w,sd_wr_ready_w,sd_rd_valid,sd_ready; wire[15:0]sd_rd_data;
reg  sd_cmd_en,sd_cmd_we; reg[23:0]sd_cmd_addr; reg[9:0]sd_cmd_len;
reg  [15:0]sd_wr_data; reg sd_wr_valid;
reg  capture_active;
always @(*) begin
  if(capture_active) begin
    sd_cmd_en=cap_cmd_en; sd_cmd_we=cap_cmd_we;
    sd_cmd_addr=cap_cmd_addr; sd_cmd_len=cap_cmd_len;
    sd_wr_data=cap_wr_data; sd_wr_valid=cap_wr_valid;
  end else begin
    sd_cmd_en=rnd_cmd_en; sd_cmd_we=rnd_cmd_we;
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

// ── CDC: arm toggle ──
reg arm_sys;
(* ASYNC_REG="TRUE" *) reg arm_s1,arm_s2,arm_s3;
always @(posedge adc_clk) begin arm_s1<=arm_sys; arm_s2<=arm_s1; arm_s3<=arm_s2; end
wire arm_adc = arm_s2 ^ arm_s3;

// ── CDC: drain done ──
wire capture_done_adc;
(* ASYNC_REG="TRUE" *) reg cds1,cds2;
always @(posedge sys_clk) begin cds1<=capture_done_adc; cds2<=cds1; end

wire drain_done_sd;
(* ASYNC_REG="TRUE" *) reg dd1,dd2;
always @(posedge sys_clk) begin dd1<=drain_done_sd; dd2<=dd1; end
wire drain_done_sys = dd2;

// ── CDC: sd_ready → lcd ──
(* ASYNC_REG="TRUE" *) reg sd_rdy_s1=0,sd_rdy_s2=0;
always @(posedge lcd_clk) begin sd_rdy_s1<=sd_ready; sd_rdy_s2<=sd_rdy_s1; end
wire sd_ready_lcd = sd_rdy_s2;

// ── Тест-сигнал (кнопка '9') ──
(* ASYNC_REG="TRUE" *) reg tm_s1=0,tm_s2=0;
always @(posedge adc_clk) begin tm_s1<=test_mode; tm_s2<=tm_s1; end
reg [11:0] test_cnt = 0;
always @(posedge adc_clk) test_cnt <= test_cnt + 12'd13;
wire [11:0] adc_in1 = tm_s2 ? test_cnt           : adc_ch1;
wire [11:0] adc_in2 = tm_s2 ? (12'hFFF-test_cnt) : adc_ch2;

adc_capture #(.CH_BASE(CH_BASE),.DEPTH(DEPTH),.DEPTH_W(DEPTH_W),.BATCH(256)) adc_cap(
  .adc_clk(adc_clk),.reset_n(reset_n),
  .adc_ch1(adc_in1),.adc_ch2(adc_in2),
  .decimation(decimation),.trig_level(trig_level),.trig_edge(trig_edge),
  .pre_trig(PRETRIG[DEPTH_W-1:0]),.arm(arm_adc),.capture_done(capture_done_adc),
  .sdram_clk(sdram_clk),.sdram_cmd_ready(sd_cmd_ready_w),
  .sdram_cmd_en(cap_cmd_en),.sdram_cmd_we(cap_cmd_we),
  .sdram_cmd_addr(cap_cmd_addr),.sdram_cmd_len(cap_cmd_len),
  .sdram_wr_ready(sd_wr_ready_w),.sdram_wr_data(cap_wr_data),
  .sdram_wr_valid(cap_wr_valid),.drain_done(drain_done_sd));

// ════ TRACE BRAM ════
reg [17:0] trace_bram [0:SCREEN_W-1];
reg [9:0] tb_wa; reg [17:0] tb_wd; reg tb_we;
reg [9:0] tb_ra; reg [17:0] tb_rd;
always @(posedge sdram_clk) if(tb_we) trace_bram[tb_wa]<=tb_wd;
always @(posedge lcd_clk)   tb_rd<=trace_bram[tb_ra];

// ════ RENDER + ВИМІРЮВАННЯ Vpp (sdram_clk) ════
// Вимірюємо лише min/max для Vpp (частота прибрана, використовуємо T/div замість)
reg start_render_sys;
(* ASYNC_REG="TRUE" *) reg srs1,srs2,srs3;
always @(posedge sdram_clk) begin srs1<=start_render_sys;srs2<=srs1;srs3<=srs2; end
wire start_render = srs2 ^ srs3;

reg render_done_sd;
(* ASYNC_REG="TRUE" *) reg rds1,rds2;
always @(posedge sys_clk) begin rds1<=render_done_sd; rds2<=rds1; end
wire render_done_sys = rds2;

(* ASYNC_REG="TRUE" *) reg [DEPTH_W-1:0] pan_s1,pan_s2;
always @(posedge sdram_clk) begin pan_s1<=pan; pan_s2<=pan_s1; end

function [8:0] map_y; input [11:0] s; reg [20:0] p;
  begin p=s*21'd464; map_y=9'd479-p[20:12]; end
endfunction

localparam R_IDLE=3'd0,R_RD=3'd1,R_W1=3'd2,R_W2=3'd3,R_MAP=3'd4,R_WRITE=3'd5,R_DONE=3'd6;
reg [2:0] rstate; reg [9:0] rx; reg [11:0] rs1,rs2; reg [23:0] rbase;
reg [8:0] my1,my2;
reg start_pending;
reg [11:0] m_min1,m_max1,m_min2,m_max2;
reg [11:0] f_min1,f_max1,f_min2,f_max2;

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
      R_IDLE: if(start_pending && !capture_active) begin
        start_pending<=0; render_done_sd<=0;
        rx<=0; rbase<=CH_BASE+{pan_s2,1'b0};
        m_min1<=12'hFFF; m_max1<=0; m_min2<=12'hFFF; m_max2<=0;
        rstate<=R_RD;
      end
      R_RD: begin
        rnd_cmd_we<=0; rnd_cmd_addr<=rbase+{rx,1'b0}; rnd_cmd_len<=10'd2;
        rnd_cmd_en<=1;
        if(rnd_cmd_en && sd_cmd_ready_w) begin rnd_cmd_en<=0; rstate<=R_W1; end
      end
      R_W1: if(sd_rd_valid) begin rs1<=sd_rd_data[11:0]; rstate<=R_W2; end
      R_W2: if(sd_rd_valid) begin rs2<=sd_rd_data[11:0]; rstate<=R_MAP; end
      R_MAP: begin                              // конвеєр map_y (вирішує timing 166→100МГц)
        my1<=map_y(rs1); my2<=map_y(rs2); rstate<=R_WRITE;
      end
      R_WRITE: begin
        tb_wa<=rx; tb_wd<={my2,my1}; tb_we<=1;
        if(rs1<m_min1) m_min1<=rs1; if(rs1>m_max1) m_max1<=rs1;
        if(rs2<m_min2) m_min2<=rs2; if(rs2>m_max2) m_max2<=rs2;
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
reg [4:0] cur_char;
wire cmd_ndata_done,init_done,start_read_data,cmd_done,cmd_data_done;
wire [7:0] lcd_state; wire [31:0] data_count;

wire [3:0] cic=data_count[3:0], ric=data_count[7:4];
wire [63:0] cur_glyph=glyph(cur_char);
wire [7:0]  grow=cur_glyph[{ric[3:1],3'b000}+:8];
wire        fbit=grow[cic[3:1]];
wire [15:0] pixel_out=text_mode?(fbit?COL_TEXT:COL_BG):solid_color;

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

// ════ Вимірювання Vpp → BCD ════
wire [11:0] vpp1=f_max1-f_min1, vpp2=f_max2-f_min2;

reg bc_start; reg [26:0] bc_in; wire [31:0] bc_out; wire bc_done,bc_busy;
bin2bcd #(.IN_W(27),.DIGITS(8)) bc(
  .clk(lcd_clk),.reset_n(reset_n),.start(bc_start),
  .bin(bc_in),.bcd(bc_out),.done(bc_done),.busy(bc_busy));

reg [15:0] dvpp1,dvpp2;
reg [4:0] text_buf [0:NCH-1];

// ════ MAIN FSM (lcd_clk) ════
localparam
  M_INIT       = 6'd0,
  M_ARM        = 6'd1,
  M_WAIT_CAP   = 6'd2,
  M_RENDER     = 6'd3,
  M_WAIT_RND   = 6'd4,
  M_DRAW_SET   = 6'd5,
  M_DRAW_LAT   = 6'd6,
  M_ERASE      = 6'd7,
  M_ERASE_W    = 6'd8,
  M_CH1        = 6'd9,
  M_CH1_W      = 6'd10,
  M_CH2        = 6'd11,
  M_CH2_W      = 6'd12,
  M_NEXTCOL    = 6'd13,
  M_BCD1       = 6'd14,  // Vpp CH1
  M_BCD1W      = 6'd15,
  M_BCD2       = 6'd16,  // Vpp CH2
  M_BCD2W      = 6'd17,
  M_BUILD      = 6'd18,  // формування тексту (включно T/div)
  M_TSET       = 6'd19,
  M_TGO        = 6'd20,
  M_TW         = 6'd21,
  M_CHECK      = 6'd22,
  M_WAIT_PAN   = 6'd23,
  M_ARM_LO     = 6'd24,
  M_RENDER_LO  = 6'd25,
  M_FILL_BG    = 6'd30,
  M_FILL_BG_W  = 6'd31,
  M_VGRID_DRAW = 6'd32,
  M_VGRID_W    = 6'd33,
  M_HGRID_DRAW = 6'd34,
  M_HGRID_W    = 6'd35,
  M_WAIT_SD    = 6'd36;

reg [5:0] mstate;
reg [9:0] dx; reg [8:0] gy;
reg [8:0] py1,py2,cy1,cy2;
reg capture_active_lcd; reg [5:0] tc;
reg [27:0] wait_sd_cnt;
localparam SD_TIMEOUT = 28'd150_000_000;

(* ASYNC_REG="TRUE" *) reg cas1,cas2;
always @(posedge sdram_clk) begin cas1<=capture_active_lcd; cas2<=cas1; end
always @(*) capture_active=cas2;

(* ASYNC_REG="TRUE" *) reg cc1,cc2,cc3;
always @(posedge lcd_clk) begin cc1<=ctrl_changed;cc2<=cc1;cc3<=cc2; end
wire ctrl_changed_lcd=cc2&~cc3;

(* ASYNC_REG="TRUE" *) reg sgg1,sgg2,sgg3;
always @(posedge lcd_clk) begin sgg1<=single_req;sgg2<=sgg1;sgg3<=sgg2; end
wire single_lcd=sgg2&~sgg3;

(* ASYNC_REG="TRUE" *) reg rm1,rm2;
always @(posedge lcd_clk) begin rm1<=run_mode;rm2<=rm1; end
wire run_lcd=rm2;

wire [8:0] s1_lo=(cy1<py1)?cy1:py1, s1_hi=(cy1<py1)?py1:cy1;
wire [8:0] s2_lo=(cy2<py2)?cy2:py2, s2_hi=(cy2<py2)?py2:cy2;

integer ti;
always @(posedge lcd_clk or negedge reset_n) begin
  if(!reset_n) begin
    mstate<=M_INIT; dx<=0; gy<=0; wait_sd_cnt<=0;
    py1<=240; py2<=240; cy1<=240; cy2<=240;
    update_screen<=0; solid_color<=COL_BG; text_mode<=0; cur_char<=5'd11;
    x_start<=0; x_end<=0; y_start<=0; y_end<=0;
    arm_sys<=0; start_render_sys<=0; capture_active_lcd<=0;
    tb_ra<=0; bc_start<=0; bc_in<=0;
    dvpp1<=0; dvpp2<=0; tc<=0; sdram_error<=0;
    for(ti=0;ti<NCH;ti=ti+1) text_buf[ti]<=5'd11;
  end else begin
    update_screen<=0; bc_start<=0;
    case(mstate)
      M_INIT: if(init_done) mstate<=M_FILL_BG;

      // ── фон ──
      M_FILL_BG: begin
        text_mode<=0; solid_color<=COL_BG;
        x_start<=0; x_end<=SCREEN_W-1; y_start<=0; y_end<=SCREEN_H-1;
        update_screen<=1; mstate<=M_FILL_BG_W;
      end
      M_FILL_BG_W: if(cmd_ndata_done) begin dx<=80; mstate<=M_VGRID_DRAW; end

      // ── вертикальна сітка: x = 80, 160, ..., 720 ──
      M_VGRID_DRAW: begin
        solid_color<=COL_GRID;
        x_start<=dx; x_end<=dx; y_start<=WAVE_Y0; y_end<=SCREEN_H-1;
        update_screen<=1; mstate<=M_VGRID_W;
      end
      M_VGRID_W: if(cmd_ndata_done) begin
        if(dx>=720) begin gy<=HGRID_Y0[8:0]; mstate<=M_HGRID_DRAW; end
        else        begin dx<=dx+80; mstate<=M_VGRID_DRAW; end
      end

      // ── горизонтальна сітка: y = 132, 248, 364 ──
      M_HGRID_DRAW: begin
        solid_color<=COL_GRID;
        x_start<=0; x_end<=SCREEN_W-1; y_start<=gy; y_end<=gy;
        update_screen<=1; mstate<=M_HGRID_W;
      end
      M_HGRID_W: if(cmd_ndata_done) begin
        if     (gy>=HGRID_Y2[8:0]) begin wait_sd_cnt<=0; mstate<=M_WAIT_SD; end
        else if(gy>=HGRID_Y1[8:0]) begin gy<=HGRID_Y2[8:0]; mstate<=M_HGRID_DRAW; end
        else                        begin gy<=HGRID_Y1[8:0]; mstate<=M_HGRID_DRAW; end
      end

      // ── чекаємо SDRAM (таймаут → LED швидко) ──
      M_WAIT_SD: begin
        if(sd_ready_lcd) begin sdram_error<=0; mstate<=M_ARM; end
        else begin
          if(wait_sd_cnt<SD_TIMEOUT) wait_sd_cnt<=wait_sd_cnt+1;
          else sdram_error<=1;
        end
      end

      // ── захоплення ──
      M_ARM:      begin capture_active_lcd<=1; arm_sys<=~arm_sys; mstate<=M_ARM_LO; end
      M_ARM_LO:   if(!drain_done_sys) mstate<=M_WAIT_CAP;
      M_WAIT_CAP: if(drain_done_sys)  begin capture_active_lcd<=0; mstate<=M_RENDER; end

      // ── рендер ──
      M_RENDER:     begin start_render_sys<=~start_render_sys; mstate<=M_RENDER_LO; end
      M_RENDER_LO:  if(!render_done_sys) mstate<=M_WAIT_RND;
      M_WAIT_RND:   if(render_done_sys)  begin dx<=0; mstate<=M_DRAW_SET; end

      // ── малювання осцилограми (по стовпцю) ──
      M_DRAW_SET: begin tb_ra<=dx; mstate<=M_DRAW_LAT; end
      M_DRAW_LAT: begin
        cy1<=tb_rd[8:0]; cy2<=tb_rd[17:9];
        if(dx==0) begin py1<=tb_rd[8:0]; py2<=tb_rd[17:9]; end
        mstate<=M_ERASE;
      end
      M_ERASE: begin
        text_mode<=0;
        solid_color<=(dx[6:0]==7'd0)?COL_GRID:COL_BG;
        x_start<=dx; x_end<=dx; y_start<=WAVE_Y0; y_end<=SCREEN_H-1;
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
      M_CH2_W: if(cmd_ndata_done) mstate<=M_NEXTCOL;
      M_NEXTCOL: begin
        py1<=cy1; py2<=cy2;
        if(dx+1>=SCREEN_W) mstate<=M_BCD1;
        else begin dx<=dx+1; mstate<=M_DRAW_SET; end
      end

      // ── BCD для Vpp ──
      M_BCD1:  begin bc_in<={15'd0,vpp1}; bc_start<=1; mstate<=M_BCD1W; end
      M_BCD1W: if(bc_done) begin dvpp1<=bc_out[15:0]; mstate<=M_BCD2; end
      M_BCD2:  begin bc_in<={15'd0,vpp2}; bc_start<=1; mstate<=M_BCD2W; end
      M_BCD2W: if(bc_done) begin dvpp2<=bc_out[15:0]; mstate<=M_BUILD; end

      // ── формування тексту ──
      // Формат 40 символів:
      // "CH1 Vpp:VVVV  CH2 Vpp:VVVV  T:NNNXXs    "
      M_BUILD: begin
        // CH1 (0-11)
        text_buf[0]<=14; text_buf[1]<=15; text_buf[2]<=1;  text_buf[3]<=11;  // "CH1 "
        text_buf[4]<=12; text_buf[5]<=13; text_buf[6]<=13; text_buf[7]<=21;  // "Vpp:"
        text_buf[8] <={1'b0,dvpp1[15:12]}; text_buf[9] <={1'b0,dvpp1[11:8]};
        text_buf[10]<={1'b0,dvpp1[7:4]};   text_buf[11]<={1'b0,dvpp1[3:0]};
        text_buf[12]<=11; text_buf[13]<=11;  // "  "
        // CH2 (13-25)
        text_buf[14]<=14; text_buf[15]<=15; text_buf[16]<=2;  text_buf[17]<=11; // "CH2 "
        text_buf[18]<=12; text_buf[19]<=13; text_buf[20]<=13; text_buf[21]<=21; // "Vpp:"
        text_buf[22]<={1'b0,dvpp2[15:12]}; text_buf[23]<={1'b0,dvpp2[11:8]};
        text_buf[24]<={1'b0,dvpp2[7:4]};   text_buf[25]<={1'b0,dvpp2[3:0]};
        text_buf[26]<=11; text_buf[27]<=11; // "  "
        // T/div (28-39) — "T:  NNXXs   "
        text_buf[28]<=25; text_buf[29]<=21; // "T:"
        begin
          // 6 гліфів з таблиці tdiv_glyphs(tidx_lcd2)
          reg [29:0] tdg;
          tdg = tdiv_glyphs(tidx_lcd2);
          text_buf[30]<=tdg[29:25]; text_buf[31]<=tdg[24:20];
          text_buf[32]<=tdg[19:15]; text_buf[33]<=tdg[14:10];
          text_buf[34]<=tdg[9:5];   text_buf[35]<=tdg[4:0];
        end
        text_buf[36]<=11; text_buf[37]<=11; text_buf[38]<=11; text_buf[39]<=11;
        tc<=0; mstate<=M_TSET;
      end

      // ── малювання тексту ──
      M_TSET: begin
        text_mode<=1; cur_char<=text_buf[tc[5:0]];
        x_start<={tc,4'b0}; x_end<={tc,4'b0}+CHAR_PX-1;
        y_start<=0; y_end<=CHAR_PX-1;
        mstate<=M_TGO;
      end
      M_TGO: begin update_screen<=1; mstate<=M_TW; end
      M_TW: if(cmd_ndata_done) begin
        if(tc+1>=NCH) begin text_mode<=0; mstate<=M_CHECK; end
        else begin tc<=tc+1; mstate<=M_TSET; end
      end

      M_CHECK: if(run_lcd) mstate<=M_ARM; else mstate<=M_WAIT_PAN;
      M_WAIT_PAN: begin
        if(run_lcd||single_lcd) mstate<=M_ARM;
        else if(ctrl_changed_lcd) mstate<=M_RENDER;
      end
      default: mstate<=M_INIT;
    endcase
  end
end
endmodule
