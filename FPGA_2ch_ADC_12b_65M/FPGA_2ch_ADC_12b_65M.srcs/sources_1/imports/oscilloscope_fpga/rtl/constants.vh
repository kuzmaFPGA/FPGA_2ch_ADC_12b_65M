`ifndef CONSTANTS_V
`define CONSTANTS_V

// Частота LCD (у кГц)
parameter LCD_FREQ_KHZ = 50000;//62500;
parameter SYS_CLK_FREQ_MHZ = 50; // Частота системного годинника у МГц
parameter SYS_CLK_FREQ_KHZ = 50000;
parameter MAIN_CLK_FREQ_KHZ = 50000;  // тепер єдиний sys_clk = 50 МГц

// Максимальні частоти (в одиницях 0.01 Гц = centihz, cHz).
// DAC904: -3dB @ 40 МГц, max sine = 55 МГц @ 165 MSPS.
//   SINE     — 40.000000 МГц → 4_000_000_000 cHz
//   SQUARE   — 10.000000 МГц → 1_000_000_000 cHz  (фільтр обрізає вище 40 МГц)
//   TRIANGLE — 20.000000 МГц → 2_000_000_000 cHz
//   PWM      — 20.000000 кГц →         2_000_000 cHz (8250 тактів → 0.012% duty)
//
// phase_inc = freq_cHz × K_CHZ >> 16
// K_CHZ = round(2^48 / (165_000_000 × 100)) = 17059
// Мінімальний крок DDS = 165e6/2^32 = 38.4 мГц = 3.84 cHz
parameter MAX_FREQ_SINE_CHZ     = 32'd4_000_000_000;
parameter MAX_FREQ_SQUARE_CHZ   = 32'd1_000_000_000;
parameter MAX_FREQ_TRIANGLE_CHZ = 32'd2_000_000_000;
parameter MAX_FREQ_PWM_CHZ      = 32'd2_000_000;
parameter K_CHZ                 = 32'd17_059;

`ifdef XILINX_SIMULATOR
    localparam DELAY_1S = 10000;          // Short delay for simulation (e.g., 10 cycles)
    localparam DELAY_TRIGGER = 10;      // Even shorter for quick triggering in sim
    localparam DELAY_50_MS = 50;        
    localparam DELAY_100_MS = 100;      
    localparam DELAY_120_MS = 120;
    localparam TEXT_WIDTH = 4;
    localparam TEXT_HEIGH = 4;
`else
    localparam DELAY_1S = 1000 * LCD_FREQ_KHZ;  // Real 1-second delay based on clock freq
    localparam DELAY_TRIGGER = 10;     // Real short delay (adjust as needed)
    localparam DELAY_50_MS = 50 * LCD_FREQ_KHZ;        
    localparam DELAY_100_MS = 100 * LCD_FREQ_KHZ;      
    localparam DELAY_120_MS = 120 * LCD_FREQ_KHZ; 
    localparam TEXT_WIDTH = 64;
    localparam TEXT_HEIGH = 128;
`endif

// Константи кольорів (RGB565)
parameter WHITE = 16'hFFFF;
parameter BLACK = 16'h0000; 
parameter BLUE = 16'h001F; 
parameter BRED = 16'hF81F;
parameter GRED = 16'hFFE0;
parameter GBLUE = 16'h07FF;
parameter RED = 16'hF800;
parameter MAGENTA = 16'hF81F;
parameter GREEN = 16'h07E0;
parameter CYAN = 16'h7FFF;
parameter YELLOW = 16'hFFE0;
parameter BROWN = 16'hBC40; 
parameter BRRED = 16'hFC07;
parameter GRAY = 16'h8430; 
parameter DARKBLUE = 16'b1010101010101010;	
parameter LIGHTBLUE = 16'h7D7C; 
parameter GRAYBLUE = 16'h5458; 
parameter LIGHTGREEN = 16'h841F; 
parameter LIGHTGRAY = 16'hEF5B; 
parameter LGRAY = 16'hC618; 
parameter LGRAYBLUE = 16'hA651; 
parameter LBBLUE = 16'h2B12;

// Загальна кількість пікселів для 800x480 дисплея
parameter TOTAL_PIXELS = 800 * 480;

// Координати для області заповнення
parameter X_START = 0;
parameter X_end = 480 - 1;
parameter Y_START = 0;
parameter Y_end = 800 - 1;

// Стани основної машини стану (plain Verilog, was typedef enum)
localparam [4:0]
    S_INIT          = 5'd0,
    S_RESET_LOW     = 5'd1,
    S_RESET_HIGH    = 5'd2,
    S_ROM_INIT      = 5'd3,
    S_SOFT_RESET    = 5'd4,
    S_DELAY         = 5'd5,
    S_SET_DIR       = 5'd6,
    S_FILL          = 5'd7,
    S_BACKLIGHT     = 5'd8,
    S_IDLE          = 5'd9,
    S_SET_XSTART_H  = 5'd10,
    S_SET_XSTART_L  = 5'd11,
    S_SET_XEND_H    = 5'd12,
    S_SET_XEND_L    = 5'd13,
    S_SET_YSTART_H  = 5'd14,
    S_SET_YSTART_L  = 5'd15,
    S_SET_YEND_H    = 5'd16,
    S_SET_YEND_L    = 5'd17,
    S_DISPLAY_ON    = 5'd18,
    S_SET_ADDR      = 5'd19,
    S_PREP_FILL     = 5'd20,
    S_FILL_PIXELS   = 5'd21,
    S_PAUSE         = 5'd22;


// Типи writer (plain Verilog, was typedef enum)
localparam [2:0]
    WRITER_NONE     = 3'd0,
    WRITER_CMD      = 3'd1,
    WRITER_CMD_DATA = 3'd3,
    WRITER_CMD_NDATA= 3'd4,
    WRITER_READ     = 3'd5;

`endif