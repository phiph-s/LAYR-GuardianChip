module ulx3s_test_top (
    input  wire        clk_25mhz,
    input  wire [6:0]  btn,
    output wire        spi_sclk,
    output wire        spi_cs_0,
    output wire        spi_cs_1,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        uart_txd,
    input  wire        uart_rxd,
    output wire        mode,
    output wire        busy,
    output wire        hard_fault,
    output wire        unlock,
    output wire [7:0]  led
);

    localparam integer START_PERIOD_TICKS = 25_000_000; // ~1s

    // MFRC522 commands (read)
    localparam [7:0] CMD_VERSION   = 8'hEE; // reg 0x37
    localparam [7:0] CMD_COMIEN    = 8'hE6; // reg 0x33
    localparam [7:0] CMD_TXCONTROL = 8'hFC; // reg 0x3E

    // Debug Sequence States
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_SEND_CMD   = 4'd1;
    localparam [3:0] ST_WAIT_CMD   = 4'd2;
    localparam [3:0] ST_SEND_DUMMY1= 4'd3;
    localparam [3:0] ST_WAIT_DUMMY1= 4'd4;
    localparam [3:0] ST_SEND_DUMMY2= 4'd5;
    localparam [3:0] ST_WAIT_DUMMY2= 4'd6;
    localparam [3:0] ST_DONE       = 4'd7;

    reg [31:0] timer = 0;
    reg [3:0]  state = ST_IDLE;
    reg [2:0]  test_cycle = 0;

    // SPI Master Interface
    reg        m_cmd_valid;
    wire       m_cmd_ready;
    reg [7:0]  m_tx_data;
    wire [7:0] m_rx_data;
    wire       m_cmd_done;
    reg        m_keep_cs;
    
    // Captured Data
    reg [7:0] byte0;
    reg [7:0] byte1;
    reg [7:0] byte2;

    // POR / Reset logic (spi_master needs rst_n)
    reg [3:0] rst_cnt = 0;
    wire rst_n = &rst_cnt;
    always @(posedge clk_25mhz) begin 
        if (!rst_n) rst_cnt <= rst_cnt + 1;
    end

    spi_master #(
        .CLKS_PER_HALF_BIT(125), // 100kHz @ 25MHz
        .CS_INACTIVE_CLKS(50)
    ) u_spi (
        .clk(clk_25mhz),
        .rst_n(rst_n),
        .cmd_valid(m_cmd_valid),
        .cmd_ready(m_cmd_ready),
        .tx_data(m_tx_data),
        .rx_data(m_rx_data),
        .cmd_done(m_cmd_done),
        .keep_cs(m_keep_cs),
        .spi_cs_n(spi_cs_0),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    wire [7:0] sel_cmd = CMD_VERSION; // ALWAYS read version

    always @(posedge clk_25mhz) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            timer <= 0;
            m_cmd_valid <= 1'b0;
            m_keep_cs <= 1'b0;
        end else begin
            // Pulse cleaning
            if (m_cmd_valid && m_cmd_ready) m_cmd_valid <= 1'b0;

            case (state)
                ST_IDLE: begin
                    timer <= timer + 1;
                    if (timer >= 2500000) begin // Speed up to 10Hz (0.1s) for responsiveness
                        timer <= 0;
                        state <= ST_SEND_CMD;
                    end
                end

                // --- Byte 0: Command ---
                ST_SEND_CMD: begin
                    if (m_cmd_ready) begin
                        m_tx_data <= sel_cmd;
                        m_keep_cs <= 1'b1; // Keep CS low
                        m_cmd_valid <= 1'b1;
                        state <= ST_WAIT_CMD;
                    end
                end
                ST_WAIT_CMD: begin
                    if (m_cmd_done) begin
                        byte0 <= m_rx_data;
                        state <= ST_SEND_DUMMY1;
                    end
                end

                // --- Byte 1: Dummy ---
                ST_SEND_DUMMY1: begin
                    if (m_cmd_ready) begin
                        m_tx_data <= 8'h00;
                        m_keep_cs <= 1'b1; // Keep CS low
                        m_cmd_valid <= 1'b1;
                        state <= ST_WAIT_DUMMY1;
                    end
                end
                ST_WAIT_DUMMY1: begin
                    if (m_cmd_done) begin
                        byte1 <= m_rx_data;
                        state <= ST_SEND_DUMMY2;
                    end
                end

                // --- Byte 2: Dummy (Last) ---
                ST_SEND_DUMMY2: begin
                    if (m_cmd_ready) begin
                        m_tx_data <= 8'h00;
                        m_keep_cs <= 1'b0; // Release CS after this
                        m_cmd_valid <= 1'b1;
                        state <= ST_WAIT_DUMMY2;
                    end
                end
                ST_WAIT_DUMMY2: begin
                    if (m_cmd_done) begin
                        byte2 <= m_rx_data;
                        state <= ST_IDLE; // Done
                    end
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

    // Assign Unused
    assign spi_cs_1 = 1'b1;
    assign uart_txd = 1'b1;
    assign mode = (state != ST_IDLE);
    assign busy = 1'b1; // Power LED
    assign hard_fault = btn[2];
    assign unlock = btn[0];

    // LED Display
    // Default: Show Byte 1 (The Data)
    // Button 1: Show Byte 0 (The Address Phase Echo)
    wire [7:0] display_byte = btn[1] ? byte0 : byte1;
    assign led = display_byte;

endmodule
