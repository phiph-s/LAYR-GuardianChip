// Main Core Module - Guardian Chip Top Level
// Integrates all components for LAYR Authentication System

module main_core #(
  parameter UNLOCK_DURATION_PARAM = 32'd500000000 // 5 seconds at 100MHz (default)
)(
  // System signals
  input  logic         clk,
  input  logic         rst_n,

  // Shared SPI bus
  output logic         spi_sclk,
  output logic         spi_cs_0,   // MFRC522
  output logic         spi_cs_1,   // EEPROM
  output logic         spi_mosi,
  input  logic         spi_miso,

  // Status indicators
  output logic         status_unlock,    // Green LED - door unlocked
  output logic         status_fault,     // Red LED - authentication failed
  output logic         status_busy       // Yellow LED - busy authenticating
);

  wire rst = ~rst_n;

  // Shared SPI master (Mode 0)
  wire       spi_xfer_active;
  wire       spi_xfer_done;
  wire [7:0] spi_rx_byte;

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
  wire       spi_start_xfer = eeprom_busy ? eeprom_start_xfer : mfrc_start_xfer;
  wire [7:0] spi_tx_byte    = eeprom_busy ? eeprom_tx_byte   : mfrc_tx_byte;

  spi_master #(
      .CLK_HZ(32_000_000),
      .SPI_HZ(4_000_000)
  ) u_spi (
      .clk(clk),
      .rst(rst),
      .spi_sclk(spi_sclk),
      .spi_mosi(spi_mosi),
      .spi_miso(spi_miso),
      .start_xfer(spi_start_xfer),
      .tx_byte(spi_tx_byte),
      .xfer_active(spi_xfer_active),
      .xfer_done(spi_xfer_done),
      .rx_byte(spi_rx_byte)
  );

  // AT25010 EEPROM interface
  wire        key_write_req;
  wire [127:0] key_write_data;
  wire        key_write_done;
  wire        counter_write_req;
  wire [63:0] counter_write_data;
  wire        counter_write_done;

  at25010_interface #(
      .CLK_HZ(32_000_000)
  ) u_eeprom (
      .clk(clk),
      .rst(rst),

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

  // MFRC522 link interface + LAYR core
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

  mfrc522_apdu_interface #(
      .CLK_HZ(32_000_000),
      .SPI_HZ(4_000_000)
  ) u_nfc (
      .clk(clk),
      .rst(rst | eeprom_busy), // hold NFC reset while EEPROM reads
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
      .card_uid(),

      .app_tx_valid(app_tx_valid),
      .app_tx_byte(app_tx_byte),
      .app_tx_last(app_tx_last),
      .app_tx_ready(app_tx_ready),

      .app_rx_valid(app_rx_valid),
      .app_rx_byte(app_rx_byte),
      .app_rx_last(app_rx_last),
      .app_rx_ready(app_rx_ready)
  );

  wire unlock;

  layr_core #(
      .CLK_HZ(32_000_000)
  ) u_layr (
      .clk(clk),
      .rst(rst),
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

  assign status_unlock = unlock;
  assign status_fault  = iface_fault | layr_fault;
  assign status_busy   = layr_busy | eeprom_busy;

endmodule
