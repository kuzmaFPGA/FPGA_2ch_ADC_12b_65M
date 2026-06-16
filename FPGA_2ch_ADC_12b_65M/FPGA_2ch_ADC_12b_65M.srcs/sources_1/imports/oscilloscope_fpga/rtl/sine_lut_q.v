// ============================================================
// sine_lut_q.v - четверть-хвильова таблиця синусу
// 1024 entries × 13-біт: sin(0)..sin(π/2) → 0..8191
// Вчетверо менша ніж full-wave, при тій самій якості.
// Квадрантна симетрія відновлює повний синус в dds.v
// ============================================================
module sine_lut_q (
    input         clk,
    input  [9:0]  addr,       // 0..1023
    output reg [12:0] val     // 0..8191
);

(* rom_style = "block" *) reg [12:0] rom [0:1023];
initial $readmemh("sine_lut_q.mem", rom);

always @(posedge clk) val <= rom[addr];

endmodule