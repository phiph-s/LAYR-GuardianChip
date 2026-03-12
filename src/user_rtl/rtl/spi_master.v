module spi_master #(
    parameter integer CLK_HZ = 32_000_000,
    parameter integer SPI_HZ = 4_000_000
)(
    input  wire clk,
    input  wire rst,              // sync reset, active high

    output wire spi_sclk,
    output reg  spi_mosi,
    input  wire spi_miso,

    // one-byte transfer handshake (Mode 0)
    input  wire       start_xfer, // pulse high for 1 clk to start when not busy
    input  wire [7:0] tx_byte,
    output reg        xfer_active,
    output reg        xfer_done,   // 1-clk pulse when byte received
    output reg  [7:0] rx_byte
);

    // --------------------------
    // SPI clock generator / shifter
    // --------------------------
    localparam integer HALF_DIV   = CLK_HZ / (SPI_HZ * 2); // e.g. 32MHz/(4MHz*2)=4
    localparam integer HALF_DIV_W = 16;

    reg [HALF_DIV_W-1:0] div_cnt = 0;
    reg sclk = 1'b0;
    assign spi_sclk = sclk;

    reg [7:0] shifter_tx = 8'h00;
    reg [7:0] shifter_rx = 8'h00;
    reg [2:0] bit_idx    = 3'd7;

    reg done_pending = 1'b0;

    // Start on SCK low, present MOSI before rising edge, sample MISO on rising edge.
    always @(posedge clk) begin
        if (rst) begin
            div_cnt     <= 0;
            sclk        <= 1'b0;
            spi_mosi    <= 1'b0;
            shifter_tx  <= 8'h00;
            shifter_rx  <= 8'h00;
            bit_idx     <= 3'd7;
            xfer_active <= 1'b0;
            xfer_done   <= 1'b0;
            rx_byte     <= 8'h00;
            done_pending<= 1'b0;
        end else begin
            xfer_done <= 1'b0;

            if (start_xfer && !xfer_active) begin
                // latch new byte
                xfer_active <= 1'b1;
                shifter_tx  <= tx_byte;
                shifter_rx  <= 8'h00;
                bit_idx     <= 3'd7;
                sclk        <= 1'b0;
                div_cnt     <= 0;

                // On mode0, drive MOSI for bit7 immediately while SCK low
                spi_mosi    <= tx_byte[7];
                done_pending<= 1'b0;

            end else if (xfer_active) begin
                if (div_cnt == HALF_DIV-1) begin
                  div_cnt <= 0;
                  // toggle SCK
                  sclk <= ~sclk;

                  if (!sclk) begin
                    // rising edge (0->1): sample MISO
                    shifter_rx[bit_idx] <= spi_miso;

                    if (bit_idx == 0) begin
                      done_pending <= 1'b1;
                    end else begin
                      bit_idx <= bit_idx - 1'b1;
                    end

                  end else begin
                    // falling edge (1->0): update MOSI
                    spi_mosi <= shifter_tx[bit_idx];

                    // if we already sampled last bit on previous rising edge,
                    // complete transfer NOW (after this falling edge)
                    if (done_pending) begin
                      done_pending <= 1'b0;
                      xfer_active  <= 1'b0;
                      xfer_done    <= 1'b1;
                      rx_byte      <= shifter_rx;
                      sclk         <= 1'b0; // return to idle low
                    end
                  end

                end else begin
                  div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end

endmodule
