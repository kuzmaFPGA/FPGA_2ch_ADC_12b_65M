module lcd_write_cmd (
	input wire clk,          // Системний тактовий сигнал (8 МГц)
	input wire reset_n,      // Активний низький скид
	input wire start,        // Сигнал запуску запису
	input wire [15:0] cmd,   // 16-бітна команда
	output reg LCD_CS,       // Chip Select (активний низький)
	output reg LCD_RS,       // D/CX (0 - команда)
	output reg LCD_WR,       // WRX (write control)
	output reg LCD_RDX,      // RDX (read control)
	output reg [15:0] LCD_DATA, // Шина даних
	output reg done          // Сигнал завершення запису
);

// Регістр стану FSM
reg [2:0] wr_substate;

localparam LCD_RS_CLR = 0, LCD_RS_SET = 1, LCD_CS_CLR = 2, LCD_CS_SET = 3, LCD_WR_CLR = 4, LCD_WR_SET =5, DATAOUT =6;

always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
		wr_substate <= 0;
		LCD_CS <= 1;
		LCD_RS <= 0;
		LCD_WR <= 1;
		LCD_RDX <= 1;
		LCD_DATA <= 16'bz;
		done <= 0;
		end else begin
		case (wr_substate)
			LCD_RS_CLR: begin
				if (start) begin
					LCD_RS <= 0; // Команда
					//done <= 0;
					wr_substate <= LCD_CS_CLR;
				end
				done <= 0;
			end
			LCD_CS_CLR: begin
				LCD_CS <= 0;
				wr_substate <= DATAOUT;
			end
			DATAOUT: begin
				LCD_DATA <= cmd; // Встановлення команди
				wr_substate <= LCD_WR_CLR;
			end
			LCD_WR_CLR: begin
				LCD_WR <= 0;
				wr_substate <= LCD_WR_SET;
			end
			LCD_WR_SET: begin
			    LCD_WR <= 1;
			    wr_substate <= LCD_CS_SET;
			end
			LCD_CS_SET: begin
				LCD_CS <= 1; // деактивуємо CS після запису
				done <= 1;
				wr_substate <= LCD_RS_CLR;
			end
			default: wr_substate <= LCD_RS_CLR;
		endcase
	end
end
endmodule

module lcd_write_cmd_data (
	input wire clk,          // Системний тактовий сигнал (8 МГц)
	input wire reset_n,      // Активний низький скид
	input wire start,        // Сигнал запуску запису
	input wire [15:0] cmd,   // 16-бітна команда
	input wire [15:0] data,  // 16-бітні дані
	output reg LCD_CS,       // Chip Select (активний низький)
	output reg LCD_RS,       // D/CX (0 - команда, 1 - дані)
	output reg LCD_WR,       // WRX (write control)
	output reg LCD_RDX,      // RDX (read control)
	output reg [15:0] LCD_DATA, // Шина даних
	output reg done          // Сигнал завершення запису
);

// Регістр стану FSM
reg [3:0] state;
reg [2:0] wr_substate;

// Стани FSM
localparam IDLE = 0, CMD_WRITE = 1, DATA_WRITE = 2, DONE = 3;
localparam LCD_RS_CLR = 0, LCD_RS_SET = 1, LCD_CS_CLR = 2, LCD_CS_SET = 3, LCD_WR_CLR = 4, LCD_WR_SET =5, DATAOUT =6;

