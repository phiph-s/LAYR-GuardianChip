// Simplest possible MFRC522 version read
module ulx3s_test_top (
    input wire clk_25mhz, btn_fire1,
    output reg spi_sclk, spi_cs_0, spi_cs_1, spi_mosi,
    input wire spi_miso,
    output wire uart_txd, input wire uart_rxd,
    output wire mode, busy, hard_fault, unlock,
    output wire [7:0] led
);
    reg [24:0] timer;
    reg [5:0] bit_counter;  // 0-31 for 2 bytes
    reg [4:0] clk_div;
    reg [15:0] tx_data;
    reg [15:0] rx_data;
    reg active;
    reg [7:0] cs_delay;  // Delay after CS activation
    
    always @(posedge clk_25mhz) begin
        timer <= timer + 1;
        
        if (!active) begin
            // Idle - wait for trigger
            spi_cs_0 <= 1'b1;
            spi_sclk <= 1'b0;
            spi_mosi <= 1'b0;
            
            if (timer == 25'd10_000_000) begin
                active <= 1'b1;
                bit_counter <= 0;
                clk_div <= 0;
                cs_delay <= 0;
                spi_cs_0 <= 1'b0;
                tx_data <= 16'hEE00;  // Read version + dummy
                rx_data <= 0;
            end
        end else begin
            // Active - send/receive
            if (cs_delay < 100) begin
                // Wait after CS activation (4 microseconds @ 25MHz)
                cs_delay <= cs_delay + 1;
            end else if (clk_div < 24) begin
                clk_div <= clk_div + 1;
            end else begin
                clk_div <= 0;
                spi_sclk <= ~spi_sclk;
                
                if (spi_sclk) begin
                    // Falling edge (was HIGH, now going LOW) - output bit
                    spi_mosi <= tx_data[15];
                    bit_counter <= bit_counter + 1;
                end else begin
                    // Rising edge (was LOW, now going HIGH) - input bit, shift
                    rx_data <= {rx_data[14:0], spi_miso};
                    tx_data <= {tx_data[14:0], 1'b0};
                    
                    if (bit_counter == 31) begin
                        // Done
                        active <= 1'b0;
                        spi_cs_0 <= 1'b1;
                        spi_sclk <= 1'b0;
                    end
                end
            end
        end
    end
    
    assign spi_cs_1 = 1'b1;
    
    wire [7:0] version = rx_data[7:0];  // Second byte received
    
    assign led[0] = timer[23];           // Heartbeat
    assign led[1] = active;              // Transaction active
    assign led[2] = (version == 8'h91 || version == 8'h92 || version == 8'h88);  // Version OK!
    assign led[3] = version[3];          // Version bit 3
    assign led[4] = version[2];          // Version bit 2
    assign led[5] = version[1];          // Version bit 1
    assign led[6] = version[0];          // Version bit 0 (LSB)
    assign led[7] = version[4];          // Version bit 4
    
    assign mode = active;
    assign busy = !active;
    assign hard_fault = 0;
    assign unlock = (version == 8'h91 || version == 8'h92);
    assign uart_txd = 1'b1;
endmodule
