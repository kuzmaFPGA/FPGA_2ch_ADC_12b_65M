module clk_wiz_1(input clk_in1,resetn,output clk_out1,clk_out2,clk_out3,clk_out4,output locked);
  assign clk_out1=clk_in1; assign clk_out2=clk_in1; assign clk_out3=clk_in1;
  assign clk_out4=clk_in1; assign locked=1'b1;
endmodule
module KeyPadInterpreter(
  input Clock, ResetButton, KeyRead,
  input [3:0] RowDataIn,
  output reg KeyReady, output reg [3:0] DataOut,
  output [3:0] ColDataOut, output PressCount);
  assign ColDataOut=4'hF; endmodule
module lcd(input clk,reset_n,input[15:0]fill_color,x_start,x_end,y_start,y_end,
  input update_screen,output[15:0]LCD_DATA,output LCD_WR,LCD_RS,LCD_CS,LCD_RESET,LCD_BL,LCD_RDX,
  input start_read_data,output cmd_done,cmd_data_done,cmd_ndata_done,input lcd_clk,
  output[7:0]lcd_state,output init_done,output[31:0]lcd_data_count);
  assign LCD_DATA=16'd0; assign {LCD_WR,LCD_RS,LCD_CS,LCD_RESET,LCD_BL,LCD_RDX}=6'd0;
  assign cmd_done=1'b0; assign cmd_data_done=1'b0; assign cmd_ndata_done=1'b1;
  assign lcd_state=8'd0; assign init_done=1'b1; assign lcd_data_count=32'd0;
endmodule
module multiboot(input clk,trigger,input[23:0]target_addr); endmodule
module ODDR #(parameter DDR_CLK_EDGE="",INIT=0,SRTYPE="")(output Q,input C,CE,D1,D2,R,S);
  assign Q=C; endmodule
module clk_wiz_0(input clk_in1,output clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,output locked);
  assign clk_out1=clk_in1;assign clk_out2=clk_in1;
  assign clk_out3=clk_in1;assign clk_out4=clk_in1;assign clk_out5=clk_in1;assign locked=1;
endmodule