always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
		state <= IDLE;
		wr_substate <= 0;
		LCD_CS <= 1;
		LCD_RS <= 0;
		LCD_WR <= 1;
		LCD_RDX <= 1;
		LCD_DATA <= 16'bz;
		done <= 0;
		end else begin
		case (state)
			IDLE: begin
				if (start) begin
					state <= CMD_WRITE;
					wr_substate <= 0;
					//done <= 0;
				end
				done <= 0;
			end
			CMD_WRITE: begin
				case (wr_substate)
					LCD_RS_CLR: begin
						if (start) begin
							LCD_RS <= 0; // Команда
							wr_substate <= LCD_CS_CLR;
						end
					end
					LCD_CS_CLR: begin
						LCD_CS <= 0;
						wr_substate <= DATAOUT;
					end
					DATAOUT: begin
						LCD_DATA <= cmd; // Встановлення команди
						wr_substate <= LCD_WR_CLR;
					end
					LCD_WR_CLR: begin
						LCD_WR <= 0;
						wr_substate <= LCD_WR_SET;
					end
					LCD_WR_SET: begin
						LCD_WR <= 1;
						wr_substate <= LCD_CS_SET;
					end
					LCD_CS_SET: begin
						LCD_CS <= 1; // деактивуємо CS між cmd та data
						wr_substate <= LCD_RS_SET;
						state <= DATA_WRITE;
					end
					default: wr_substate <= LCD_RS_CLR;
				endcase
			end
			DATA_WRITE: begin
				case (wr_substate)
					LCD_RS_SET: begin
						if (start) begin
							LCD_RS <= 1; // data
							wr_substate <= LCD_CS_CLR;
						end
					end
					LCD_CS_CLR: begin
						LCD_CS <= 0;
						wr_substate <= DATAOUT;
					end
					DATAOUT: begin
						LCD_DATA <= data; // Встановлення data
						wr_substate <= LCD_WR_CLR;
					end
					LCD_WR_CLR: begin
						LCD_WR <= 0;
						wr_substate <= LCD_WR_SET;
					end
					LCD_WR_SET: begin
						LCD_WR <= 1;
						wr_substate <= LCD_CS_SET;
					end
					LCD_CS_SET: begin
						LCD_CS <= 1; // деактивуємо CS після запису даних
						wr_substate <= LCD_RS_CLR;
						state <= DONE;
					end
					default: wr_substate <= LCD_RS_CLR;
				endcase
				
			end
			DONE: begin
				done <= 1;
				state <= IDLE;
			end
			default: state <= IDLE;
		endcase
	end
end
endmodule

module lcd_write_cmd_ndata (
	input wire clk,          // Системний тактовий сигнал (8 МГц)
	input wire reset_n,      // Активний низький скид
	input wire start,        // Сигнал запуску запису
	input wire [15:0] cmd,   // 16-бітна команда
	input wire [15:0] data,  // 16-бітні дані (надходять послідовно)
	input wire [31:0] n,     // Кількість даних для запису
	output reg LCD_CS,       // Chip Select (активний низький)
	output reg LCD_RS,       // D/CX (0 - команда, 1 - дані)
	output reg LCD_WR,       // WRX (write control)
	output reg LCD_RDX,      // RDX (read control)
	output reg [15:0] LCD_DATA, // Шина даних
	output reg done,          // Сигнал завершення запису
    output reg [31:0] data_count   // Лічильник записаних даних	
//output reg next_data      // сигнал на зчитування наступного пікселя
	//output wire [7:0] debug
);

// plain Verilog (was typedef enum)
localparam [3:0]
    IDLE                   = 4'd0,
    SET_COMMAND            = 4'd1,
    WRITE_COMMAND_TO_LCD   = 4'd2,
    NOOP_AFTER_WRITE_COMMAND= 4'd3,
    SET_DATA               = 4'd4,
    WRITE_DATA_TO_LCD      = 4'd5,
    PAUSE                  = 4'd6,
    FILL_DONE              = 4'd7;

reg [3:0] fill_display_state;
//assign debug[3:0] = fill_display_state;


always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
		fill_display_state <= IDLE;
		data_count <= 0;
		LCD_CS <= 1;
		LCD_RS <= 0;
		LCD_WR <= 1;
		LCD_RDX <= 1;
		LCD_DATA <= 16'h0000;
		done <= 0;
		end else begin
		case (fill_display_state)
			IDLE: begin
				if (start) begin
				    LCD_CS <= 1;
		            LCD_RS <= 0;
		            LCD_WR <= 1;
		            LCD_RDX <= 1;
					fill_display_state <= SET_COMMAND;
					data_count <= 0;
					//done <= 0;
				end
				done <= 0;
			end
			SET_COMMAND: begin
                LCD_CS <= 0;
		        LCD_RS <= 0;
		        LCD_WR <= 0;
				LCD_DATA <= cmd; // Встановлення команди
				fill_display_state <= WRITE_COMMAND_TO_LCD;
			end
			WRITE_COMMAND_TO_LCD: begin
			    LCD_CS <= 0;
				LCD_RS <= 0;
		        LCD_WR <= 1;
				LCD_DATA <= cmd; // Встановлення команди
				fill_display_state <= NOOP_AFTER_WRITE_COMMAND;
			end
			NOOP_AFTER_WRITE_COMMAND: begin
				//LCD_CS <= 0;
				LCD_RS <= 1;
				LCD_WR <= 0;
				//LCD_DATA <= cmd; 
				fill_display_state <= SET_DATA;	
			end
			SET_DATA: begin
			    
				LCD_CS <= 0;
				LCD_RS <= 1;
				LCD_WR <= 0;
				LCD_DATA <= data; 
				fill_display_state <= WRITE_DATA_TO_LCD;			
			end			
			WRITE_DATA_TO_LCD: begin
				LCD_CS <= 0;
				LCD_RS <= 1;
				LCD_WR <= 1;
				LCD_DATA <= data; 
				data_count <= data_count + 1;
				if (data_count + 1 > n) begin
					fill_display_state <= PAUSE;
				end	
				else begin		
					fill_display_state <= SET_DATA;			
				end						
			end			
			PAUSE : begin
			     done <= 1;
			     data_count <= 0;
			     fill_display_state <= FILL_DONE;
			end		
			FILL_DONE: begin
				fill_display_state <= IDLE;
			end
			default: fill_display_state <= IDLE;
		endcase
	end
