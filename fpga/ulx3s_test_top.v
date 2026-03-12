module ulx3s_test_top (
    input  wire        clk_25mhz,
    input  wire [6:0]  btn,

    // Shared SPI bus
    output wire        spi_sclk,
    output wire        spi_cs_0,   // MFRC522
    output wire        spi_cs_1,   // EEPROM
    output wire        spi_mosi,
    input  wire        spi_miso,

    // misc IO
    output wire        uart_txd,
    input  wire        uart_rxd,
    output wire        mode,

    // status
    output wire        busy,
    output wire        hard_fault,
    output wire        unlock,

    output wire [7:0]  led
);

    wire rst = btn[1];  // Use btn[1] for reset (btn[0] used for debug)

    // ------------------------------------------------------------------------
    // PLL: 25 MHz -> 32 MHz (MFRC522 logic expects 32 MHz)
    // ------------------------------------------------------------------------
    wire clk_32mhz;
    wire pll_lock;

    // ECP5 PLL (same config as before)
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

    // Separate SPI drive wires per consumer
    wire       mfrc_start_xfer;
    wire [7:0] mfrc_tx_byte;

    wire       eeprom_start_xfer;
    wire [7:0] eeprom_tx_byte;

    // EEPROM status
    wire        eeprom_busy;
    wire        eeprom_key_valid;
    wire [127:0] eeprom_key;
    wire        eeprom_counter_valid;
    wire [63:0] eeprom_counter;
    wire [767:0] eeprom_ids;
    wire        eeprom_ids_valid;

    // Mux: EEPROM has priority while it is running its startup read
    wire spi_start_xfer = eeprom_busy ? eeprom_start_xfer : mfrc_start_xfer;
    wire [7:0] spi_tx_byte = eeprom_busy ? eeprom_tx_byte : mfrc_tx_byte;

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
    // AT25010 EEPROM interface — reads key on startup automatically
    // ------------------------------------------------------------------------
    at25010_interface #(
        .CLK_HZ(32_000_000)
    ) u_eeprom (
        .clk(clk_32mhz),
        .rst(rst | ~pll_lock),

        .spi_cs(spi_cs_1),
        .start_xfer(eeprom_start_xfer),
        .tx_byte(eeprom_tx_byte),
        .xfer_active(spi_xfer_active),
        .xfer_done(spi_xfer_done),
        .rx_byte(spi_rx_byte),

        .key(eeprom_key),
        .key_valid(eeprom_key_valid),
        .counter(eeprom_counter),
        .counter_valid(eeprom_counter_valid),
        .ids(eeprom_ids),
        .ids_valid(eeprom_ids_valid),
        .busy(eeprom_busy),

        .read_req(1'b0),
        .write_req(key_write_req),
        .write_key(key_write_data),
        .counter_write_req(counter_write_req),
        .counter_write_data(counter_write_data),
        .ids_write_req(1'b0),
        .ids_write_data(768'h0),
        .read_done(),
        .write_done(key_write_done),
        .counter_write_done(counter_write_done),
        .ids_write_done(),
        .wren_fail()
    );

    // ------------------------------------------------------------------------
    // MFRC522 link interface + LAYR core
    // ------------------------------------------------------------------------
    wire [31:0] card_uid;
    wire        iface_busy;
    wire        iface_fault;
    wire        iface_link_ready;

    wire        app_tx_valid;
    wire [7:0]  app_tx_byte;
    wire        app_tx_last;
    wire        app_tx_ready;
    wire        app_rx_valid;
    wire [7:0]  app_rx_byte;
    wire        app_rx_last;
    wire        app_rx_ready;
    wire        restart_link;

    wire        layr_busy;
    wire        layr_fault;
    wire        key_write_req;
    wire [127:0] key_write_data;
    wire        key_write_done;
    wire        counter_write_req;
    wire [63:0] counter_write_data;
    wire        counter_write_done;

    mfrc522_apdu_interface #(
        .CLK_HZ(32_000_000),
        .SPI_HZ(4_000_000)
    ) u_nfc (
        .clk(clk_32mhz),
        // Hold MFRC522 in reset while EEPROM is reading so the SPI bus is free
        .rst(rst | ~pll_lock | eeprom_busy),
        .enable(1'b1),
        .busy_in(1'b0),
        .restart_link(restart_link),

        .spi_cs_0(spi_cs_0),

        .start_xfer(mfrc_start_xfer),
        .tx_byte(mfrc_tx_byte),
        .xfer_active(spi_xfer_active),
        .xfer_done(spi_xfer_done),
        .rx_byte(spi_rx_byte),

        .busy(iface_busy),
        .hard_fault(iface_fault),
        .card_seen(),
        .link_ready(iface_link_ready),
        .card_uid(card_uid),

        .app_tx_valid(app_tx_valid),
        .app_tx_byte(app_tx_byte),
        .app_tx_last(app_tx_last),
        .app_tx_ready(app_tx_ready),

        .app_rx_valid(app_rx_valid),
        .app_rx_byte(app_rx_byte),
        .app_rx_last(app_rx_last),
        .app_rx_ready(app_rx_ready)
    );

    layr_core #(
        .CLK_HZ(32_000_000)
    ) u_layr (
        .clk(clk_32mhz),
        .rst(rst | ~pll_lock),
        // Enable only once key + counter have been successfully read from EEPROM
        .enable(eeprom_key_valid & eeprom_counter_valid & eeprom_ids_valid),
        .busy_in(1'b0),
        .psk_key(eeprom_key),
        .psk_counter(eeprom_counter),
        .psk_counter_valid(eeprom_counter_valid),
        .allowed_ids(eeprom_ids),
        .allowed_ids_valid(eeprom_ids_valid),

        .key_write_req(key_write_req),
        .key_write_data(key_write_data),
        .key_write_done(key_write_done),
        .counter_write_req(counter_write_req),
        .counter_write_data(counter_write_data),
        .counter_write_done(counter_write_done),

        .link_ready(iface_link_ready),

        .app_tx_valid(app_tx_valid),
        .app_tx_byte(app_tx_byte),
        .app_tx_last(app_tx_last),
        .app_tx_ready(app_tx_ready),

        .app_rx_valid(app_rx_valid),
        .app_rx_byte(app_rx_byte),
        .app_rx_last(app_rx_last),
        .app_rx_ready(app_rx_ready),

        .restart_link(restart_link),
        .unlock(unlock),
        .busy(layr_busy),
        .fault(layr_fault)
    );

    assign busy       = layr_busy | eeprom_busy;
    assign hard_fault = iface_fault | layr_fault;

    // UART idle high (unused)
    assign uart_txd = 1'b1;
    // mode = key + counter + IDs loaded from EEPROM
    assign mode     = eeprom_key_valid & eeprom_counter_valid & eeprom_ids_valid;

    assign led = {4'b0, iface_link_ready, hard_fault, busy, unlock};

endmodule
