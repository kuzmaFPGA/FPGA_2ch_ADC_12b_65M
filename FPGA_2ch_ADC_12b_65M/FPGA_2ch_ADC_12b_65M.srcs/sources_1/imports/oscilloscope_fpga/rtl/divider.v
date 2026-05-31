// Послідовний беззнаковий дільник (restoring division)
module divider #(parameter W=40) (
    input              clk, reset_n, start,
    input  [W-1:0]     dividend, divisor,
    output reg [W-1:0] quotient,
    output reg         done, busy
);
    reg [2*W-1:0] acc;
    reg [W-1:0]   divr;
    reg [6:0]     cnt;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acc<=0; divr<=0; cnt<=0; quotient<=0; done<=0; busy<=0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                if (divisor==0) begin quotient<=0; done<=1; busy<=0; end
                else begin
                    acc  <= {{W{1'b0}}, dividend};
                    divr <= divisor; cnt <= W[6:0]; busy <= 1;
                end
            end else if (busy) begin
                if (acc[2*W-2:W-1] >= divr) begin
                    acc <= {(acc[2*W-2:W-1]-divr), acc[W-2:0], 1'b1};
                end else begin
                    acc <= {acc[2*W-2:0], 1'b0};
                end
                cnt <= cnt - 1;
                if (cnt==1) begin
                    busy<=0; done<=1;
                    quotient <= (acc[2*W-2:W-1] >= divr) ?
                        {acc[W-2:0],1'b1} : {acc[W-2:0],1'b0};
                end
            end
        end
    end
endmodule
