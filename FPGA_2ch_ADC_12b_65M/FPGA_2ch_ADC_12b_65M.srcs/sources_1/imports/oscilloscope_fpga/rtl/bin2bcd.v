// Double-dabble: bin → BCD (DIGITS цифр)
module bin2bcd #(parameter IN_W=27, parameter DIGITS=8) (
    input                   clk, reset_n, start,
    input  [IN_W-1:0]       bin,
    output reg [4*DIGITS-1:0] bcd,
    output reg              done, busy
);
    reg [4*DIGITS-1:0] bcd_r;
    reg [IN_W-1:0]     sh;
    reg [6:0]          cnt;
    integer d;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bcd<=0; bcd_r<=0; sh<=0; cnt<=0; done<=0; busy<=0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                bcd_r<=0; sh<=bin; cnt<=IN_W[6:0]; busy<=1;
            end else if (busy) begin
                // add-3 до кожної цифри >=5
                for (d=0; d<DIGITS; d=d+1)
                    if (bcd_r[4*d +: 4] >= 5)
                        bcd_r[4*d +: 4] = bcd_r[4*d +: 4] + 3;
                // зсув вліво з внесенням MSB sh
                bcd_r = {bcd_r[4*DIGITS-2:0], sh[IN_W-1]};
                sh    = {sh[IN_W-2:0], 1'b0};
                cnt   <= cnt - 1;
                if (cnt==1) begin busy<=0; done<=1; bcd<=bcd_r; end
            end
        end
    end
endmodule
