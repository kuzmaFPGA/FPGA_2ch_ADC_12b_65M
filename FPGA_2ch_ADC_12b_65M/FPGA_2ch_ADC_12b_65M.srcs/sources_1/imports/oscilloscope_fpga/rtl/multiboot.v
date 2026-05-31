// ============================================================
// multiboot.v - MultiBoot для Xilinx Artix-7
//
// Дозволяє перемикатися між прошивками збереженими у SPI Flash.
// Рекомендована схема Flash-пам'яті:
//
//   Адреса 0x000000 - "Golden" bitstream (DDS, резервний)
//   Адреса 0x200000 - Proshivka 2 (Logic Analyzer)
//   Адреса 0x400000 - Proshivka 3 (Oscilloscope)
//   Адреса 0x7FF000 - User data (частоти)
//
// Для XC7A35T bitstream ~ 1.7 MB → 0x200000 = 2 MB (безпечно).
//
// Використання:
//   1. Запрограмувати всі прошивки в flash через Vivado
//      (Create MCS → multiple bitstreams)
//   2. Встановити trigger та target_addr на 1 такт
//   3. FPGA перезавантажиться з вказаної адреси
//
// ПРИМІТКА: trigger повинен підтримуватися МІНІМУМ 1 такт.
//           Після trigger FPGA перестає виконувати код (reconfig).
// ============================================================
module multiboot (
    input         clk,
    input         trigger,       // 1-cycle pulse → переключити прошивку
    input  [23:0] target_addr   // адреса bitstream у SPI Flash
);

// ICAP_ARTIX7 - Internal Configuration Access Port
// Дозволяє надсилати конфігураційні команди FPGA з user logic
localparam SYNC_WORD = 32'hAA995566;  // Sync word для config stream
localparam IPROG_CMD = 32'h0000000F;  // Type 1 NOP + IPROG command

// Послідовність IPROG:
// 1. Sync word
// 2. Type 1 write 1 to WBSTAR (Warm Boot Start Address)
// 3. WBSTAR address
// 4. Type 1 write 1 to CMD
// 5. IPROG command
// 6. NOP

wire [31:0] WBSTAR_REG = {target_addr, 8'h00};  // warm boot start address

// FSM для надсилання послідовності через ICAP
reg [3:0]  icap_state;
reg [31:0] icap_data;
reg        icap_csib;  // chip select (active low)
reg        icap_rdwrb; // 0 = write
reg        trigger_r;

wire [31:0] icap_out;

// ICAP_ARTIX7: 32-bit wide, байт-реверс для правильного порядку
// Artix-7 ICAP потребує реверсування байтів в кожному word
function [31:0] byte_rev;
    input [31:0] din;
    begin
        byte_rev = {din[7:0], din[15:8], din[23:16], din[31:24]};
    end
endfunction

// ICAPE2 - Internal Configuration Access Port (Vivado / 7-series)
// ICAP_ARTIX7 - застаріла назва для ISE/XST, у Vivado не підтримується
ICAPE2 #(
    .DEVICE_ID   (32'h0362D093),  // XC7A35T JTAG IDCODE (тільки для симуляції)
    .ICAP_WIDTH  ("X32"),
    .SIM_CFG_FILE_NAME ("NONE")
) icap_inst (
    .I     (icap_data),   // 32-bit config data in
    .CLK   (clk),
    .CSIB  (icap_csib),   // Active-Low chip enable (0 = enabled)
    .RDWRB (icap_rdwrb),  // 0 = write, 1 = read
    .O     (icap_out)     // readback (не використовуємо)
);

// Послідовність команд (7 word-ів)
reg [31:0] cmd_seq [0:6];
reg [2:0]  seq_idx;

initial begin
    // Заповнимо під час тригера
    cmd_seq[0] = byte_rev(32'hFFFF_FFFF); // Dummy word
    cmd_seq[1] = byte_rev(32'hAA99_5566); // Sync word
    cmd_seq[2] = byte_rev(32'h3261_0001); // Type 1, write 1 to WBSTAR (reg=0x10)
    cmd_seq[3] = byte_rev(32'h0000_0000); // WBSTAR = target_addr (задається при trigger)
    cmd_seq[4] = byte_rev(32'h3000_8001); // Type 1, write 1 to CMD
    cmd_seq[5] = byte_rev(32'h0000_000F); // CMD = IPROG
    cmd_seq[6] = byte_rev(32'h2000_0000); // NOP
end

always @(posedge clk) begin
    trigger_r <= trigger;

    case (icap_state)
        4'd0: begin  // IDLE
            icap_csib  <= 1;
            icap_rdwrb <= 1;
            icap_data  <= 32'hFFFF_FFFF;
            seq_idx    <= 0;
            if (trigger && !trigger_r) begin
                // Оновлюємо адресу в послідовності
                cmd_seq[3] <= byte_rev({8'd0, target_addr});
                icap_state <= 4'd1;
            end
        end
        4'd1: begin  // Відкриваємо ICAP
            icap_csib  <= 0;
            icap_rdwrb <= 0;
            icap_data  <= cmd_seq[0];
            seq_idx    <= 1;
            icap_state <= 4'd2;
        end
        4'd2: begin  // Надсилаємо команди
            icap_data <= cmd_seq[seq_idx];
            seq_idx   <= seq_idx + 1;
            if (seq_idx == 3'd6) icap_state <= 4'd3;
        end
        4'd3: begin  // Очікуємо - FPGA перезавантажиться
            icap_csib <= 1;
            icap_state <= 4'd3;  // Зависаємо, reconfig відбудеться
        end
        default: icap_state <= 4'd0;
    endcase
end

endmodule