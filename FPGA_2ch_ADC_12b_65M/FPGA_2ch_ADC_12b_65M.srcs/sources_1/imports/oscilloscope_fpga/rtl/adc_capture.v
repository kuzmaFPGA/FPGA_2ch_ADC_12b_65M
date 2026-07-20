// ============================================================
// adc_capture.v - захоплення 2× паралельних АЦП у SDRAM
//                 (BATCH-BURST + чистий пост-тригер)
//
// АЦП: 12-біт паралельні, 65 Msps, 2 канали
// Потік: adc_clk(65) → async FIFO → sdram_clk(100) → SDRAM burst
//
// Захоплення: arm → чекати тригер (CH1) → записати рівно DEPTH пар
//   → drain_done (усе злито в SDRAM). FIFO спорожнюється між кадрами.
//
// BATCH-BURST: дренаж ллє BATCH пар одним burst=2*BATCH слів
//   (≤512 = 1 рядок) з prefetch-конвеєром → 1 слово/такт.
//   ~97 M words/s ≈ 48 M пар/с (decimation≥2 → необмежено).
//
// SDRAM (інтерлівно): sample i → CH1@2i, CH2@2i+1
// ============================================================
module adc_capture #(
    parameter [23:0] CH_BASE = 24'h00_0000,
    parameter        DEPTH   = 32768,
    parameter        DEPTH_W = 15,
    parameter        BATCH   = 256
) (
    input             adc_clk,
    input             reset_n,
    input      [11:0] adc_ch1,
    input      [11:0] adc_ch2,
    input      [15:0] decimation,
    input      [11:0] trig_level,
    input             trig_edge,
    input      [DEPTH_W-1:0] pre_trig,   // (нині не використовується)
    input             arm,
    output reg        capture_done,      // семплування завершено
    input             sdram_clk,
    input             sdram_cmd_ready,
    output reg        sdram_cmd_en,
    output reg        sdram_cmd_we,
    output reg [23:0] sdram_cmd_addr,
    output reg [9:0]  sdram_cmd_len,
    input             sdram_wr_ready,
    output reg [15:0] sdram_wr_data,
    output reg        sdram_wr_valid,
    output reg        drain_done         // усе записано в SDRAM (sdram domain)
);

// ═══ ADC DOMAIN: decimation + trigger + FIFO write ═══════════
reg [15:0] decim_cnt; reg sample_tick;
always @(posedge adc_clk or negedge reset_n) begin
    if (!reset_n) begin decim_cnt<=0; sample_tick<=0; end
    else begin
        sample_tick <= 0;
        if (decim_cnt+1 >= decimation) begin decim_cnt<=0; sample_tick<=1; end
        else decim_cnt <= decim_cnt+1;
    end
end

(* IOB="TRUE" *) reg [11:0] ch1_r, ch2_r;
always @(posedge adc_clk) begin ch1_r<=adc_ch1; ch2_r<=adc_ch2; end

reg [11:0] ch1_prev;
reg [1:0]  cap_state;
reg [DEPTH_W-1:0] cap_cnt;
reg        arm_prev;
reg [25:0] fifo_wdata; reg fifo_wen; reg trig_hit;
reg        capturing;
// Авто-тригер: рахує ТАКТИ adc_clk (не семпли!) у стані C_WAIT.
// КРИТИЧНО: 'arm' виставляється диспетчером щоразу на початку кожного
// scope-циклу render - набагато частіше за 70 мс. Якщо реальний сигнал
// не перетинає trig_level, cap_state весь час скидається в C_WAIT
// раніше ніж встигне спрацювати старий (надто повільний) таймаут,
// і захоплення НІКОЛИ не завершується → на екрані порожньо/старий кадр.
// 2^11 тактів adc_clk (60МГц) ≈ 34 мкс - на порядки швидше за один
// прохід диспетчера (мс), тому авто-тригер завжди встигає спрацювати.
reg [11:0] auto_trig_cnt;

localparam C_IDLE=2'd0, C_WAIT=2'd1, C_CAP=2'd2, C_DONE=2'd3;

