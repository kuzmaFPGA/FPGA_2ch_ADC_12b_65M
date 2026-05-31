`include "constants.vh"

module lcd (
    input            clk,        // System clock
    input            reset_n,    // Active-low reset
    input     [15:0] fill_color, // Pixel data from BRAM (RGB565)
    input     [15:0] x_start,    // Window x start coordinate
    input     [15:0] x_end,      // Window x end coordinate
    input     [15:0] y_start,    // Window y start coordinate
    input     [15:0] y_end,      // Window y end coordinate
    input            update_screen, // Trigger to update screen
    output    [15:0] LCD_DATA,   // LCD data bus
    output           LCD_WR,     // WRX (write control)
    output           LCD_RS,     // D/CX (0 - command, 1 - data)
    output           LCD_CS,     // CSX (active low)
    output           LCD_RESET,  // LCD reset (active low)
    output           LCD_BL,     // Backlight
    output           LCD_RDX,    // RDX (read control)
    output           start_read_data,
    input            lcd_clk,  // тактовий вхід (з clk_wiz_1 в top_module)
    output    [4:0]  lcd_state,
    output           init_done,
    output           cmd_done,
    output           cmd_data_done,
    output           cmd_ndata_done,
    output    [31:0] lcd_data_count
);

// Output registers
reg    [15:0] LCD_DATA_reg;
reg           LCD_WR_reg;
reg           LCD_RS_reg;
reg           LCD_CS_reg;
reg           LCD_RESET_reg;
reg           LCD_BL_reg;
reg           LCD_RDX_reg;
reg           start_read_data_reg;
reg           lcd_ready_reg;

assign LCD_DATA = LCD_DATA_reg;
assign LCD_WR = LCD_WR_reg;
assign LCD_RS = LCD_RS_reg;
assign LCD_CS = LCD_CS_reg;
assign LCD_RESET = LCD_RESET_reg;
assign LCD_BL = LCD_BL_reg;
assign LCD_RDX = LCD_RDX_reg;
assign start_read_data = start_read_data_reg;
reg init_done_reg;
assign init_done = init_done_reg;

// Initialization ROM
reg [15:0] init_rom [0:779];
initial $readmemh("init.mem", init_rom);
reg [9:0] init_rom_addr;

// Data and type for writing
reg [15:0] cmd_data;
reg [15:0] write_data;

// State machine
reg [4:0] state;

// Delay counter
reg [31:0] delay_counter;

// Control signals
reg cmd_start;
reg cmd_data_start;
reg cmd_ndata_start;
wire next_data;

// Multiplexer signals
wire [15:0] cmd_LCD_DATA, cmd_data_LCD_DATA, cmd_ndata_LCD_DATA, cmd_read_LCD_DATA;
wire cmd_LCD_CS, cmd_data_LCD_CS, cmd_ndata_LCD_CS, cmd_read_LCD_CS;
wire cmd_LCD_RS, cmd_data_LCD_RS, cmd_ndata_LCD_RS, cmd_read_LCD_RS;
wire cmd_LCD_WR, cmd_data_LCD_WR, cmd_ndata_LCD_WR, cmd_read_LCD_WR;
wire cmd_LCD_RDX, cmd_data_LCD_RDX, cmd_ndata_LCD_RDX, cmd_read_LCD_RDX;

// Active writer
reg [2:0] active_writer;

// Pixel counter
reg [31:0] total_pixels;
reg [31:0] pixel_count;
reg [31:0] data_count;
// Refresh timer for 60 Hz
//reg [31:0] refresh_timer;
//reg internal_update;
//localparam REFRESH_TICKS = (SYS_CLK_FREQ_MHZ * 1000000) / 60;

//always @(posedge clk or negedge reset_n) begin
//    if (!reset_n) begin
//        refresh_timer <= 0;
//        internal_update <= 0;
//    end else if (init_done) begin
//        if (refresh_timer < REFRESH_TICKS - 1) begin
//            refresh_timer <= refresh_timer + 1;
//            internal_update <= 0;
//        end else begin
//            refresh_timer <= 0;
//            internal_update <= 1;
//        end
//    end else begin
//        refresh_timer <= 0;
//        internal_update <= 0;
//    end
//end

// Writers
lcd_write_cmd cmd_writer (
    .clk(lcd_clk),
    .reset_n(reset_n),
    .start(cmd_start),
    .cmd(cmd_data),
    .LCD_CS(cmd_LCD_CS),
    .LCD_RS(cmd_LCD_RS),
    .LCD_WR(cmd_LCD_WR),
    .LCD_RDX(cmd_LCD_RDX),
    .LCD_DATA(cmd_LCD_DATA),
    .done(cmd_done)
);

lcd_write_cmd_data cmd_data_writer (
    .clk(lcd_clk),
    .reset_n(reset_n),
    .start(cmd_data_start),
    .cmd(cmd_data),
    .data(write_data),
    .LCD_CS(cmd_data_LCD_CS),
    .LCD_RS(cmd_data_LCD_RS),
    .LCD_WR(cmd_data_LCD_WR),
    .LCD_RDX(cmd_data_LCD_RDX),
    .LCD_DATA(cmd_data_LCD_DATA),
    .done(cmd_data_done)
);

lcd_write_cmd_ndata cmd_ndata_writer (
    .clk(lcd_clk),
    .reset_n(reset_n),
    .start(cmd_ndata_start),
    .cmd(16'h2C00),
    .data(fill_color), // Використовуємо pixel_data з BRAM
    .n(total_pixels), // Кількість пікселів для одного запису
    .LCD_CS(cmd_ndata_LCD_CS),
    .LCD_RS(cmd_ndata_LCD_RS),
    .LCD_WR(cmd_ndata_LCD_WR),
    .LCD_RDX(cmd_ndata_LCD_RDX),
    .LCD_DATA(cmd_ndata_LCD_DATA),
    .done(cmd_ndata_done),
    .data_count(data_count)
);

assign lcd_data_count = data_count;
reg read_start;
wire read_done;
wire [15:0] read_data;
reg [15:0] lcd_id;

lcd_read_data read_writer (
    .clk(lcd_clk),
    .reset_n(reset_n),
    .start(read_start),
    .data(read_data),
    .done(read_done),
    .LCD_CS(cmd_read_LCD_CS),
    .LCD_RS(cmd_read_LCD_RS),
    .LCD_WR(cmd_read_LCD_WR),
    .LCD_RDX(cmd_read_LCD_RDX),
    .LCD_DATA(LCD_DATA)
);

// Multiplexer
always @(*) begin
    case (active_writer)
        WRITER_NONE: begin
            LCD_CS_reg = 1;
            LCD_RS_reg = 0;
            LCD_WR_reg = 1;
            LCD_RDX_reg = 1;
            LCD_DATA_reg = 16'h0000;
        end
        WRITER_CMD: begin
            LCD_CS_reg = cmd_LCD_CS;
            LCD_RS_reg = cmd_LCD_RS;
            LCD_WR_reg = cmd_LCD_WR;
            LCD_RDX_reg = cmd_LCD_RDX;
            LCD_DATA_reg = cmd_LCD_DATA;
        end
        WRITER_CMD_DATA: begin
            LCD_CS_reg = cmd_data_LCD_CS;
            LCD_RS_reg = cmd_data_LCD_RS;
            LCD_WR_reg = cmd_data_LCD_WR;
            LCD_RDX_reg = cmd_data_LCD_RDX;
            LCD_DATA_reg = cmd_data_LCD_DATA;
        end
        WRITER_CMD_NDATA: begin
            LCD_CS_reg = cmd_ndata_LCD_CS;
            LCD_RS_reg = cmd_ndata_LCD_RS;
            LCD_WR_reg = cmd_ndata_LCD_WR;
            LCD_RDX_reg = cmd_ndata_LCD_RDX;
            LCD_DATA_reg = cmd_ndata_LCD_DATA;
        end
        WRITER_READ: begin
            LCD_CS_reg = cmd_read_LCD_CS;
            LCD_RS_reg = cmd_read_LCD_RS;
            LCD_WR_reg = cmd_read_LCD_WR;
            LCD_RDX_reg = cmd_read_LCD_RDX;
            LCD_DATA_reg = 16'hZZZZ;
        end
        default: begin
            LCD_CS_reg = 1;
            LCD_RS_reg = 0;
            LCD_WR_reg = 1;
            LCD_RDX_reg = 1;
            LCD_DATA_reg = 16'hzzzz;
        end
    endcase
end

// FSM
always @(posedge lcd_clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= S_INIT;
        total_pixels <= 0;
        pixel_count <= 1;
        LCD_RESET_reg <= 0;
        LCD_BL_reg <= 0;
        init_rom_addr <= 0;
        delay_counter <= 0;
        cmd_start <= 0;
        cmd_data_start <= 0;
        cmd_ndata_start <= 0;
        active_writer <= WRITER_NONE;
        cmd_data <= 0;
        write_data <= 0;
        init_done_reg <= 0;
        
    end else begin
        case (state)
            S_INIT: begin
                LCD_RESET_reg <= 0;
                init_rom_addr <= 0;
                delay_counter <= DELAY_100_MS;
                state <= S_RESET_LOW;
                init_done_reg <= 0;
            end
            S_RESET_LOW: begin
                if (delay_counter > 0) begin
                    delay_counter <= delay_counter - 1;
                end else begin
                    LCD_RESET_reg <= 1;
                    delay_counter <= DELAY_50_MS;
                    state <= S_RESET_HIGH;
                end
            end
            S_RESET_HIGH: begin
                if (delay_counter > 0) begin
                    delay_counter <= delay_counter - 1;
                end else begin
                    state <= S_ROM_INIT;
                end
            end
            S_ROM_INIT: begin
                if (init_rom_addr <= 778) begin
                    if (!cmd_data_start) begin
                        cmd_data <= init_rom[init_rom_addr];
                        write_data <= init_rom[init_rom_addr + 1];
                        active_writer <= WRITER_CMD_DATA;
                        cmd_data_start <= 1;
                    end else if (cmd_data_done) begin
                        cmd_data_start <= 0;
                        active_writer <= WRITER_NONE;
                        init_rom_addr <= init_rom_addr + 2;
                    end
                end else begin
                    state <= S_SOFT_RESET;
                end
            end
            S_SOFT_RESET: begin
                if (!cmd_start) begin
                    cmd_data <= 16'h1100;
                    active_writer <= WRITER_CMD;
                    cmd_start <= 1;
                end else if (cmd_done) begin
                    cmd_start <= 0;
                    active_writer <= WRITER_NONE;
                    delay_counter <= DELAY_120_MS;
                    state <= S_DELAY;
                end
            end
            S_DELAY: begin
                if (delay_counter > 0) begin
                    delay_counter <= delay_counter - 1;
                end else begin
                    state <= S_SET_DIR;
                end
            end
            S_SET_DIR: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h3600;
                    write_data <= (1<<5)|(1<<6);//16'h00;
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_FILL;
                end
            end
            S_FILL: begin
                // Сигналізуємо top_module що LCD готовий приймати команди
                init_done_reg <= 1;
                if (update_screen) begin
                    total_pixels <= ((x_end - x_start + 1) * (y_end - y_start + 1));
                    pixel_count <= 1;
                    state <= S_SET_XSTART_H;
                end
            end
            S_SET_XSTART_H: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2A00;
                    write_data <= (x_start >> 8);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_XSTART_L;
                end
            end
            S_SET_XSTART_L: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2A01;
                    write_data <= (x_start & 16'hFF);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_XEND_H;
                end
            end
            S_SET_XEND_H: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2A02;
                    write_data <= (x_end >> 8);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_XEND_L;
                end
            end
            S_SET_XEND_L: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2A03;
                    write_data <= (x_end & 16'hFF);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_YSTART_H;
                end
            end
            S_SET_YSTART_H: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2B00;
                    write_data <= (y_start >> 8);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_YSTART_L;
                end
            end
            S_SET_YSTART_L: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2B01;
                    write_data <= (y_start & 16'hFF);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_YEND_H;
                end
            end
            S_SET_YEND_H: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2B02;
                    write_data <= (y_end >> 8);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_SET_YEND_L;
                end
            end
            S_SET_YEND_L: begin
                if (!cmd_data_start) begin
                    cmd_data <= 16'h2B03;
                    write_data <= (y_end & 16'hFF);
                    active_writer <= WRITER_CMD_DATA;
                    cmd_data_start <= 1;
                end else if (cmd_data_done) begin
                    cmd_data_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_DISPLAY_ON;
                end
            end
            S_DISPLAY_ON: begin
                if (!cmd_start) begin
                    cmd_data <= 16'h2900;
                    active_writer <= WRITER_CMD;
                    cmd_start <= 1;
                end else if (cmd_done) begin
                    cmd_start <= 0;
                    active_writer <= WRITER_NONE;
                    state <= S_PREP_FILL;
                end
            end
            S_PREP_FILL: begin
                state <= S_FILL_PIXELS;
                cmd_ndata_start <= 0;
                start_read_data_reg <= 1;
            end
            S_FILL_PIXELS: begin
                // Запускаємо cmd_ndata_writer один раз — він сам пише всі total_pixels
                if (!cmd_ndata_start && !cmd_ndata_done) begin
                    active_writer   <= WRITER_CMD_NDATA;
                    cmd_ndata_start <= 1;
                end else if (cmd_ndata_done) begin
                    cmd_ndata_start     <= 0;
                    active_writer       <= WRITER_NONE;
                    start_read_data_reg <= 0;
                    state               <= S_BACKLIGHT;
                end
            end
            S_BACKLIGHT: begin
                LCD_BL_reg <= 1;
                state <= S_FILL;
            end
            default: state <= S_INIT;
        endcase
    end
end
endmodule