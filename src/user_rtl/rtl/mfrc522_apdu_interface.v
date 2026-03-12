// =============================================================================
// mfrc522_apdu_interface.v
// MFRC522-based NFC card detect + ISO14443-4 link bring-up.
// Hands off APDU payload exchange to an external core.
// =============================================================================

module mfrc522_apdu_interface #(
    parameter integer CLK_HZ      = 32_000_000,
    parameter integer SPI_HZ      = 4_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire enable,
    input  wire busy_in,
    input  wire restart_link,

    output reg        spi_cs_0,

    output reg        start_xfer,
    output reg  [7:0] tx_byte,
    input  wire       xfer_active,
    input  wire       xfer_done,
    input  wire [7:0] rx_byte,

    output reg        busy,
    output reg        hard_fault,
    output reg        card_seen,
    output reg        link_ready,
    output reg  [31:0] card_uid,

    input  wire       app_tx_valid,
    input  wire [7:0] app_tx_byte,
    input  wire       app_tx_last,
    output reg        app_tx_ready,

    output reg        app_rx_valid,
    output reg  [7:0] app_rx_byte,
    output reg        app_rx_last,
    input  wire       app_rx_ready
);

    // -------------------------------------------------------------------------
    // 1 ms tick generator
    // -------------------------------------------------------------------------
    localparam integer MS_DIV = CLK_HZ / 1000;
    reg [$clog2(MS_DIV)-1:0] ms_cnt  = 0;
    reg ms_tick = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            ms_cnt  <= 0;
            ms_tick <= 1'b0;
        end else begin
            if (ms_cnt == MS_DIV - 1) begin
                ms_cnt  <= 0;
                ms_tick <= 1'b1;
            end else begin
                ms_cnt  <= ms_cnt + 1'b1;
                ms_tick <= 1'b0;
            end
        end
    end

    reg [7:0]  delay_ms    = 8'd0;
    reg [1:0]  reset_tries = 2'd0;

    // -------------------------------------------------------------------------
    // MFRC522 register addresses
    // -------------------------------------------------------------------------
    localparam [7:0] REG_Command_W     = 8'h02;
    localparam [7:0] REG_Command_R     = 8'h82;
    localparam [7:0] REG_ComIrq_W      = 8'h08;
    localparam [7:0] REG_ComIrq_R      = 8'h88;
    localparam [7:0] REG_DivIrq_W      = 8'h0A;
    localparam [7:0] REG_DivIrq_R      = 8'h8A;
    localparam [7:0] REG_Error_R       = 8'h8C;
    localparam [7:0] REG_FIFOData_W    = 8'h12;
    localparam [7:0] REG_FIFOData_R    = 8'h92;
    localparam [7:0] REG_FIFOLevel_W   = 8'h14;
    localparam [7:0] REG_FIFOLevel_R   = 8'h94;
    localparam [7:0] REG_Control_R     = 8'h98;
    localparam [7:0] REG_BitFraming_W  = 8'h1A;
    localparam [7:0] REG_BitFraming_R  = 8'h9A;
    localparam [7:0] REG_Coll_W        = 8'h1C;
    localparam [7:0] REG_Coll_R        = 8'h9C;
    localparam [7:0] REG_Mode_W        = 8'h22;
    localparam [7:0] REG_TxMode_W      = 8'h24;
    localparam [7:0] REG_RxMode_W      = 8'h26;
    localparam [7:0] REG_TxControl_W   = 8'h28;
    localparam [7:0] REG_TxControl_R   = 8'hA8;
    localparam [7:0] REG_TxASK_W       = 8'h2A;
    localparam [7:0] REG_CRCResultL_R  = 8'hC4;
    localparam [7:0] REG_CRCResultH_R  = 8'hC2;
    localparam [7:0] REG_ModWidth_W    = 8'h48;
    localparam [7:0] REG_RFCfg_W       = 8'h4C;
    localparam [7:0] REG_RxThreshold_W = 8'h30;
    localparam [7:0] REG_TMode_W       = 8'h54;
    localparam [7:0] REG_TPrescaler_W  = 8'h56;
    localparam [7:0] REG_TReloadH_W    = 8'h58;
    localparam [7:0] REG_TReloadL_W    = 8'h5A;
    localparam [7:0] REG_Version_R     = 8'hEE;

    // MFRC522 command codes
    localparam [7:0] PCD_Idle       = 8'h00;
    localparam [7:0] PCD_CalcCRC    = 8'h03;
    localparam [7:0] PCD_Transceive = 8'h0C;
    localparam [7:0] PCD_SoftReset  = 8'h0F;

    localparam [7:0] REQA             = 8'h26;
    localparam [7:0] PICC_CMD_SEL_CL1 = 8'h93;

    localparam [31:0] TIMEOUT_MAX = 32'd20_000_000;

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    reg [7:0] state = 8'h00;

    // Working registers
    reg [7:0] tmp_reg  = 8'h00;
    reg [7:0] comirq   = 8'h00;
    reg [7:0] errreg   = 8'h00;
    reg [7:0] fifolvl  = 8'h00;
    reg [7:0] ctrlreg  = 8'h00;
    reg [7:0] atqa0    = 8'h00;
    reg [7:0] atqa1    = 8'h00;

    reg [7:0] uid0     = 8'h00;
    reg [7:0] uid1     = 8'h00;
    reg [7:0] uid2     = 8'h00;
    reg [7:0] uid3     = 8'h00;
    reg [7:0] uid_bcc  = 8'h00;

    reg [7:0] crc_lo   = 8'h00;
    reg [7:0] crc_hi   = 8'h00;

    reg [7:0] sak          = 8'h00;

    reg [11:0] unlock_ms  = 12'd0;
    reg [31:0] poll_ctr   = 32'd0;

    // APDU helpers
    reg [5:0]   apdu_state     = 6'd0;
    reg [3:0]   apdu_idx       = 4'd0;
    reg [4:0]   resp_idx       = 5'd0;
    reg [7:0]   pcb_byte       = 8'h00;
    reg [7:0]   wtxm_byte      = 8'h00;
    reg         wtx_pending    = 1'b0;
    reg         rx_done_pending = 1'b0;
    reg         tx_last_seen   = 1'b0;
    reg         block_num      = 1'b0;

    // -------------------------------------------------------------------------
    // APDU sub-state encoding
    // -------------------------------------------------------------------------
    localparam [5:0] APDU_CFG_TXMODE        = 6'd0;
    localparam [5:0] APDU_CFG_RXMODE        = 6'd1;
    localparam [5:0] APDU_CFG_RFCFG         = 6'd2;
    localparam [5:0] APDU_CFG_RXTHRESH      = 6'd3;
    localparam [5:0] APDU_CFG_TIMER_H       = 6'd4;
    localparam [5:0] APDU_CFG_TIMER_L       = 6'd5;
    localparam [5:0] APDU_RATS_WAIT_SFGT    = 6'd6;
    localparam [5:0] APDU_RATS_IDLE         = 6'd7;
    localparam [5:0] APDU_RATS_IRQ_CLEAR    = 6'd8;
    localparam [5:0] APDU_RATS_FIFO_FLUSH   = 6'd9;
    localparam [5:0] APDU_RATS_FIFO_WRITE   = 6'd10;
    localparam [5:0] APDU_RATS_BITFRAMING   = 6'd11;
    localparam [5:0] APDU_RATS_CMD          = 6'd12;
    localparam [5:0] APDU_RATS_STARTSEND    = 6'd13;
    localparam [5:0] APDU_RATS_POLL_START   = 6'd14;
    localparam [5:0] APDU_RATS_POLL_WAIT    = 6'd15;
    localparam [5:0] APDU_RATS_ERR          = 6'd16;
    localparam [5:0] APDU_RATS_LEN          = 6'd17;
    localparam [5:0] APDU_RATS_READ         = 6'd18;
    localparam [5:0] APDU_RATS_RXCRC_ON     = 6'd19;
    localparam [5:0] APDU_LINK_IDLE         = 6'd20;
    // States >= APDU_LINK_IDLE that are NOT link-ready (post-ATS setup):
    localparam [5:0] APDU_ATS_SFGT_WAIT     = 6'd40;  // wait between ATS and first APDU
    localparam [5:0] APDU_CFG2_TMODE        = 6'd41;  // re-write TMode for APDU phase
    localparam [5:0] APDU_CFG2_TPRESCALER   = 6'd42;  // re-write TPrescaler for APDU phase
    localparam [5:0] APDU_TX_IDLE           = 6'd21;
    localparam [5:0] APDU_TX_IRQ_CLEAR      = 6'd22;
    localparam [5:0] APDU_TX_FIFO_FLUSH     = 6'd23;
    localparam [5:0] APDU_TX_WRITE_PCB      = 6'd24;
    localparam [5:0] APDU_TX_WRITE_PAYLOAD  = 6'd25;
    localparam [5:0] APDU_TX_BITFRAMING     = 6'd26;
    localparam [5:0] APDU_TX_CMD            = 6'd27;
    localparam [5:0] APDU_TX_STARTSEND      = 6'd28;
    localparam [5:0] APDU_TX_POLL_START     = 6'd29;
    localparam [5:0] APDU_TX_POLL_WAIT      = 6'd30;
    localparam [5:0] APDU_RX_ERR            = 6'd31;
    localparam [5:0] APDU_RX_LEN            = 6'd32;
    localparam [5:0] APDU_RX_READ           = 6'd33;
    localparam [5:0] APDU_WTX_IDLE          = 6'd34;
    localparam [5:0] APDU_WTX_FIFO_FLUSH    = 6'd35;
    localparam [5:0] APDU_WTX_WRITE         = 6'd36;
    localparam [5:0] APDU_WTX_BITFRAMING    = 6'd37;
    localparam [5:0] APDU_WTX_CMD           = 6'd38;
    localparam [5:0] APDU_WTX_STARTSEND     = 6'd39;

    // -------------------------------------------------------------------------
    // SPI op engine (2-byte write or read transaction)
    // -------------------------------------------------------------------------
    reg [7:0] op_addr    = 8'h00;
    reg [7:0] op_data    = 8'h00;
    reg       op_is_read = 1'b0;
    reg [2:0] op_step    = 3'd0;
    reg       op_done    = 1'b0;

    task start_write;
        input [7:0] addr_w;
        input [7:0] data;
        begin
            op_addr    <= addr_w;
            op_data    <= data;
            op_is_read <= 1'b0;
            op_step    <= 3'd1;
        end
    endtask

    task start_read;
        input [7:0] addr_r;
        begin
            op_addr    <= addr_r;
            op_data    <= 8'h00;
            op_is_read <= 1'b1;
            op_step    <= 3'd1;
        end
    endtask

    // -------------------------------------------------------------------------
    // Payload LUTs
    // -------------------------------------------------------------------------

    // RATS: E0 50 (FSDI=5, FSD=64 bytes, CID=0)
    function [7:0] rats_byte;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: rats_byte = 8'hE0;
                2'd1: rats_byte = 8'h50;
                default: rats_byte = 8'h00;
            endcase
        end
    endfunction

    // =========================================================================
    // Main clocked process
    // =========================================================================
    always @(posedge clk) begin
        if (rst || !enable) begin
            spi_cs_0          <= 1'b1;
            busy              <= 1'b0;
            hard_fault        <= 1'b0;
            card_seen         <= 1'b0;
            link_ready        <= 1'b0;
            card_uid          <= 32'h0;

            op_step    <= 3'd0;
            op_done    <= 1'b0;
            start_xfer <= 1'b0;
            state      <= 8'h00;
            poll_ctr   <= 32'd0;

            uid0 <= 8'h00; uid1 <= 8'h00;
            uid2 <= 8'h00; uid3 <= 8'h00;
            uid_bcc <= 8'h00;
            crc_lo  <= 8'h00; crc_hi  <= 8'h00;
            sak     <= 8'h00;

            apdu_state   <= APDU_CFG_TXMODE;
            apdu_idx     <= 4'd0;
            resp_idx     <= 5'd0;
            wtxm_byte    <= 8'h00;
            pcb_byte     <= 8'h00;
            wtx_pending <= 1'b0;
            rx_done_pending <= 1'b0;
            tx_last_seen <= 1'b0;
            block_num   <= 1'b0;
            app_tx_ready <= 1'b0;
            app_rx_valid <= 1'b0;
            app_rx_byte  <= 8'h00;
            app_rx_last  <= 1'b0;
            errreg  <= 8'h00;
            comirq  <= 8'h00;
            fifolvl <= 8'h00;
        end else begin
            op_done    <= 1'b0;
            start_xfer <= 1'b0;
            link_ready <= (state == 8'hF1) &&
                          (apdu_state >= APDU_LINK_IDLE) &&
                          (apdu_state <  APDU_ATS_SFGT_WAIT);  // exclude post-ATS setup states
            busy <= (state != 8'hF0) && (state != 8'hFF) &&
                    !((state == 8'hF1) && (apdu_state == APDU_LINK_IDLE));
            app_tx_ready <= 1'b0;
            if (app_rx_valid && app_rx_ready) begin
                app_rx_valid <= 1'b0;
                app_rx_last  <= 1'b0;
            end

            if (restart_link) begin
                spi_cs_0       <= 1'b1;
                op_step        <= 3'd0;
                op_done        <= 1'b0;
                start_xfer     <= 1'b0;
                state          <= 8'h30;
                apdu_state     <= APDU_CFG_TXMODE;
                card_seen      <= 1'b0;
                hard_fault     <= 1'b0;
                poll_ctr       <= 32'd0;
                app_rx_valid   <= 1'b0;
                app_rx_last    <= 1'b0;
                app_tx_ready   <= 1'b0;
                block_num      <= 1'b0;  // FIX 1: PCB block number must reset on restart
            end else begin

            // De-assert CS when op engine is idle, except during burst reads
            if (op_step == 3'd0 &&
                !((state >= 8'h65 && state <= 8'h69) ||
                  (state >= 8'h8F && state <= 8'h95))) begin
                spi_cs_0 <= 1'b1;
            end

            case (op_step)
                3'd0: begin end
                3'd1: begin
                    spi_cs_0 <= 1'b0;
                    op_step  <= 3'd2;
                end
                3'd2: begin
                    if (!xfer_active) begin
                        tx_byte    <= op_addr;
                        start_xfer <= 1'b1;
                        op_step    <= 3'd3;
                    end
                end
                3'd3: begin
                    if (xfer_done) begin
                        if (!xfer_active) begin
                            tx_byte    <= op_data;
                            start_xfer <= 1'b1;
                            op_step    <= 3'd4;
                        end
                    end
                end
                // 2nd byte finished shifting out.
                3'd4: begin
                    if (xfer_done) begin
                        // Wait one clock so rx_byte is guaranteed stable.
                        op_step <= 3'd5;
                    end
                end
                // Capture stage.
                3'd5: begin
                    if (op_is_read) tmp_reg <= rx_byte;
                    op_step <= 3'd6;
                end
                // Done pulse.
                3'd6: begin
                    spi_cs_0 <= 1'b1;
                    op_done  <= 1'b1;
                    op_step  <= 3'd0;
                end
            endcase

            // -----------------------------------------------------------------
            // Top-level state machine
            // -----------------------------------------------------------------
            case (state)

                // ==============================================================
                // INIT: Soft-reset and wait
                // ==============================================================
                8'h00: begin
                    busy       <= 1'b1;
                    hard_fault <= 1'b0;
                    card_seen  <= 1'b0;
                    reset_tries <= 0;
                    uid0 <= 8'h00; uid1 <= 8'h00;
                    uid2 <= 8'h00; uid3 <= 8'h00;
                    if (op_step == 3'd0) begin
                        start_write(REG_Command_W, PCD_SoftReset);
                        state <= 8'h01;
                    end
                end
                8'h01: if (op_done) begin delay_ms <= 8'd50; state <= 8'h02; end
                8'h02: if (ms_tick) begin
                    if (delay_ms != 0) delay_ms <= delay_ms - 1'b1;
                    else state <= 8'h03;
                end
                8'h03: if (op_step == 3'd0) begin start_read(REG_Command_R); state <= 8'h04; end
                8'h04: if (op_done) begin
                    uid0 <= tmp_reg;
                    if (tmp_reg[4] == 1'b1) begin
                        reset_tries <= reset_tries + 1'b1;
                        if (reset_tries == 2'd2) begin hard_fault <= 1'b1; state <= 8'hFF; end
                        else begin delay_ms <= 8'd50; state <= 8'h02; end
                    end else state <= 8'h10;
                end

                // ==============================================================
                // CHIP INIT: Version read + register setup
                // ==============================================================
                8'h10: if (op_step==3'd0) begin start_read(REG_Version_R); state<=8'h0D; end
                8'h0D: if (op_done) begin uid3 <= tmp_reg; state<=8'h0E; end
                8'h0E: if (op_step==3'd0) begin start_write(REG_TxMode_W, 8'h00);  state<=8'h11; end
                8'h11: if (op_done) begin state<=8'h12; end
                8'h12: if (op_step==3'd0) begin start_write(REG_RxMode_W, 8'h00);  state<=8'h13; end
                8'h13: if (op_done) begin state<=8'h14; end
                8'h14: if (op_step==3'd0) begin start_write(REG_ModWidth_W, 8'h26); state<=8'h15; end
                8'h15: if (op_done) begin state<=8'h16; end

                // Timer: TAuto, TPrescaler=169, TReload=1000 → ~25 ms (used for ISO14443-3 only)
                8'h16: if (op_step==3'd0) begin start_write(REG_TMode_W, 8'h80);     state<=8'h17; end
                8'h17: if (op_done) begin state<=8'h18; end
                8'h18: if (op_step==3'd0) begin start_write(REG_TPrescaler_W, 8'hA9); state<=8'h19; end
                8'h19: if (op_done) begin state<=8'h1A; end
                8'h1A: if (op_step==3'd0) begin start_write(REG_TReloadH_W, 8'h03);  state<=8'h1B; end
                8'h1B: if (op_done) begin state<=8'h1C; end
                8'h1C: if (op_step==3'd0) begin start_write(REG_TReloadL_W, 8'hE8);  state<=8'h1D; end
                8'h1D: if (op_done) begin state<=8'h1E; end

                8'h1E: if (op_step==3'd0) begin start_write(REG_TxASK_W, 8'h40);   state<=8'h1F; end
                8'h1F: if (op_done) begin state<=8'h20; end
                8'h20: if (op_step==3'd0) begin start_write(REG_Mode_W, 8'h3D);     state<=8'h21; end
                8'h21: if (op_done) begin state<=8'h22; end

                8'h22: if (op_step==3'd0) begin start_read(REG_TxControl_R); state<=8'h23; end
                8'h23: if (op_done) begin state<=8'h24; end
                8'h24: begin
                    if (tmp_reg[1:0] == 2'b11) state <= 8'h30;
                    else if (op_step==3'd0) begin
                        start_write(REG_TxControl_W, tmp_reg | 8'h03);
                        state <= 8'h25;
                    end
                end
                8'h25: if (op_done) begin state <= 8'h30; end

                // ==============================================================
                // POLL LOOP: REQA + anticollision + SELECT
                // ==============================================================
                8'h30: if (op_step==3'd0) begin start_write(REG_TxMode_W, 8'h00);  state<=8'h31; end
                8'h31: if (op_done) begin state<=8'h32; end
                8'h32: if (op_step==3'd0) begin start_write(REG_RxMode_W, 8'h00);  state<=8'h33; end
                8'h33: if (op_done) begin state<=8'h34; end
                8'h34: if (op_step==3'd0) begin start_write(REG_ModWidth_W, 8'h26); state<=8'h35; end
                8'h35: if (op_done) begin state<=8'h40; end

                // Send REQA (7-bit short frame)
                8'h40: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Idle); state<=8'h41; end
                8'h41: if (op_done) begin state<=8'h42; end
                8'h42: if (op_step==3'd0) begin start_write(REG_ComIrq_W, 8'h7F);    state<=8'h43; end
                8'h43: if (op_done) begin state<=8'h44; end
                8'h44: if (op_step==3'd0) begin start_write(REG_FIFOLevel_W, 8'h80); state<=8'h45; end
                8'h45: if (op_done) begin state<=8'h46; end
                8'h46: if (op_step==3'd0) begin start_write(REG_FIFOData_W, REQA);   state<=8'h47; end
                8'h47: if (op_done) begin state<=8'h48; end
                8'h48: if (op_step==3'd0) begin start_write(REG_BitFraming_W, 8'h07); state<=8'h49; end
                8'h49: if (op_done) begin state<=8'h4A; end
                8'h4A: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Transceive); state<=8'h4B; end
                8'h4B: if (op_done) begin state<=8'h4C; end
                8'h4C: if (op_step==3'd0) begin start_read(REG_BitFraming_R); state<=8'h4D; end
                8'h4D: if (op_done) begin state<=8'h4E; end
                8'h4E: if (op_step==3'd0) begin start_write(REG_BitFraming_W, tmp_reg | 8'h80); state<=8'h4F; end
                8'h4F: if (op_done) begin poll_ctr<=0; state<=8'h50; end

                8'h50: if (op_step==3'd0) begin start_read(REG_ComIrq_R); state<=8'h51; end
                8'h51: if (op_done) begin
                    comirq<=tmp_reg;
                    if ((tmp_reg & 8'h33) != 8'h00) begin
                        if ((tmp_reg & 8'h03) != 8'h00) state <= 8'h30;
                        else state <= 8'h60;
                    end else begin
                        poll_ctr <= poll_ctr + 1'b1;
                        if (poll_ctr == TIMEOUT_MAX) begin hard_fault<=1'b1; state<=8'hFF; end
                        else state <= 8'h50;
                    end
                end

                // Check ATQA
                8'h60: if (op_step==3'd0) begin start_read(REG_Error_R);    state<=8'h61; end
                8'h61: if (op_done) begin errreg<=tmp_reg; state<=8'h62; end
                8'h62: if (op_step==3'd0) begin start_read(REG_FIFOLevel_R); state<=8'h63; end
                8'h63: if (op_done) begin fifolvl<=tmp_reg; state<=8'h64; end
                8'h64: begin
                    if (fifolvl < 8'd2) state <= 8'h30;
                    else state <= 8'h65;
                end

                // Burst-read 2 ATQA bytes
                8'h65: begin
                    if (!xfer_active && op_step==3'd0) begin
                        spi_cs_0   <= 1'b0;
                        tx_byte    <= REG_FIFOData_R;
                        start_xfer <= 1'b1;
                        state      <= 8'h66;
                    end
                end
                8'h66: if (xfer_done && !xfer_active) begin
                    tx_byte <= 8'h00; start_xfer <= 1'b1; state <= 8'h67;
                end
                8'h67: if (xfer_done && !xfer_active) begin
                    atqa0   <= rx_byte;
                    tx_byte <= REG_FIFOData_R; start_xfer <= 1'b1; state <= 8'h68;
                end
                8'h68: if (xfer_done && !xfer_active) begin
                    tx_byte <= 8'h00; start_xfer <= 1'b1; state <= 8'h69;
                end
                8'h69: if (xfer_done && !xfer_active) begin
                    atqa1    <= rx_byte;
                    spi_cs_0 <= 1'b1;
                    state    <= 8'h6A;
                end

                8'h6A: if (op_step==3'd0) begin start_read(REG_Control_R); state<=8'h6B; end
                8'h6B: if (op_done) begin ctrlreg<=tmp_reg; state<=8'h6C; end
                8'h6C: begin
                    if ((ctrlreg[2:0] == 3'b000) && (fifolvl == 8'd2)) begin
                        card_seen <= 1'b1; state <= 8'h70;
                    end else state <= 8'h30;
                end

                // ==============================================================
                // ANTICOLLISION (PICC_CMD_SEL_CL1, NVB=0x20)
                // ==============================================================
                8'h70: if (op_step==3'd0) begin start_read(REG_Coll_R);   state<=8'h71; end
                8'h71: if (op_done) begin state<=8'h72; end
                8'h72: if (op_step==3'd0) begin start_write(REG_Coll_W, tmp_reg & 8'h7F); state<=8'h73; end
                8'h73: if (op_done) begin state<=8'h74; end
                8'h74: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Idle); state<=8'h75; end
                8'h75: if (op_done) begin state<=8'h76; end
                8'h76: if (op_step==3'd0) begin start_write(REG_ComIrq_W, 8'h7F);    state<=8'h77; end
                8'h77: if (op_done) begin state<=8'h78; end
                8'h78: if (op_step==3'd0) begin start_write(REG_FIFOLevel_W, 8'h80); state<=8'h79; end
                8'h79: if (op_done) begin state<=8'h7A; end
                8'h7A: if (op_step==3'd0) begin start_write(REG_FIFOData_W, PICC_CMD_SEL_CL1); state<=8'h7B; end
                8'h7B: if (op_done) begin state<=8'h7C; end
                8'h7C: if (op_step==3'd0) begin start_write(REG_FIFOData_W, 8'h20); state<=8'h7D; end
                8'h7D: if (op_done) begin state<=8'h7E; end
                8'h7E: if (op_step==3'd0) begin start_write(REG_BitFraming_W, 8'h00); state<=8'h7F; end
                8'h7F: if (op_done) begin state<=8'h80; end
                8'h80: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Transceive); state<=8'h81; end
                8'h81: if (op_done) begin state<=8'h82; end
                8'h82: if (op_step==3'd0) begin start_read(REG_BitFraming_R); state<=8'h83; end
                8'h83: if (op_done) begin state<=8'h84; end
                8'h84: if (op_step==3'd0) begin start_write(REG_BitFraming_W, tmp_reg | 8'h80); state<=8'h85; end
                8'h85: if (op_done) begin poll_ctr<=0; state<=8'h86; end

                8'h86: if (op_step==3'd0) begin start_read(REG_ComIrq_R); state<=8'h87; end
                8'h87: if (op_done) begin
                    comirq<=tmp_reg;
                    if ((tmp_reg & 8'h33) != 8'h00) begin
                        if ((tmp_reg & 8'h03) != 8'h00) state <= 8'h30;
                        else state <= 8'h89;
                    end else begin
                        poll_ctr <= poll_ctr + 1'b1;
                        if (poll_ctr == TIMEOUT_MAX) state <= 8'h30;
                        else state <= 8'h86;
                    end
                end

                8'h89: if (op_step==3'd0) begin start_read(REG_Error_R);    state<=8'h8A; end
                8'h8A: if (op_done) begin errreg<=tmp_reg; state<=8'h8B; end
                8'h8B: begin
                    if ((errreg & 8'h13) != 8'h00) state <= 8'h30;
                    else state <= 8'h8C;
                end

                8'h8C: if (op_step==3'd0) begin start_read(REG_FIFOLevel_R); state<=8'h8D; end
                8'h8D: if (op_done) begin fifolvl<=tmp_reg; state<=8'h8E; end
                8'h8E: begin
                    if (fifolvl < 8'd5) state <= 8'h30;
                    else state <= 8'h8F;
                end

                // Burst-read UID bytes
                8'h8F: begin
                    if (!xfer_active) begin
                        spi_cs_0   <= 1'b0;
                        tx_byte    <= REG_FIFOData_R;
                        start_xfer <= 1'b1;
                        state      <= 8'h90;
                    end
                end
                8'h90: if (xfer_done && !xfer_active) begin
                    tx_byte <= REG_FIFOData_R; start_xfer<=1'b1; state<=8'h91;
                end
                8'h91: if (xfer_done && !xfer_active) begin
                    uid0    <= rx_byte;
                    tx_byte <= REG_FIFOData_R; start_xfer<=1'b1; state<=8'h92;
                end
                8'h92: if (xfer_done && !xfer_active) begin
                    uid1    <= rx_byte;
                    tx_byte <= REG_FIFOData_R; start_xfer<=1'b1; state<=8'h93;
                end
                8'h93: if (xfer_done && !xfer_active) begin
                    uid2    <= rx_byte;
                    tx_byte <= REG_FIFOData_R; start_xfer<=1'b1; state<=8'h94;
                end
                8'h94: if (xfer_done && !xfer_active) begin
                    uid3    <= rx_byte;
                    tx_byte <= REG_FIFOData_R; start_xfer<=1'b1; state<=8'h95;
                end
                8'h95: if (xfer_done && !xfer_active) begin
                    uid_bcc      <= rx_byte;
                    spi_cs_0     <= 1'b1;
                    state        <= 8'h96;
                end

                8'h96: begin
                    if (uid_bcc == (uid0 ^ uid1 ^ uid2 ^ uid3)) state <= 8'hA0;
                    else state <= 8'h30;
                end

                // ==============================================================
                // SELECT (PICC_CMD_SEL_CL1, NVB=0x70, UID+BCC+CRC)
                // ==============================================================
                8'hA0: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Idle); state<=8'hA1; end
                8'hA1: if (op_done) begin state<=8'hA2; end
                8'hA2: if (op_step==3'd0) begin start_write(REG_DivIrq_W, 8'h04);    state<=8'hA3; end
                8'hA3: if (op_done) begin state<=8'hA4; end
                8'hA4: if (op_step==3'd0) begin start_write(REG_FIFOLevel_W, 8'h80); state<=8'hA5; end
                8'hA5: if (op_done) begin state<=8'hA6; end
                8'hA6: if (op_step==3'd0) begin start_write(REG_FIFOData_W, PICC_CMD_SEL_CL1); state<=8'hA7; end
                8'hA7: if (op_done) begin state<=8'hA8; end
                8'hA8: if (op_step==3'd0) begin start_write(REG_FIFOData_W, 8'h70); state<=8'hA9; end
                8'hA9: if (op_done) begin state<=8'hAA; end
                8'hAA: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid0);  state<=8'hAB; end
                8'hAB: if (op_done) begin state<=8'hAC; end
                8'hAC: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid1);  state<=8'hAD; end
                8'hAD: if (op_done) begin state<=8'hAE; end
                8'hAE: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid2);  state<=8'hAF; end
                8'hAF: if (op_done) begin state<=8'hB0; end
                8'hB0: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid3);  state<=8'hB1; end
                8'hB1: if (op_done) begin state<=8'hB2; end
                8'hB2: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid_bcc); state<=8'hB3; end
                8'hB3: if (op_done) begin state<=8'hB4; end
                8'hB4: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_CalcCRC); state<=8'hB5; end
                8'hB5: if (op_done) begin poll_ctr<=0; state<=8'hB6; end
                8'hB6: if (op_step==3'd0) begin start_read(REG_DivIrq_R); state<=8'hB7; end
                8'hB7: if (op_done) begin
                    if ((tmp_reg & 8'h04) != 8'h00) state <= 8'hB8;
                    else begin
                        poll_ctr <= poll_ctr + 1'b1;
                        if (poll_ctr == TIMEOUT_MAX) state <= 8'h30;
                        else state <= 8'hB6;
                    end
                end
                8'hB8: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Idle); state<=8'hB9; end
                8'hB9: if (op_done) begin state<=8'hBA; end
                8'hBA: if (op_step==3'd0) begin start_read(REG_CRCResultL_R); state<=8'hBB; end
                8'hBB: if (op_done) begin crc_lo<=tmp_reg; state<=8'hBC; end
                8'hBC: if (op_step==3'd0) begin start_read(REG_CRCResultH_R); state<=8'hBD; end
                8'hBD: if (op_done) begin crc_hi<=tmp_reg; state<=8'hC0; end

                8'hC0: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Idle); state<=8'hC1; end
                8'hC1: if (op_done) begin state<=8'hC2; end
                8'hC2: if (op_step==3'd0) begin start_write(REG_ComIrq_W, 8'h7F);    state<=8'hC3; end
                8'hC3: if (op_done) begin state<=8'hC4; end
                8'hC4: if (op_step==3'd0) begin start_write(REG_FIFOLevel_W, 8'h80); state<=8'hC5; end
                8'hC5: if (op_done) begin state<=8'hC6; end
                8'hC6: if (op_step==3'd0) begin start_write(REG_FIFOData_W, PICC_CMD_SEL_CL1); state<=8'hC7; end
                8'hC7: if (op_done) begin state<=8'hC8; end
                8'hC8: if (op_step==3'd0) begin start_write(REG_FIFOData_W, 8'h70); state<=8'hC9; end
                8'hC9: if (op_done) begin state<=8'hCA; end
                8'hCA: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid0);  state<=8'hCB; end
                8'hCB: if (op_done) begin state<=8'hCC; end
                8'hCC: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid1);  state<=8'hCD; end
                8'hCD: if (op_done) begin state<=8'hCE; end
                8'hCE: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid2);  state<=8'hCF; end
                8'hCF: if (op_done) begin state<=8'hD0; end
                8'hD0: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid3);  state<=8'hD1; end
                8'hD1: if (op_done) begin state<=8'hD2; end
                8'hD2: if (op_step==3'd0) begin start_write(REG_FIFOData_W, uid_bcc); state<=8'hD3; end
                8'hD3: if (op_done) begin state<=8'hD4; end
                8'hD4: if (op_step==3'd0) begin start_write(REG_FIFOData_W, crc_lo); state<=8'hD5; end
                8'hD5: if (op_done) begin state<=8'hD6; end
                8'hD6: if (op_step==3'd0) begin start_write(REG_FIFOData_W, crc_hi); state<=8'hD7; end
                8'hD7: if (op_done) begin state<=8'hD8; end
                8'hD8: if (op_step==3'd0) begin start_write(REG_BitFraming_W, 8'h00); state<=8'hD9; end
                8'hD9: if (op_done) begin state<=8'hDA; end
                8'hDA: if (op_step==3'd0) begin start_write(REG_Command_W, PCD_Transceive); state<=8'hDB; end
                8'hDB: if (op_done) begin state<=8'hDC; end
                8'hDC: if (op_step==3'd0) begin start_read(REG_BitFraming_R); state<=8'hDD; end
                8'hDD: if (op_done) begin state<=8'hDE; end
                8'hDE: if (op_step==3'd0) begin start_write(REG_BitFraming_W, tmp_reg | 8'h80); state<=8'hDF; end
                8'hDF: if (op_done) begin poll_ctr<=0; state<=8'hE0; end

                8'hE0: if (op_step==3'd0) begin start_read(REG_ComIrq_R); state<=8'hE1; end
                8'hE1: if (op_done) begin
                    comirq<=tmp_reg;
                    if ((tmp_reg & 8'h33) != 8'h00) begin
                        if ((tmp_reg & 8'h03) != 8'h00) state <= 8'h30;
                        else state <= 8'hE3;
                    end else begin
                        poll_ctr <= poll_ctr + 1'b1;
                        if (poll_ctr == TIMEOUT_MAX) state <= 8'h30;
                        else state <= 8'hE0;
                    end
                end

                8'hE3: if (op_step==3'd0) begin start_read(REG_Error_R); state<=8'hE4; end
                8'hE4: if (op_done) begin errreg<=tmp_reg; state<=8'hE5; end
                8'hE5: begin
                    if ((errreg & 8'h13) != 8'h00) state <= 8'h30;
                    else state <= 8'hE6;
                end

                8'hE6: if (op_step==3'd0) begin start_read(REG_FIFOLevel_R); state<=8'hE7; end
                8'hE7: if (op_done) begin fifolvl<=tmp_reg; state<=8'hE8; end
                8'hE8: begin
                    if (fifolvl < 8'd3) state <= 8'h30;
                    else state <= 8'hE9;
                end

                8'hE9: if (op_step==3'd0) begin start_read(REG_Control_R); state<=8'hEA; end
                8'hEA: if (op_done) begin ctrlreg<=tmp_reg; state<=8'hEB; end
                8'hEB: begin
                    if ((ctrlreg[2:0] != 3'b000) || (fifolvl != 8'd3)) state <= 8'h30;
                    else state <= 8'hEC;
                end

                8'hEC: if (op_step==3'd0) begin start_read(REG_FIFOData_R); state<=8'hED; end
                8'hED: if (op_done) begin sak<=tmp_reg; state<=8'hEE; end

                // ==============================================================
                // SAK check → enter ISO 14443-4 (T=CL) layer
                // ==============================================================
                8'hEE: begin
                    card_uid <= {uid0, uid1, uid2, uid3};
                    if ((sak & 8'h04) != 8'h00) begin
                        // Cascade Level 2 required – not supported
                        hard_fault <= 1'b1;
                        unlock_ms  <= 12'd3000;
                        state      <= 8'hF0;
                    end else begin
                        busy       <= 1'b1;
                        hard_fault <= 1'b0;
                        // Reset APDU state
                        apdu_state   <= APDU_CFG_TXMODE;
                        apdu_idx     <= 4'd0;
                        resp_idx     <= 5'd0;
                        pcb_byte     <= 8'h00;
                        wtxm_byte    <= 8'h00;
                        wtx_pending  <= 1'b0;
                        tx_last_seen <= 1'b0;
                        rx_done_pending <= 1'b0;
                        block_num    <= 1'b0;
                        poll_ctr     <= 32'd0;
                        state        <= 8'hF1;
                    end
                end

                // ==============================================================
                // 8'hF1: ISO 14443-4 (T=CL) APDU exchange sub-machine
                // ==============================================================
                8'hF1: begin
                    case (apdu_state)
                        // --------------------------------------------------------
                        // Config: TxMode=0x80 (TxCRCEn=1, 106 kbps)
                        // --------------------------------------------------------
                        APDU_CFG_TXMODE: begin
                            if (op_step == 3'd0)
                                start_write(REG_TxMode_W, 8'h80);
                            if (op_done) apdu_state <= APDU_CFG_RXMODE;
                        end

                        // RxCRCEn off for ATS (ATS has no CRC).
                        APDU_CFG_RXMODE: begin
                            if (op_step == 3'd0)
                                start_write(REG_RxMode_W, 8'h00);
                            if (op_done) apdu_state <= APDU_CFG_RFCFG;
                        end

                        APDU_CFG_RFCFG: begin
                            if (op_step == 3'd0)
                                start_write(REG_RFCfg_W, 8'h60); // 43 dB gain
                            if (op_done) apdu_state <= APDU_CFG_RXTHRESH;
                        end

                        APDU_CFG_RXTHRESH: begin
                            if (op_step == 3'd0)
                                start_write(REG_RxThreshold_W, 8'h55);
                            if (op_done) apdu_state <= APDU_CFG_TIMER_H;
                        end

                        // APDU timeout ~300 ms (TPrescaler=169, TReload=12000)
                        APDU_CFG_TIMER_H: begin
                            if (op_step == 3'd0)
                                start_write(REG_TReloadH_W, 8'h2E);
                            if (op_done) apdu_state <= APDU_CFG_TIMER_L;
                        end

                        APDU_CFG_TIMER_L: begin
                            if (op_step == 3'd0)
                                start_write(REG_TReloadL_W, 8'hE0);
                            if (op_done) begin
                                delay_ms   <= 8'd5; // short SFGT
                                apdu_state <= APDU_RATS_WAIT_SFGT;
                            end
                        end

                        APDU_RATS_WAIT_SFGT: begin
                            if (ms_tick) begin
                                if (delay_ms != 0) delay_ms <= delay_ms - 1'b1;
                                else apdu_state <= APDU_RATS_IDLE;
                            end
                        end

                        // --------------------------------------------------------
                        // RATS: send E0 50, receive ATS
                        // --------------------------------------------------------
                        APDU_RATS_IDLE: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Idle);
                            if (op_done) apdu_state <= APDU_RATS_IRQ_CLEAR;
                        end

                        APDU_RATS_IRQ_CLEAR: begin
                            if (op_step == 3'd0) start_write(REG_ComIrq_W, 8'h7F);
                            if (op_done) apdu_state <= APDU_RATS_FIFO_FLUSH;
                        end

                        APDU_RATS_FIFO_FLUSH: begin
                            if (op_step == 3'd0) start_write(REG_FIFOLevel_W, 8'h80);
                            if (op_done) begin apdu_idx <= 4'd0; apdu_state <= APDU_RATS_FIFO_WRITE; end
                        end

                        APDU_RATS_FIFO_WRITE: begin
                            if (op_step == 3'd0)
                                start_write(REG_FIFOData_W, rats_byte(apdu_idx[1:0]));
                            if (op_done) begin
                                if (apdu_idx == 4'd1) apdu_state <= APDU_RATS_BITFRAMING;
                                else apdu_idx <= apdu_idx + 1'b1;
                            end
                        end

                        APDU_RATS_BITFRAMING: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h00);
                            if (op_done) apdu_state <= APDU_RATS_CMD;
                        end

                        APDU_RATS_CMD: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Transceive);
                            if (op_done) apdu_state <= APDU_RATS_STARTSEND;
                        end

                        APDU_RATS_STARTSEND: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h80);
                            if (op_done) begin poll_ctr <= 32'd0; apdu_state <= APDU_RATS_POLL_START; end
                        end

                        APDU_RATS_POLL_START: begin
                            if (op_step == 3'd0) begin
                                start_read(REG_ComIrq_R);
                                apdu_state <= APDU_RATS_POLL_WAIT;
                            end
                        end

                        APDU_RATS_POLL_WAIT: begin
                            if (op_done) begin
                                comirq <= tmp_reg;
                                if ((tmp_reg & 8'h33) != 8'h00) begin
                                    if ((tmp_reg & 8'h03) == 8'h01) begin
                                        // FIX 3: TimerIRq alone = card didn't respond to RATS -> soft restart
                                        state <= 8'h30;
                                    end else if ((tmp_reg & 8'h03) != 8'h00) begin
                                        hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                    end else begin
                                        apdu_state <= APDU_RATS_ERR;
                                    end
                                end else begin
                                    poll_ctr <= poll_ctr + 1'b1;
                                    if (poll_ctr == TIMEOUT_MAX) begin hard_fault<=1'b1; state<=8'hFF; end
                                    else apdu_state <= APDU_RATS_POLL_START;
                                end
                            end
                        end

                        APDU_RATS_ERR: begin
                            if (op_done) begin
                                errreg <= tmp_reg;
                                // Ignore CRCErr; fail on collision/overflow.
                                if ((tmp_reg & 8'h18) != 8'h00) begin
                                    hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                end else apdu_state <= APDU_RATS_LEN;
                            end else if (op_step == 3'd0) start_read(REG_Error_R);
                        end

                        APDU_RATS_LEN: begin
                            if (op_done) begin
                                fifolvl <= tmp_reg;
                                // ATS length in FIFO (no CRC).
                                if (tmp_reg < 8'd1) begin
                                    hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                end else begin
                                    resp_idx <= 5'd0; apdu_state <= APDU_RATS_READ;
                                end
                            end else if (op_step == 3'd0) start_read(REG_FIFOLevel_R);
                        end

                        // Read ATS and then enable RxCRCEn for I/S blocks.
                        APDU_RATS_READ: begin
                            if (op_done) begin
                                if (resp_idx == (fifolvl - 8'd1)) begin
                                    apdu_state <= APDU_RATS_RXCRC_ON;
                                end else begin
                                    resp_idx <= resp_idx + 1'b1;
                                end
                            end else if (op_step == 3'd0) start_read(REG_FIFOData_R);
                        end

                        // Enable RxCRCEn after ATS, then configure timer for T=CL and wait SFGT.
                        APDU_RATS_RXCRC_ON: begin
                            if (op_step == 3'd0)
                                start_write(REG_RxMode_W, 8'h80);
                            if (op_done) begin
                                block_num  <= 1'b0;
                                apdu_state <= APDU_CFG2_TMODE;
                            end
                        end

                        // FIX 2a: re-write TMode (TAuto) and TPrescaler explicitly for APDU phase.
                        // Init already set these but being explicit avoids any chip-state ambiguity.
                        APDU_CFG2_TMODE: begin
                            if (op_step == 3'd0)
                                start_write(REG_TMode_W, 8'h80);   // TAuto=1
                            if (op_done) apdu_state <= APDU_CFG2_TPRESCALER;
                        end

                        APDU_CFG2_TPRESCALER: begin
                            if (op_step == 3'd0)
                                start_write(REG_TPrescaler_W, 8'hA9); // prescaler=169 -> ~50us/tick
                            if (op_done) begin
                                // FIX 2b: post-ATS start-up frame guard time (SFGT).
                                // ATS TC1=0x02 -> SFGT multiplier=4 -> ~4.8ms minimum.
                                // Use 10ms for margin.
                                delay_ms   <= 8'd10;
                                apdu_state <= APDU_ATS_SFGT_WAIT;
                            end
                        end

                        // FIX 2b: wait after ATS before first APDU.
                        APDU_ATS_SFGT_WAIT: begin
                            if (ms_tick) begin
                                if (delay_ms != 0) delay_ms <= delay_ms - 1'b1;
                                else apdu_state <= APDU_LINK_IDLE;
                            end
                        end

                        // --------------------------------------------------------
                        // Link idle: wait for APDU payload from external core
                        // --------------------------------------------------------
                        APDU_LINK_IDLE: begin
                            if (!busy_in && app_tx_valid) begin
                                tx_last_seen    <= 1'b0;
                                rx_done_pending <= 1'b0;
                                wtx_pending     <= 1'b0;
                                apdu_state      <= APDU_TX_IDLE;
                            end
                        end

                        APDU_TX_IDLE: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Idle);
                            if (op_done) apdu_state <= APDU_TX_IRQ_CLEAR;
                        end

                        APDU_TX_IRQ_CLEAR: begin
                            if (op_step == 3'd0) start_write(REG_ComIrq_W, 8'h7F);
                            if (op_done) apdu_state <= APDU_TX_FIFO_FLUSH;
                        end

                        APDU_TX_FIFO_FLUSH: begin
                            if (op_step == 3'd0) start_write(REG_FIFOLevel_W, 8'h80);
                            if (op_done) apdu_state <= APDU_TX_WRITE_PCB;
                        end

                        APDU_TX_WRITE_PCB: begin
                            if (op_step == 3'd0)
                                start_write(REG_FIFOData_W, 8'h02 | {7'b0, block_num});
                            if (op_done) apdu_state <= APDU_TX_WRITE_PAYLOAD;
                        end

                        APDU_TX_WRITE_PAYLOAD: begin
                            if (!tx_last_seen && op_step == 3'd0 && !busy_in) begin
                                app_tx_ready <= 1'b1;
                                if (app_tx_valid) begin
                                    start_write(REG_FIFOData_W, app_tx_byte);
                                    if (app_tx_last) tx_last_seen <= 1'b1;
                                end
                            end
                            if (op_done && tx_last_seen)
                                apdu_state <= APDU_TX_BITFRAMING;
                        end

                        APDU_TX_BITFRAMING: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h00);
                            if (op_done) apdu_state <= APDU_TX_CMD;
                        end

                        APDU_TX_CMD: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Transceive);
                            if (op_done) apdu_state <= APDU_TX_STARTSEND;
                        end

                        APDU_TX_STARTSEND: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h80);
                            if (op_done) begin poll_ctr <= 32'd0; apdu_state <= APDU_TX_POLL_START; end
                        end

                        APDU_TX_POLL_START: begin
                            if (op_step == 3'd0) begin
                                start_read(REG_ComIrq_R);
                                apdu_state <= APDU_TX_POLL_WAIT;
                            end
                        end

                        APDU_TX_POLL_WAIT: begin
                            if (op_done) begin
                                comirq <= tmp_reg;
                                if ((tmp_reg & 8'h33) != 8'h00) begin
                                    if ((tmp_reg & 8'h03) == 8'h01) begin
                                        // FIX 3: TimerIRq alone = card didn't respond to APDU -> soft restart
                                        // op_step is 0 here (op_done just fired), safe to jump to poll loop
                                        state <= 8'h30;
                                    end else if ((tmp_reg & 8'h03) != 8'h00) begin
                                        hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                    end else begin
                                        apdu_state <= APDU_RX_ERR;
                                    end
                                end else begin
                                    poll_ctr <= poll_ctr + 1'b1;
                                    if (poll_ctr == TIMEOUT_MAX) begin hard_fault<=1'b1; state<=8'hFF; end
                                    else apdu_state <= APDU_TX_POLL_START;
                                end
                            end
                        end

                        APDU_RX_ERR: begin
                            if (op_done) begin
                                errreg <= tmp_reg;
                                // Accept CRCErr; fail on collision/overflow.
                                if ((tmp_reg & 8'h18) != 8'h00) begin
                                    hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                end else apdu_state <= APDU_RX_LEN;
                            end else if (op_step == 3'd0) start_read(REG_Error_R);
                        end

                        APDU_RX_LEN: begin
                            if (op_done) begin
                                fifolvl <= tmp_reg;
                                // min 2 bytes: S(WTX) = [PCB][WTXM]
                                // min 3 bytes for I-block: [PCB][SW1][SW2]
                                // We allow 2 here; APDU_RX_READ checks PCB type.
                                if (tmp_reg < 8'd2) begin
                                    hard_fault <= 1'b1; unlock_ms <= 12'd3000; state <= 8'hF0;
                                end else begin
                                    resp_idx        <= 5'd0;
                                    wtx_pending     <= 1'b0;
                                    rx_done_pending <= 1'b0;
                                    apdu_state      <= APDU_RX_READ;
                                end
                            end else if (op_step == 3'd0) start_read(REG_FIFOLevel_R);
                        end

                        // CRC stripped by MFRC522 (RxCRCEn=1).
                        // PCB at idx 0; payload bytes start at idx 1.
                        APDU_RX_READ: begin
                            if (!app_rx_valid && op_step == 3'd0)
                                start_read(REG_FIFOData_R);
                            if (op_done) begin
                                if (resp_idx == 5'd0) begin
                                    pcb_byte    <= tmp_reg;
                                    wtx_pending <= ((tmp_reg & 8'hF7) == 8'hF2);
                                end else begin
                                    if (wtx_pending) begin
                                        if (resp_idx == 5'd1)
                                            wtxm_byte <= tmp_reg;
                                    end else begin
                                        app_rx_valid <= 1'b1;
                                        app_rx_byte  <= tmp_reg;
                                        app_rx_last  <= (resp_idx == (fifolvl - 8'd1));
                                    end
                                end

                                if (resp_idx == (fifolvl - 8'd1)) begin
                                    if (wtx_pending) begin
                                        apdu_idx   <= 4'd0;
                                        apdu_state <= APDU_WTX_IDLE;
                                    end else begin
                                        rx_done_pending <= 1'b1;
                                    end
                                end

                                resp_idx <= resp_idx + 1'b1;
                            end
                            if (rx_done_pending && app_rx_valid && app_rx_ready) begin
                                rx_done_pending <= 1'b0;
                                block_num <= ~block_num;
                                apdu_state <= APDU_LINK_IDLE;
                            end
                        end

                        APDU_WTX_IDLE: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Idle);
                            if (op_done) apdu_state <= APDU_WTX_FIFO_FLUSH;
                        end

                        APDU_WTX_FIFO_FLUSH: begin
                            if (op_step == 3'd0) start_write(REG_FIFOLevel_W, 8'h80);
                            if (op_done) begin apdu_idx <= 4'd0; apdu_state <= APDU_WTX_WRITE; end
                        end

                        APDU_WTX_WRITE: begin
                            if (op_step == 3'd0) begin
                                if (apdu_idx == 4'd0)
                                    start_write(REG_FIFOData_W, 8'hF2); // S(WTX) PCB
                                else
                                    start_write(REG_FIFOData_W, wtxm_byte & 8'h3F); // WTXM (bits 5-0)
                            end
                            if (op_done) begin
                                if (apdu_idx == 4'd1) apdu_state <= APDU_WTX_BITFRAMING;
                                else apdu_idx <= apdu_idx + 1'b1;
                            end
                        end

                        APDU_WTX_BITFRAMING: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h00);
                            if (op_done) apdu_state <= APDU_WTX_CMD;
                        end

                        APDU_WTX_CMD: begin
                            if (op_step == 3'd0) start_write(REG_Command_W, PCD_Transceive);
                            if (op_done) apdu_state <= APDU_WTX_STARTSEND;
                        end

                        APDU_WTX_STARTSEND: begin
                            if (op_step == 3'd0) start_write(REG_BitFraming_W, 8'h80);
                            if (op_done) begin
                                poll_ctr   <= 32'd0;
                                resp_idx   <= 5'd0;
                                wtx_pending <= 1'b0;
                                apdu_state <= APDU_TX_POLL_START;
                            end
                        end

                        default: apdu_state <= APDU_CFG_TXMODE;
                    endcase
                end // 8'hF1

                // ==============================================================
                // Fault hold → re-poll after delay
                // ==============================================================
                8'hF0: begin
                    if (ms_tick) begin
                        if (unlock_ms != 0) unlock_ms <= unlock_ms - 1'b1;
                        else begin
                            hard_fault <= 1'b0;
                            card_seen  <= 1'b0;
                            state      <= 8'h30;
                        end
                    end
                end

                // ==============================================================
                // Permanent halt
                // ==============================================================
                8'hFF: begin
                    state <= 8'hFF;
                end

                default: state <= 8'h00;

            endcase
            end
        end
    end

endmodule