always @(posedge adc_clk or negedge reset_n) begin
    if (!reset_n) begin
        cap_state<=C_IDLE; cap_cnt<=0; arm_prev<=0; ch1_prev<=0;
        fifo_wen<=0; fifo_wdata<=0; capture_done<=0; capturing<=0;
        auto_trig_cnt<=0;
    end else begin
        fifo_wen <= 0; arm_prev <= arm;
        if (arm && !arm_prev) begin
            cap_state<=C_WAIT; cap_cnt<=0; capture_done<=0; capturing<=1;
            auto_trig_cnt<=0;
        end else if (cap_state==C_WAIT) begin
            // тікає кожен такт adc_clk - фіксований таймаут ~70 мс
            auto_trig_cnt <= auto_trig_cnt + 1;
        end
        if (sample_tick) begin
            ch1_prev <= ch1_r;
            trig_hit = 1'b0;
            if (!trig_edge) begin
                if (ch1_prev<trig_level && ch1_r>=trig_level) trig_hit=1'b1;
            end else begin
                if (ch1_prev>trig_level && ch1_r<=trig_level) trig_hit=1'b1;
            end
            case (cap_state)
                C_WAIT: begin
                    // тригер: або сигнал, або таймаут авто-тригера (~34 мкс)
                    if (trig_hit || auto_trig_cnt[11]) begin
                        cap_state<=C_CAP; cap_cnt<=0; auto_trig_cnt<=0;
                        fifo_wdata<={1'b0,ch2_r,1'b0,ch1_r}; fifo_wen<=1;
                    end
                end
                C_CAP: begin
                    fifo_wdata<={1'b0,ch2_r,1'b0,ch1_r}; fifo_wen<=1;
                    cap_cnt<=cap_cnt+1;
                    if (cap_cnt+1 >= DEPTH) begin
                        cap_state<=C_DONE; capture_done<=1; capturing<=0;
                    end
                end
                C_DONE: capture_done<=1;
                default: ;
            endcase
        end
    end
end

// ═══ ASYNC FIFO (adc→sdram), 26-біт × 1024 ══════════════════
// ram_style=block → Vivado виводить RAMB36 (SDP, різні клоки)
// КРИТИЧНО: BRAM-блок без async reset → економить ~25 000 FF
localparam FIFO_AW=10;
(* ram_style = "block" *) reg [25:0] fifo_mem [0:(1<<FIFO_AW)-1];
reg [FIFO_AW:0] wr_ptr_bin,wr_ptr_gray,rd_ptr_bin,rd_ptr_gray;
function [FIFO_AW:0] bin2gray; input [FIFO_AW:0] b; bin2gray=b^(b>>1); endfunction
function [FIFO_AW:0] gray2bin; input [FIFO_AW:0] g; integer i; reg[FIFO_AW:0]b;
  begin b[FIFO_AW]=g[FIFO_AW];
    for(i=FIFO_AW-1;i>=0;i=i-1) b[i]=b[i+1]^g[i]; gray2bin=b; end
endfunction

// Write port: adc_clk, БЕЗ async reset (обов'язково для BRAM inference)
always @(posedge adc_clk)
    if(fifo_wen) fifo_mem[wr_ptr_bin[FIFO_AW-1:0]] <= fifo_wdata;

// Write pointer: окремо, з async reset
always @(posedge adc_clk or negedge reset_n) begin
    if(!reset_n) begin wr_ptr_bin<=0; wr_ptr_gray<=0; end
    else if(fifo_wen) begin
        wr_ptr_bin<=wr_ptr_bin+1; wr_ptr_gray<=bin2gray(wr_ptr_bin+1);
    end
end
(* ASYNC_REG="TRUE" *) reg [FIFO_AW:0] wr_gray_s1,wr_gray_s2;
always @(posedge sdram_clk) begin wr_gray_s1<=wr_ptr_gray; wr_gray_s2<=wr_gray_s1; end
wire [FIFO_AW:0] wr_ptr_sync = gray2bin(wr_gray_s2);
wire [FIFO_AW:0] fifo_fill   = wr_ptr_sync - rd_ptr_bin;

reg [25:0] fifo_rdata; reg fifo_ren;
// Read port: sdram_clk, БЕЗ async reset (обов'язково для BRAM inference)
always @(posedge sdram_clk)
    if(fifo_ren) fifo_rdata <= fifo_mem[rd_ptr_bin[FIFO_AW-1:0]];

