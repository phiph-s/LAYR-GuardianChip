// AT25010 write/read FPGA test top for ULX3S
module at25010_write_test_top (
    input  wire       clk_25mhz,
    input  wire [6:0] btn,

    // Shared SPI bus
    output wire       spi_sclk,
    output wire       spi_cs_0,   // MFRC522 (unused)
    output wire       spi_cs_1,   // AT25010
    output wire       spi_mosi,
    input  wire       spi_miso,

    // misc IO
    output wire       uart_txd,
    input  wire       uart_rxd,
    output wire       mode,

    // status
    output wire       busy,
    output wire       hard_fault,
    output wire       unlock,

    output wire [7:0] led
);

    wire rst = btn[1];  // FIRE1 as reset (active high)

    // ------------------------------------------------------------------------
    // PLL: 25 MHz -> 32 MHz
    // ------------------------------------------------------------------------
    wire clk_32mhz;
    wire pll_lock;

    EHXPLLL #(
        .PLLRST_ENA("ENABLED"),
        .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"),
        .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"),
        .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"),
        .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(25),
        .CLKFB_DIV(32),
        .CLKOP_DIV(1),
        .CLKOP_ENABLE("ENABLED"),
        .CLKOP_CPHASE(0),
        .CLKOP_FPHASE(0)
    ) pll_i (
        .CLKI(clk_25mhz),
        .CLKFB(clk_32mhz),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b0), .PHASESTEP(1'b0), .PHASELOADREG(1'b0),
        .STDBY(1'b0),
        .PLLWAKESYNC(1'b0),
        .RST(rst),
        .ENCLKOP(1'b1), .ENCLKOS(1'b0), .ENCLKOS2(1'b0), .ENCLKOS3(1'b0),
        .CLKOP(clk_32mhz),
        .CLKOS(), .CLKOS2(), .CLKOS3(),
        .LOCK(pll_lock)
    );

    // ------------------------------------------------------------------------
    // Shared SPI master (Mode 0)
    // ------------------------------------------------------------------------
    wire       spi_xfer_active;
    wire       spi_xfer_done;
    wire [7:0] spi_rx_byte;

    wire       spi_start_xfer;
    wire [7:0] spi_tx_byte;

    spi_master #(
        .CLK_HZ(32_000_000),
        .SPI_HZ(4_000_000)
    ) u_spi (
        .clk(clk_32mhz),
        .rst(rst | ~pll_lock),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .start_xfer(spi_start_xfer),
        .tx_byte(spi_tx_byte),
        .xfer_active(spi_xfer_active),
        .xfer_done(spi_xfer_done),
        .rx_byte(spi_rx_byte)
    );

    // ------------------------------------------------------------------------
    // Button edge detection for write/read
    // ------------------------------------------------------------------------
    reg btn_write_d = 1'b0;
    reg btn_read_d  = 1'b0;

    always @(posedge clk_32mhz) begin
        btn_write_d <= btn[2]; // FIRE2
        btn_read_d  <= btn[3]; // UP
    end

    wire write_pulse = btn[2] & ~btn_write_d;
    wire read_pulse  = btn[3] & ~btn_read_d;

    // ------------------------------------------------------------------------
    // Fixed debug key + allowed IDs to write
    // ------------------------------------------------------------------------
    localparam [127:0] DEBUG_KEY = 128'h00112233445566778899AABBCCDDEEFF;
    localparam [127:0] ID_1 = 128'h00000000000000000000000000000001;
    localparam [127:0] ID_2 = 128'h28d7c47f5bd16c9814a142aa4ba28823;
    localparam [127:0] ID_3 = 128'hd0d23f18251c6087566de7b7deab7774;
    localparam [127:0] ID_4 = 128'hbbe8278a67f960605adafd6f63cf7ba7;
    localparam [127:0] ID_5 = 128'h7a8404068420c249c8ae65ea499bd9f7;
    localparam [127:0] ID_6 = 128'haa46f7689a200a24327aefdcf3a03a40;
    localparam [767:0] DEBUG_IDS = {ID_1, ID_2, ID_3, ID_4, ID_5, ID_6};

    // ------------------------------------------------------------------------
    // AT25010 interface
    // ------------------------------------------------------------------------
    wire [127:0] key;
    wire key_valid;
    wire [63:0] counter;
    wire counter_valid;
    wire [767:0] ids;
    wire ids_valid;
    wire eeprom_busy;
    wire read_done;
    wire write_done;
    wire ids_write_done;
    wire wren_fail;                        // DEBUG: WREN not accepted by EEPROM

    reg  read_done_latched  = 1'b0;
    reg  write_done_latched = 1'b0;
    reg  wren_fail_latched  = 1'b0;       // DEBUG: latched WREN failure
    reg  auto_read_req      = 1'b0;       // auto read-back trigger after write
    reg  key_write_req      = 1'b0;
    reg  ids_write_req      = 1'b0;

    localparam [1:0] WR_IDLE = 2'd0;
    localparam [1:0] WR_KEY  = 2'd1;
    localparam [1:0] WR_IDS  = 2'd2;
    reg [1:0] write_state = WR_IDLE;

    at25010_interface #(
        .CLK_HZ(32_000_000)
    ) u_eeprom (
        .clk(clk_32mhz),
        .rst(rst | ~pll_lock),
        .spi_cs(spi_cs_1),
        .start_xfer(spi_start_xfer),
        .tx_byte(spi_tx_byte),
        .xfer_active(spi_xfer_active),
        .xfer_done(spi_xfer_done),
        .rx_byte(spi_rx_byte),
        .key(key),
        .key_valid(key_valid),
        .counter(counter),
        .counter_valid(counter_valid),
        .ids(ids),
        .ids_valid(ids_valid),
        .busy(eeprom_busy),
        .read_req(read_pulse | auto_read_req),
        .write_req(key_write_req),
        .write_key(DEBUG_KEY),
        .counter_write_req(1'b0),
        .counter_write_data(64'h0),
        .ids_write_req(ids_write_req),
        .ids_write_data(DEBUG_IDS),
        .read_done(read_done),
        .write_done(write_done),
        .counter_write_done(),
        .ids_write_done(ids_write_done),
        .wren_fail(wren_fail)
    );

    // After a successful write, fire a single-cycle read request to verify
    // what the EEPROM actually stored.
    always @(posedge clk_32mhz) begin
        if (rst | ~pll_lock) begin
            auto_read_req      <= 1'b0;
            read_done_latched  <= 1'b0;
            write_done_latched <= 1'b0;
            wren_fail_latched  <= 1'b0;
        end else begin
            // Default: pulse is one cycle wide
            auto_read_req <= 1'b0;

            // Trigger a read-back immediately after the ID write completes
            if (ids_write_done && !wren_fail)
                auto_read_req <= 1'b1;

            if (read_pulse | auto_read_req) begin
                read_done_latched <= 1'b0;
            end else if (read_done) begin
                read_done_latched <= 1'b1;
            end

            if (write_pulse) begin
                write_done_latched <= 1'b0;
                wren_fail_latched  <= 1'b0;
            end else if (write_done) begin
                write_done_latched <= 1'b1;
                if (wren_fail)
                    wren_fail_latched <= 1'b1;
            end
        end
    end

    // Write sequence: key first, then IDs
    always @(posedge clk_32mhz) begin
        if (rst | ~pll_lock) begin
            write_state   <= WR_IDLE;
            key_write_req <= 1'b0;
            ids_write_req <= 1'b0;
        end else begin
            key_write_req <= 1'b0;
            ids_write_req <= 1'b0;
            case (write_state)
                WR_IDLE: begin
                    if (write_pulse) begin
                        key_write_req <= 1'b1;
                        write_state   <= WR_KEY;
                    end
                end
                WR_KEY: begin
                    if (write_done || wren_fail) begin
                        ids_write_req <= 1'b1;
                        write_state   <= WR_IDS;
                    end
                end
                WR_IDS: begin
                    if (ids_write_done || wren_fail) begin
                        write_state <= WR_IDLE;
                    end
                end
                default: write_state <= WR_IDLE;
            endcase
        end
    end

    // MFRC522 chip select idle high
    assign spi_cs_0 = 1'b1;

    // unlock = last EEPROM read returned exactly DEBUG_KEY
    // This lights up at startup if the EEPROM already holds the correct key,
    // and after a write+auto-read confirms the write was verified successfully.
    wire key_match = key_valid && (key == DEBUG_KEY);

    // Status outputs
    assign busy       = eeprom_busy;
    assign hard_fault = wren_fail_latched; // WREN was rejected -> EEPROM problem
    assign unlock     = read_done_latched && key_match;
    assign mode       = key_valid;

    // ------------------------------------------------------------------------
    // LED mapping:
    //   [7]   = wren_fail_latched  (WREN rejected -> EEPROM problem)
    //   [6]   = write_done_latched (write cycle completed)
    //   [5]   = read_done_latched  (read cycle completed)
    //   [4]   = key_match          (read-back matches DEBUG_KEY)
    //   [3:0] = last nibble of key LSB (read-back data, expect 0x0)
    // ------------------------------------------------------------------------
    assign led[7]   = wren_fail_latched;
    assign led[6]   = write_done_latched;
    assign led[5]   = read_done_latched;
    assign led[4]   = key_match;
    assign led[3:0] = key_valid ? key[3:0] : 4'h0;

    // UART idle high (unused)
    assign uart_txd = 1'b1;

endmodule
