// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// Pin mapping (counter-clockwise from bottom-left):
//
//   clk         ← sys_clk  (Pin2,  via clk_PAD)
//   rst_n       ← rst      (Pin1,  via rst_n_PAD, active-low)
//
//   input_in[0] ← uart_clk (Pin3,  not connected to main_core)
//   input_in[1] ← uart_rx  (Pin5,  not connected to main_core)
//   input_in[2] ← spi_miso (Pin15, → main_core.spi_miso)
//
//   output_out[0]  → user_io_0    (Pin4,  ← uart_clk / input_in[0])
//   output_out[1]  → uart_tx      (Pin6,  ← uart_rx  / input_in[1])
//   output_out[2]  → user_io_1    (Pin7,  driven 0)
//   output_out[3]  → user_io_2    (Pin8,  driven 0)
//   output_out[4]  → user_io_3    (Pin9,  driven 0)
//   output_out[5]  → user_io_4    (Pin10, driven 0)
//   output_out[6]  → cs_1         (Pin13, ← main_core.spi_cs_1 / AT25010 EEPROM)
//   output_out[7]  → cs_2         (Pin14, ← main_core.spi_cs_0 / MFRC522)
//   output_out[8]  → spi_mosi     (Pin16, ← main_core.spi_mosi)
//   output_out[9]  → spi_sclk     (Pin17, ← main_core.spi_sclk)
//   output_out[10] → status_unlock(Pin20, ← main_core.status_unlock)
//   output_out[11] → status_fault (Pin21, ← main_core.status_fault)
//   output_out[12] → status_busy  (Pin22, ← main_core.status_busy)

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_OUTPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    input  logic clk,    // sys_clk (Pin2)
    input  logic rst_n,  // rst, active-low (Pin1)

    input  wire [NUM_INPUT_PADS-1 :0] input_in,   // [0]=uart_clk, [1]=uart_rx, [2]=spi_miso
    output wire [NUM_OUTPUT_PADS-1:0] output_out  // see pin mapping above
);

    // Internal wires to/from main_core
    wire spi_sclk;
    wire spi_cs_0;   // MFRC522   → cs_2 (Pin14)
    wire spi_cs_1;   // AT25010   → cs_1 (Pin13)
    wire spi_mosi;
    wire status_unlock;
    wire status_fault;
    wire status_busy;

    // Route unused inputs to output pads to avoid floating nets / antenna violations
    assign output_out[0] = input_in[0]; // uart_clk → user_io_0 (Pin4)
    assign output_out[1] = input_in[1]; // uart_rx  → uart_tx   (Pin6)
    assign output_out[2] = 1'b0; // user_io_1 (Pin7)
    assign output_out[3] = 1'b0; // user_io_2 (Pin8)
    assign output_out[4] = 1'b0; // user_io_3 (Pin9)
    assign output_out[5] = 1'b0; // user_io_4 (Pin10)

    // main_core outputs
    assign output_out[6]  = spi_cs_1;      // cs_1         (Pin13)
    assign output_out[7]  = spi_cs_0;      // cs_2         (Pin14)
    assign output_out[8]  = spi_mosi;      // spi_mosi     (Pin16)
    assign output_out[9]  = spi_sclk;      // spi_sclk     (Pin17)
    assign output_out[10] = status_unlock; // status_unlock(Pin20)
    assign output_out[11] = status_fault;  // status_fault (Pin21)
    assign output_out[12] = status_busy;   // status_busy  (Pin22)

    main_core i_main_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .spi_sclk     (spi_sclk),
        .spi_cs_0     (spi_cs_0),
        .spi_cs_1     (spi_cs_1),
        .spi_mosi     (spi_mosi),
        .spi_miso     (input_in[2]),   // spi_miso (Pin15)
        .status_unlock(status_unlock),
        .status_fault (status_fault),
        .status_busy  (status_busy)
    );

endmodule

`default_nettype wire