// Read pointer: окремо, з async reset
always @(posedge sdram_clk or negedge reset_n) begin
    if(!reset_n) begin rd_ptr_bin<=0; rd_ptr_gray<=0; end
    else if(fifo_ren) begin
        rd_ptr_bin<=rd_ptr_bin+1; rd_ptr_gray<=bin2gray(rd_ptr_bin+1);
    end
end

// capturing (рівень) → sdram domain; фронт скидає wr_idx
(* ASYNC_REG="TRUE" *) reg capg_s1,capg_s2,capg_s3;
always @(posedge sdram_clk) begin capg_s1<=capturing;capg_s2<=capg_s1;capg_s3<=capg_s2; end
wire capturing_rise = capg_s2 & ~capg_s3;
// capture_done (семплування) → sdram
(* ASYNC_REG="TRUE" *) reg cd_s1,cd_s2;
always @(posedge sdram_clk) begin cd_s1<=capture_done; cd_s2<=cd_s1; end
wire cap_done_sd = cd_s2;

// ═══ BATCH-BURST DRAIN: FIFO → SDRAM (1 слово/такт) ══════════
localparam B_IDLE=3'd0,B_LOAD=3'd1,B_CMD=3'd2,B_WLO=3'd3,B_WHI=3'd4,B_FIN=3'd5;
reg [2:0]  bstate;
reg [23:0] wr_idx;
reg [9:0]  batch_n, pair_cnt;
reg [11:0] cur_ch2;

always @(posedge sdram_clk or negedge reset_n) begin
    if(!reset_n) begin
        bstate<=B_IDLE; fifo_ren<=0; sdram_cmd_en<=0; sdram_cmd_we<=0;
        sdram_cmd_addr<=0; sdram_cmd_len<=0; sdram_wr_data<=0; sdram_wr_valid<=0;
        wr_idx<=0; batch_n<=0; pair_cnt<=0; cur_ch2<=0; drain_done<=0;
    end else begin
        sdram_cmd_en<=0; fifo_ren<=0; sdram_wr_valid<=0;
        case(bstate)
            B_IDLE: begin
                if (wr_idx<DEPTH &&
                    (fifo_fill>=BATCH || (cap_done_sd && fifo_fill>0))) begin
                    if (fifo_fill>=BATCH) batch_n<=BATCH;
                    else batch_n<=fifo_fill[9:0];
                    if (DEPTH-wr_idx<BATCH && (DEPTH-wr_idx)<fifo_fill)
                        batch_n<=DEPTH[9:0]-wr_idx[9:0];
                    pair_cnt<=0; fifo_ren<=1; bstate<=B_LOAD;
                end
            end
            B_LOAD: bstate<=B_CMD;
            B_CMD: begin
                sdram_cmd_en<=1; sdram_cmd_we<=1;
                sdram_cmd_addr<=CH_BASE+{wr_idx[22:0],1'b0};
                sdram_cmd_len<={batch_n[8:0],1'b0};
                if(sdram_cmd_en && sdram_cmd_ready) begin
                    sdram_cmd_en<=0; bstate<=B_WLO;
                end
            end
            B_WLO: if(sdram_wr_ready) begin
                sdram_wr_data<=fifo_rdata[11:0]; sdram_wr_valid<=1;
                cur_ch2<=fifo_rdata[24:13]; bstate<=B_WHI;
            end
            B_WHI: if(sdram_wr_ready) begin
                sdram_wr_data<=cur_ch2; sdram_wr_valid<=1;
                pair_cnt<=pair_cnt+1;
                if(pair_cnt+1>=batch_n) bstate<=B_FIN;
                else begin fifo_ren<=1; bstate<=B_WLO; end
            end
            B_FIN: begin
                wr_idx<=wr_idx+batch_n;
                if (wr_idx+batch_n>=DEPTH) drain_done<=1;  // останній batch
                bstate<=B_IDLE;
            end
            default: bstate<=B_IDLE;
        endcase
        if (capturing_rise) begin wr_idx<=0; drain_done<=0; end  // пріоритет
    end
end

endmodule