end
endmodule

module lcd_write_pixel (
    input clk, reset_n, start,
    input [15:0] x, y, color,
    output reg done,
    output reg [15:0] LCD_DATA,
    output reg LCD_CS, LCD_RS, LCD_WR, LCD_RDX
);
reg [3:0] state;
always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
		state <= 0;
		LCD_CS <= 1;
		LCD_RS <= 0;
		LCD_WR <= 1;
		LCD_RDX <= 1;
		LCD_DATA <= 0;
		done <= 0;
        end else begin
		case (state)
			0: begin // 0x2A00
				if (start) begin
					LCD_CS <= 0;
					LCD_RS <= 0;
					LCD_DATA <= 16'h2A00;
					LCD_WR <= 0;
					state <= 1;
				end
			end
			1: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= x >> 8;
				LCD_WR <= 0;
				state <= 2;
			end
			2: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2A01;
				LCD_WR <= 0;
				state <= 3;
			end
			3: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= x & 16'hFF;
				LCD_WR <= 0;
				state <= 4;
			end
			4: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2A02;
				LCD_WR <= 0;
				state <= 5;
			end
			5: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= x >> 8;
				LCD_WR <= 0;
				state <= 6;
			end
			6: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2A03;
				LCD_WR <= 0;
				state <= 7;
			end
			7: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= x & 16'hFF;
				LCD_WR <= 0;
				state <= 8;
			end
			8: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2B00;
				LCD_WR <= 0;
				state <= 9;
			end
			9: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= y >> 8;
				LCD_WR <= 0;
				state <= 10;
			end
			10: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2B01;
				LCD_WR <= 0;
				state <= 11;
			end
			11: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= y & 16'hFF;
				LCD_WR <= 0;
				state <= 12;
			end
			12: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2B02;
				LCD_WR <= 0;
				state <= 13;
			end
			13: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= y >> 8;
				LCD_WR <= 0;
				state <= 14;
			end
			14: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2B03;
				LCD_WR <= 0;
				state <= 15;
			end
			15: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= y & 16'hFF;
				LCD_WR <= 0;
				state <= 16;
			end
			16: begin
				LCD_WR <= 1;
				LCD_RS <= 0;
				LCD_DATA <= 16'h2C00;
				LCD_WR <= 0;
				state <= 17;
			end
			17: begin
				LCD_WR <= 1;
				LCD_RS <= 1;
				LCD_DATA <= color;
				LCD_WR <= 0;
				state <= 18;
			end
			18: begin
				LCD_WR <= 1;
				LCD_CS <= 1;
				done <= 1;
				state <= 19;
			end
			19: begin
				if (!start) begin
					done <= 0;
					state <= 0;
				end
			end
		endcase
	end
end
endmodule

module lcd_read_data (
    input clk, reset_n, start,
    output reg [15:0] data,
    output reg done,
    output reg LCD_CS, LCD_RS, LCD_WR, LCD_RDX,
    input [15:0] LCD_DATA
);
reg [2:0] state;
always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
		state <= 0;
		LCD_CS <= 1;
		LCD_RS <= 1;
		LCD_WR <= 1;
		LCD_RDX <= 1;
		done <= 0;
		data <= 0;
        end else begin
		case (state)
			0: begin
				if (start) begin
					LCD_CS <= 0;
					LCD_RS <= 1;
					state <= 1;
				end
			end
			1: begin
				LCD_RDX <= 0;
				state <= 2;
			end
			2: begin
				data <= LCD_DATA;
				state <= 3;
			end
			3: begin
				LCD_RDX <= 1;
				state <= 4;
			end
			4: begin
				LCD_CS <= 1;
				done <= 1;
				state <= 5;
			end
			5: begin
				if (!start) begin
					done <= 0;
					state <= 0;
				end
			end
		endcase
	end
end
endmodule	