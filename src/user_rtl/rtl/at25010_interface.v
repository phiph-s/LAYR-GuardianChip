// =============================================================================
// at25010_interface.v
// Reads a 128-bit AES key (16 bytes), 64-bit counter (8 bytes), and a list
// of allowed 16-byte IDs from an AT25010 SPI EEPROM. Supports write modes
// to program key, counter, or ID list.
//
// SPI Mode 0, MSB first
// READ  sequence:  CS↓ -> READ(0x03) -> ADDR(0x00) -> 120 data bytes -> CS↑
//
// WRITE sequence (two 8-byte page writes, AT25010B page size = 8 bytes):
//   Page 0:  WREN -> verify WEL -> WRITE(0x02, 0x00, bytes 0–7)  -> Poll WIP
//   Page 1:  WREN -> verify WEL -> WRITE(0x02, 0x08, bytes 8–15) -> Poll WIP
// =============================================================================

module at25010_interface #(
    parameter integer CLK_HZ      = 32_000_000,
    parameter [127:0] DEFAULT_KEY = 128'h00112233445566778899AABBCCDDEEFF
)(
    input  wire        clk,
    input  wire        rst,

    // SPI chip-select for the AT25010 (active low)
    output reg         spi_cs,

    // Shared SPI-master byte interface
    output reg         start_xfer,
    output reg  [7:0]  tx_byte,
    input  wire        xfer_active,
    input  wire        xfer_done,
    input  wire [7:0]  rx_byte,

    // 128-bit AES key output + 64-bit counter output + allowed IDs
    output reg [127:0] key,
    output reg         key_valid,
    output reg [63:0]  counter,
    output reg         counter_valid,
    output reg [767:0] ids,          // 6 * 16-byte IDs
    output reg         ids_valid,
    output reg         busy,

    // Optional read/write controls
    input  wire        read_req,
    input  wire        write_req,
    input  wire [127:0] write_key,
    input  wire        counter_write_req,
    input  wire [63:0]  counter_write_data,
    input  wire        ids_write_req,
    input  wire [767:0] ids_write_data,
    output reg         read_done,
    output reg         write_done,
    output reg         counter_write_done,
    output reg         ids_write_done,

    // DEBUG: asserted if WREN was not accepted (WEL=0 after WREN)
    output reg         wren_fail
);

    localparam integer POLL_DELAY_CYCLES = (CLK_HZ / 1000) > 0 ? (CLK_HZ / 1000) : 1; // ~1ms
    localparam integer CS_GAP_CYCLES     = (CLK_HZ / 1_000_000) > 0 ? (CLK_HZ / 1_000_000) : 8; // ~1us

    localparam [5:0]
        ST_IDLE                 = 6'd0,

        // READ path
        ST_READ_CSS             = 6'd1,
        ST_READ_CMD             = 6'd2,
        ST_READ_ADDR            = 6'd3,
        ST_READ_ADDR_WAIT       = 6'd4,
        ST_READ_DATA            = 6'd5,
        ST_READ_DESEL           = 6'd6,
        ST_READ_DONE            = 6'd7,

        // WREN + WEL-check (shared for both pages)
        ST_WREN_CSS             = 6'd8,
        ST_WREN                 = 6'd9,
        ST_WREN_WAIT            = 6'd10,
        ST_WREN_DESEL           = 6'd11,
        ST_WREN_CHK_GAP         = 6'd12,
        ST_WREN_CHK_CSS         = 6'd13,
        ST_WREN_CHK_CMD         = 6'd14,
        ST_WREN_CHK_WAIT        = 6'd15,
        ST_WREN_CHK_DATA        = 6'd16,
        ST_WREN_CHK_DESEL       = 6'd17,
        ST_WREN_FAIL            = 6'd18,

        // WRITE page (shared for both pages)
        ST_WREN_GAP             = 6'd19,
        ST_WRITE_CMD            = 6'd20,
        ST_WRITE_ADDR           = 6'd21,
        ST_WRITE_DATA           = 6'd22,
        ST_WRITE_DESEL          = 6'd23,

        // Poll WIP after write
        ST_WRITE_POLL_DELAY     = 6'd24,
        ST_WRITE_POLL_CSS       = 6'd25,
        ST_WRITE_POLL_CMD       = 6'd26,
        ST_WRITE_POLL_WAIT      = 6'd27,
        ST_WRITE_POLL_DATA      = 6'd28,

        // After page 0 done: start page 1
        ST_PAGE1_START          = 6'd29,

        ST_WRITE_DONE           = 6'd30;

    reg [5:0]   state          = ST_IDLE;
    reg [6:0]   byte_cnt       = 7'd0;
    reg [127:0] write_buf      = 128'h0;
    reg [63:0]  counter_buf    = 64'h0;
    reg [767:0] ids_buf        = 768'h0;
    reg [63:0]  write_shift    = 64'h0;   // 8 bytes at a time
    reg [31:0]  poll_delay_cnt = 32'd0;
    reg [31:0]  cs_gap_cnt     = 32'd0;
    reg [7:0]   rdsr_latch     = 8'h00;
    reg [7:0]   write_addr     = 8'h00;   // current page start address
    reg [3:0]   page_idx       = 4'd0;    // page index for multi-page writes
    reg [3:0]   write_pages    = 4'd0;
    reg [7:0]   write_base_addr= 8'h00;

    reg pending_read        = 1'b0;
    reg pending_write       = 1'b0;
    reg pending_ctr_write   = 1'b0;
    reg pending_ids_write   = 1'b0;
    reg write_is_counter    = 1'b0;
    reg write_is_ids        = 1'b0;

    function [63:0] ids_chunk;
        input [3:0] idx;
        begin
            ids_chunk = ids_buf[767 - (idx * 64) -: 64];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_IDLE;
            spi_cs         <= 1'b1;
            start_xfer     <= 1'b0;
            tx_byte        <= 8'h00;
            key            <= DEFAULT_KEY;
            key_valid      <= 1'b0;
            counter        <= 64'h0;
            counter_valid  <= 1'b0;
            ids            <= 768'h0;
            ids_valid      <= 1'b0;
            busy           <= 1'b0;
            byte_cnt       <= 7'd0;
            write_buf      <= DEFAULT_KEY;
            counter_buf    <= 64'h0;
            ids_buf        <= 768'h0;
            write_shift    <= 64'h0;
            poll_delay_cnt <= 32'd0;
            cs_gap_cnt     <= 32'd0;
            rdsr_latch     <= 8'h00;
            write_addr     <= 8'h00;
            page_idx       <= 4'd0;
            write_pages    <= 4'd0;
            write_base_addr<= 8'h00;
            pending_read     <= 1'b1;
            pending_write    <= 1'b0;
            pending_ctr_write<= 1'b0;
            pending_ids_write<= 1'b0;
            write_is_counter <= 1'b0;
            write_is_ids     <= 1'b0;
            read_done      <= 1'b0;
            write_done     <= 1'b0;
            counter_write_done <= 1'b0;
            ids_write_done <= 1'b0;
            wren_fail      <= 1'b0;
        end else begin
            start_xfer <= 1'b0;
            read_done  <= 1'b0;
            write_done <= 1'b0;
            counter_write_done <= 1'b0;
            ids_write_done <= 1'b0;

            if (write_req === 1'b1) begin
                pending_write <= 1'b1;
                write_buf     <= write_key;
                wren_fail     <= 1'b0;
            end
            if (counter_write_req === 1'b1) begin
                pending_ctr_write <= 1'b1;
                counter_buf       <= counter_write_data;
                wren_fail         <= 1'b0;
            end
            if (ids_write_req === 1'b1) begin
                pending_ids_write <= 1'b1;
                ids_buf           <= ids_write_data;
                wren_fail         <= 1'b0;
            end
            if (read_req === 1'b1) begin
                pending_read <= 1'b1;
            end

            case (state)

                // -------------------------------------------------------
                // Idle
                // -------------------------------------------------------
                ST_IDLE: begin
                    spi_cs   <= 1'b1;
                    busy     <= 1'b0;
                    if (pending_write) begin
                        busy <= 1'b1;
                        if (!xfer_active) begin
                            pending_write <= 1'b0;
                            write_is_counter <= 1'b0;
                            write_is_ids   <= 1'b0;
                            page_idx      <= 4'd0;
                            write_pages   <= 4'd2;
                            write_base_addr <= 8'h00;
                            write_addr    <= 8'h00;
                            // load first 8 bytes (MSB first) into write_shift
                            write_shift   <= write_buf[127:64];
                            spi_cs        <= 1'b0;
                            cs_gap_cnt    <= 32'd0;
                            state         <= ST_WREN_CSS;
                        end
                    end else if (pending_ctr_write) begin
                        busy <= 1'b1;
                        if (!xfer_active) begin
                            pending_ctr_write <= 1'b0;
                            write_is_counter  <= 1'b1;
                            write_is_ids   <= 1'b0;
                            page_idx      <= 4'd0;
                            write_pages   <= 4'd1;
                            write_base_addr <= 8'h10;
                            write_addr    <= 8'h10; // counter starts after key
                            write_shift   <= counter_buf;
                            spi_cs        <= 1'b0;
                            cs_gap_cnt    <= 32'd0;
                            state         <= ST_WREN_CSS;
                        end
                    end else if (pending_ids_write) begin
                        busy <= 1'b1;
                        if (!xfer_active) begin
                            pending_ids_write <= 1'b0;
                            write_is_counter  <= 1'b0;
                            write_is_ids      <= 1'b1;
                            page_idx      <= 4'd0;
                            write_pages   <= 4'd12;
                            write_base_addr <= 8'h18; // IDs start after key + counter
                            write_addr    <= 8'h18;
                            write_shift   <= ids_chunk(4'd0);
                            spi_cs        <= 1'b0;
                            cs_gap_cnt    <= 32'd0;
                            state         <= ST_WREN_CSS;
                        end
                    end else if (pending_read) begin
                        busy <= 1'b1;
                        if (!xfer_active) begin
                            pending_read <= 1'b0;
                            spi_cs       <= 1'b0;
                            cs_gap_cnt   <= 32'd0;
                            key_valid    <= 1'b0;
                            counter_valid<= 1'b0;
                            ids_valid    <= 1'b0;
                            state        <= ST_READ_CSS;
                        end
                    end
                end

                // -------------------------------------------------------
                // READ path
                // -------------------------------------------------------
                ST_READ_CSS: begin
                    spi_cs <= 1'b0;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        state      <= ST_READ_CMD;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_READ_CMD: begin
                    spi_cs <= 1'b0;
                    if (!xfer_active) begin
                        tx_byte    <= 8'h03;
                        start_xfer <= 1'b1;
                        state      <= ST_READ_ADDR;
                    end
                end

                ST_READ_ADDR: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        tx_byte    <= 8'h00; // start address = 0
                        start_xfer <= 1'b1;
                        state      <= ST_READ_ADDR_WAIT;
                    end
                end

                ST_READ_ADDR_WAIT: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        tx_byte    <= 8'h00;
                        start_xfer <= 1'b1;
                        byte_cnt   <= 7'd0;
                        key        <= 128'h0;
                        counter    <= 64'h0;
                        ids        <= 768'h0;
                        state      <= ST_READ_DATA;
                    end
                end

                ST_READ_DATA: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        if (byte_cnt < 7'd16) begin
                            key <= {key[119:0], rx_byte};
                        end else if (byte_cnt < 7'd24) begin
                            counter <= {counter[55:0], rx_byte};
                        end else if (byte_cnt < 7'd120) begin
                            ids <= {ids[759:0], rx_byte};
                        end
                        if (byte_cnt == 7'd119) begin
                            state <= ST_READ_DESEL;
                        end else begin
                            byte_cnt   <= byte_cnt + 1'b1;
                            tx_byte    <= 8'h00;
                            start_xfer <= 1'b1;
                        end
                    end
                end

                ST_READ_DESEL: begin
                    spi_cs <= 1'b1;
                    state  <= ST_READ_DONE;
                end

                ST_READ_DONE: begin
                    key_valid     <= 1'b1;
                    counter_valid <= 1'b1;
                    ids_valid     <= 1'b1;
                    busy      <= 1'b0;
                    read_done <= 1'b1;
                    state     <= ST_IDLE;
                end

                // -------------------------------------------------------
                // WREN (used for both page 0 and page 1)
                // -------------------------------------------------------
                ST_WREN_CSS: begin
                    spi_cs <= 1'b0;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        state      <= ST_WREN;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_WREN: begin
                    spi_cs <= 1'b0;
                    if (!xfer_active) begin
                        tx_byte    <= 8'h06;
                        start_xfer <= 1'b1;
                        state      <= ST_WREN_WAIT;
                    end
                end

                ST_WREN_WAIT: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        spi_cs <= 1'b1;
                        state  <= ST_WREN_DESEL;
                    end
                end

                ST_WREN_DESEL: begin
                    spi_cs     <= 1'b1;
                    cs_gap_cnt <= 32'd0;
                    state      <= ST_WREN_CHK_GAP;
                end

                // -------------------------------------------------------
                // Verify WEL=1 after WREN
                // -------------------------------------------------------
                ST_WREN_CHK_GAP: begin
                    spi_cs <= 1'b1;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        spi_cs     <= 1'b0;
                        state      <= ST_WREN_CHK_CSS;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_WREN_CHK_CSS: begin
                    spi_cs <= 1'b0;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        state      <= ST_WREN_CHK_CMD;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_WREN_CHK_CMD: begin
                    spi_cs <= 1'b0;
                    if (!xfer_active) begin
                        tx_byte    <= 8'h05;
                        start_xfer <= 1'b1;
                        state      <= ST_WREN_CHK_WAIT;
                    end
                end

                ST_WREN_CHK_WAIT: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        tx_byte    <= 8'h00;
                        start_xfer <= 1'b1;
                        state      <= ST_WREN_CHK_DATA;
                    end
                end

                ST_WREN_CHK_DATA: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        rdsr_latch <= rx_byte;
                        spi_cs     <= 1'b1;
                        state      <= ST_WREN_CHK_DESEL;
                    end
                end

                ST_WREN_CHK_DESEL: begin
                    spi_cs <= 1'b1;
                    if (rdsr_latch[1]) begin
                        // WEL=1: proceed with page write
                        cs_gap_cnt <= 32'd0;
                        state      <= ST_WREN_GAP;
                    end else begin
                        wren_fail <= 1'b1;
                        state     <= ST_WREN_FAIL;
                    end
                end

                ST_WREN_FAIL: begin
                    spi_cs     <= 1'b1;
                    busy       <= 1'b0;
                    if (write_is_counter) begin
                        counter_write_done <= 1'b1;
                    end else if (write_is_ids) begin
                        ids_write_done <= 1'b1;
                    end else begin
                        write_done <= 1'b1;
                    end
                    state      <= ST_IDLE;
                end

                // -------------------------------------------------------
                // Gap then WRITE page
                // -------------------------------------------------------
                ST_WREN_GAP: begin
                    spi_cs <= 1'b1;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        spi_cs     <= 1'b0;
                        state      <= ST_WRITE_CMD;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_WRITE_CMD: begin
                    spi_cs <= 1'b0;
                    if (!xfer_active) begin
                        tx_byte    <= 8'h02;
                        start_xfer <= 1'b1;
                        state      <= ST_WRITE_ADDR;
                    end
                end

                ST_WRITE_ADDR: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        tx_byte    <= write_addr; // 0x00 for page0, 0x08 for page1
                        start_xfer <= 1'b1;
                        byte_cnt   <= 5'd0;
                        state      <= ST_WRITE_DATA;
                    end
                end

                // Send 8 bytes of the current page
                ST_WRITE_DATA: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        if (byte_cnt == 5'd0) begin
                            tx_byte     <= write_shift[63:56];
                            start_xfer  <= 1'b1;
                            write_shift <= {write_shift[55:0], 8'h00};
                            byte_cnt    <= 5'd1;
                        end else if (byte_cnt >= 5'd8) begin
                            // 8 bytes sent, deselect
                            state <= ST_WRITE_DESEL;
                        end else begin
                            tx_byte     <= write_shift[63:56];
                            start_xfer  <= 1'b1;
                            write_shift <= {write_shift[55:0], 8'h00};
                            byte_cnt    <= byte_cnt + 1'b1;
                        end
                    end
                end

                ST_WRITE_DESEL: begin
                    spi_cs         <= 1'b1;
                    poll_delay_cnt <= 32'd0;
                    state          <= ST_WRITE_POLL_DELAY;
                end

                // -------------------------------------------------------
                // Poll WIP until write cycle complete
                // -------------------------------------------------------
                ST_WRITE_POLL_DELAY: begin
                    spi_cs <= 1'b1;
                    if (poll_delay_cnt >= POLL_DELAY_CYCLES - 1) begin
                        poll_delay_cnt <= 32'd0;
                        spi_cs         <= 1'b0;
                        cs_gap_cnt     <= 32'd0;
                        state          <= ST_WRITE_POLL_CSS;
                    end else
                        poll_delay_cnt <= poll_delay_cnt + 1'b1;
                end

                ST_WRITE_POLL_CSS: begin
                    spi_cs <= 1'b0;
                    if (cs_gap_cnt >= CS_GAP_CYCLES - 1) begin
                        cs_gap_cnt <= 32'd0;
                        state      <= ST_WRITE_POLL_CMD;
                    end else
                        cs_gap_cnt <= cs_gap_cnt + 1'b1;
                end

                ST_WRITE_POLL_CMD: begin
                    spi_cs <= 1'b0;
                    if (!xfer_active) begin
                        tx_byte    <= 8'h05;
                        start_xfer <= 1'b1;
                        state      <= ST_WRITE_POLL_WAIT;
                    end
                end

                ST_WRITE_POLL_WAIT: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        tx_byte    <= 8'h00;
                        start_xfer <= 1'b1;
                        state      <= ST_WRITE_POLL_DATA;
                    end
                end

                ST_WRITE_POLL_DATA: begin
                    spi_cs <= 1'b0;
                    if (xfer_done) begin
                        spi_cs <= 1'b1;
                        if (rx_byte[0]) begin
                            // WIP=1: still writing
                            poll_delay_cnt <= 32'd0;
                            state          <= ST_WRITE_POLL_DELAY;
                        end else begin
                            // WIP=0: page write done
                            if ((page_idx + 1'b1) < write_pages) begin
                                // More pages to write
                                state <= ST_PAGE1_START;
                            end else begin
                                // All pages done
                                state <= ST_WRITE_DONE;
                            end
                        end
                    end
                end

                // -------------------------------------------------------
                // Transition to next page
                // -------------------------------------------------------
                ST_PAGE1_START: begin
                    spi_cs      <= 1'b1;
                    page_idx   <= page_idx + 1'b1;
                    write_addr <= write_base_addr + {page_idx + 1'b1, 3'b000};
                    if (write_is_counter) begin
                        write_shift <= counter_buf;
                    end else if (write_is_ids) begin
                        write_shift <= ids_chunk(page_idx + 1'b1);
                    end else begin
                        write_shift <= (page_idx + 1'b1) == 4'd1 ? write_buf[63:0] : write_buf[127:64];
                    end
                    cs_gap_cnt <= 32'd0;
                    spi_cs     <= 1'b0;
                    state      <= ST_WREN_CSS;
                end

                // -------------------------------------------------------
                // All done
                // -------------------------------------------------------
                ST_WRITE_DONE: begin
                    if (write_is_counter) begin
                        counter        <= counter_buf;
                        counter_valid  <= 1'b1;
                        counter_write_done <= 1'b1;
                    end else if (write_is_ids) begin
                        ids        <= ids_buf;
                        ids_valid  <= 1'b1;
                        ids_write_done <= 1'b1;
                    end else begin
                        key        <= write_buf;
                        key_valid  <= 1'b1;
                        write_done <= 1'b1;
                    end
                    busy       <= 1'b0;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
