// =============================================================================
// layr_core.v
// APDU payload handler for MFRC522 ISO14443-4 link.
// Implements AUTH_INIT / AUTH / GET_ID protocol using AES and CTR-based nonces.
// =============================================================================

module layr_core #(
    parameter integer CLK_HZ = 32_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire       busy_in,

    // 128-bit pre-shared key + 64-bit counter loaded from EEPROM
    input  wire [127:0] psk_key,
    input  wire [63:0]  psk_counter,
    input  wire         psk_counter_valid,
    input  wire [767:0] allowed_ids,
    input  wire         allowed_ids_valid,

    input  wire       link_ready,

    output reg        app_tx_valid,
    output reg  [7:0] app_tx_byte,
    output reg        app_tx_last,
    input  wire       app_tx_ready,

    input  wire       app_rx_valid,
    input  wire [7:0] app_rx_byte,
    input  wire       app_rx_last,
    output reg        app_rx_ready,

    output reg        restart_link,
    output reg        unlock,
    output reg        busy,
    output reg        fault,

    // Key rollover: request EEPROM write of newly negotiated key
    output reg        key_write_req,
    output reg [127:0] key_write_data,
    input  wire       key_write_done,
    // Counter persistence: request EEPROM write of updated counter
    output reg        counter_write_req,
    output reg [63:0] counter_write_data,
    input  wire       counter_write_done
);

    // -------------------------------------------------------------------------
    // 1 ms tick generator
    // -------------------------------------------------------------------------
    localparam integer MS_DIV = CLK_HZ / 1000;
    reg [$clog2(MS_DIV)-1:0] ms_cnt = 0;
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

    // -------------------------------------------------------------------------
    // APDU payload helpers
    // -------------------------------------------------------------------------
    // SELECT AID APDU includes Le=0x00 at index 11 (12 bytes total)
    function [7:0] select_apdu_byte;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  select_apdu_byte = 8'h00; // CLA
                4'd1:  select_apdu_byte = 8'hA4; // INS
                4'd2:  select_apdu_byte = 8'h04; // P1
                4'd3:  select_apdu_byte = 8'h00; // P2
                4'd4:  select_apdu_byte = 8'h06; // Lc
                4'd5:  select_apdu_byte = 8'hF0; // AID[0]
                4'd6:  select_apdu_byte = 8'h00; // AID[1]
                4'd7:  select_apdu_byte = 8'h00; // AID[2]
                4'd8:  select_apdu_byte = 8'h0C; // AID[3]
                4'd9:  select_apdu_byte = 8'hDC; // AID[4]
                4'd10: select_apdu_byte = 8'h01; // AID[5]
                4'd11: select_apdu_byte = 8'h00; // Le
                default: select_apdu_byte = 8'h00;
            endcase
        end
    endfunction

    function [7:0] auth_init_cmd_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: auth_init_cmd_byte = 8'h80; // CLA
                3'd1: auth_init_cmd_byte = 8'h10; // INS
                3'd2: auth_init_cmd_byte = 8'h00; // P1
                3'd3: auth_init_cmd_byte = 8'h00; // P2
                3'd4: auth_init_cmd_byte = 8'h10; // Le (16 bytes)
                default: auth_init_cmd_byte = 8'h00;
            endcase
        end
    endfunction

    function [7:0] get_id_cmd_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_id_cmd_byte = 8'h80; // CLA
                3'd1: get_id_cmd_byte = 8'h12; // INS
                3'd2: get_id_cmd_byte = 8'h00; // P1
                3'd3: get_id_cmd_byte = 8'h00; // P2
                3'd4: get_id_cmd_byte = 8'h10; // Le (16 bytes)
                default: get_id_cmd_byte = 8'h00;
            endcase
        end
    endfunction

    function [7:0] get_new_key_cmd_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: get_new_key_cmd_byte = 8'h80; // CLA
                3'd1: get_new_key_cmd_byte = 8'h21; // INS
                3'd2: get_new_key_cmd_byte = 8'h00; // P1
                3'd3: get_new_key_cmd_byte = 8'h00; // P2
                3'd4: get_new_key_cmd_byte = 8'h10; // Le (16 bytes)
                default: get_new_key_cmd_byte = 8'h00;
            endcase
        end
    endfunction

    function [7:0] be_byte;
        input [127:0] data;
        input [4:0]   idx;
        begin
            be_byte = data[127 - (idx * 8) -: 8];
        end
    endfunction

    function [127:0] id_slot;
        input [2:0] idx;
        begin
            id_slot = allowed_ids[767 - (idx * 128) -: 128];
        end
    endfunction

    function id_in_list;
        input [127:0] id;
        integer i;
        reg match;
        begin
            match = 1'b0;
            for (i = 0; i < 6; i = i + 1) begin
                if (id_slot(i[2:0]) != 128'h0 && id_slot(i[2:0]) == id)
                    match = 1'b1;
            end
            id_in_list = match;
        end
    endfunction

    // -------------------------------------------------------------------------
    // AES core
    // -------------------------------------------------------------------------
    reg         aes_start;
    reg         aes_mode; // 0=encrypt, 1=decrypt
    reg [127:0] aes_key;
    reg [127:0] aes_block_in;
    wire [127:0] aes_block_out;
    wire        aes_done;

    aes_core u_aes (
        .clk      (clk),
        .rst_n    (~rst),
        .start    (aes_start),
        .mode     (aes_mode),
        .key      (aes_key),
        .block_in (aes_block_in),
        .block_out(aes_block_out),
        .done     (aes_done)
    );

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    localparam [4:0] ST_IDLE            = 5'd0;
    localparam [4:0] ST_SEND_SELECT     = 5'd1;
    localparam [4:0] ST_WAIT_SELECT     = 5'd2;
    localparam [4:0] ST_AUTH_INIT_SEND  = 5'd3;
    localparam [4:0] ST_AUTH_INIT_WAIT  = 5'd4;
    localparam [4:0] ST_DEC_RC_START    = 5'd5;
    localparam [4:0] ST_DEC_RC_WAIT     = 5'd6;
    localparam [4:0] ST_GEN_RT_REQ      = 5'd7;
    localparam [4:0] ST_GEN_RT_WAIT     = 5'd8;
    localparam [4:0] ST_ENC_AUTH_START  = 5'd9;
    localparam [4:0] ST_ENC_AUTH_WAIT   = 5'd10;
    localparam [4:0] ST_AUTH_SEND       = 5'd11;
    localparam [4:0] ST_AUTH_WAIT       = 5'd12;
    localparam [4:0] ST_DEC_AUTH_START  = 5'd13;
    localparam [4:0] ST_DEC_AUTH_WAIT   = 5'd14;
    localparam [4:0] ST_GET_ID_SEND     = 5'd15;
    localparam [4:0] ST_GET_ID_WAIT     = 5'd16;
    localparam [4:0] ST_DEC_ID_START    = 5'd17;
    localparam [4:0] ST_DEC_ID_WAIT     = 5'd18;
    localparam [4:0] ST_SUCCESS_HOLD       = 5'd19;
    localparam [4:0] ST_FAIL_HOLD          = 5'd20;
    // Key rollover states
    localparam [4:0] ST_GET_NEW_KEY_SEND   = 5'd21;
    localparam [4:0] ST_GET_NEW_KEY_WAIT   = 5'd22;
    localparam [4:0] ST_DEC_NEW_KEY_START  = 5'd23;
    localparam [4:0] ST_DEC_NEW_KEY_WAIT   = 5'd24;
    localparam [4:0] ST_WRITE_KEY_REQ      = 5'd25;
    localparam [4:0] ST_WRITE_KEY_WAIT     = 5'd26;
    // Counter write-back states
    localparam [4:0] ST_WRITE_CTR_REQ      = 5'd27;
    localparam [4:0] ST_WRITE_CTR_WAIT     = 5'd28;

    reg [4:0] state = ST_IDLE;

    reg [4:0] tx_idx = 5'd0;
    reg [5:0] rx_count = 6'd0;
    reg [5:0] expected_len = 6'd0;

    reg [7:0] sw1 = 8'h00;
    reg [7:0] sw2 = 8'h00;

    reg [127:0] auth_init_cipher = 128'h0;
    reg [127:0] auth_cipher      = 128'h0;
    reg [127:0] auth_resp_cipher = 128'h0;
    reg [127:0] get_id_cipher    = 128'h0;
    reg [127:0] k_eph            = 128'h0;
    reg [127:0] card_id_plain    = 128'h0;
    reg [127:0] new_key_cipher   = 128'h0;
    reg         new_key_pending  = 1'b0;

    reg [63:0] rc = 64'h0;
    reg [63:0] rt = 64'h0;
    reg [63:0] counter_reg = 64'h0;
    reg        counter_loaded = 1'b0;
    reg        counter_dirty  = 1'b0;

    reg [11:0] hold_ms = 12'd0;
    reg [5:0]  select_warmup = 6'd0;
    reg        link_seen = 1'b0;
    localparam [127:0] AUTH_SUCCESS = 128'h415554485F5355434345535300000000;

    // -------------------------------------------------------------------------
    // Main clocked process
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst || !enable) begin
            state         <= ST_IDLE;
            tx_idx        <= 5'd0;
            rx_count      <= 6'd0;
            expected_len  <= 6'd0;
            sw1           <= 8'h00;
            sw2           <= 8'h00;
            auth_init_cipher <= 128'h0;
            auth_cipher      <= 128'h0;
            auth_resp_cipher <= 128'h0;
            get_id_cipher    <= 128'h0;
            k_eph            <= 128'h0;
            card_id_plain    <= 128'h0;
            rc            <= 64'h0;
            rt            <= 64'h0;
            hold_ms       <= 12'd0;
            select_warmup <= 6'd0;
            link_seen    <= 1'b0;

            app_tx_valid  <= 1'b0;
            app_tx_byte   <= 8'h00;
            app_tx_last   <= 1'b0;
            app_rx_ready  <= 1'b0;
            restart_link  <= 1'b0;

            aes_start      <= 1'b0;
            aes_mode       <= 1'b0;
            aes_key        <= psk_key;
            aes_block_in   <= 128'h0;

            key_write_req  <= 1'b0;
            key_write_data <= 128'h0;
            counter_write_req  <= 1'b0;
            counter_write_data <= 64'h0;
            new_key_pending <= 1'b0;
            new_key_cipher  <= 128'h0;
            counter_reg     <= 64'h0;
            counter_loaded  <= 1'b0;
            counter_dirty   <= 1'b0;

            unlock        <= 1'b0;
            busy          <= 1'b0;
            fault         <= 1'b0;
        end else begin
            // Defaults
            app_tx_valid  <= 1'b0;
            app_tx_byte   <= 8'h00;
            app_tx_last   <= 1'b0;
            app_rx_ready  <= 1'b0;
            restart_link  <= 1'b0;
            aes_start     <= 1'b0;
            key_write_req <= 1'b0;
            counter_write_req <= 1'b0;
            busy          <= 1'b1;
            unlock        <= 1'b0;
            fault         <= 1'b0;

            if (!counter_loaded && psk_counter_valid) begin
                counter_reg    <= psk_counter;
                counter_loaded <= 1'b1;
            end
            if (counter_write_done) begin
                counter_dirty <= 1'b0;
            end
            if (link_ready) begin
                link_seen <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    unlock <= 1'b0;
                    fault  <= 1'b0;
                    busy   <= 1'b0;
                    if (link_ready && !busy_in) begin
                        tx_idx       <= 5'd0;
                        rx_count     <= 6'd0;
                        expected_len <= 6'd0;
                        auth_init_cipher <= 128'h0;
                        auth_cipher      <= 128'h0;
                        get_id_cipher    <= 128'h0;
                        state        <= ST_SEND_SELECT;
                    end
                end

                ST_SEND_SELECT: begin
                    busy         <= 1'b1;
                    app_tx_valid <= !busy_in;
                    app_tx_byte  <= select_apdu_byte(tx_idx[3:0]);
                    app_tx_last  <= (tx_idx == 5'd11);
                    if (!busy_in && app_tx_ready) begin
                        if (tx_idx == 5'd11) begin
                            tx_idx       <= 5'd0;
                            rx_count     <= 6'd0;
                            expected_len <= 6'd0;
                            sw1          <= 8'h00;
                            sw2          <= 8'h00;
                            state        <= ST_WAIT_SELECT;
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                        end
                    end
                end

                ST_WAIT_SELECT: begin
                    busy         <= 1'b1;
                    app_rx_ready <= !busy_in;
                    if (!busy_in && app_rx_valid && app_rx_ready) begin
                        if (rx_count == 6'd0) sw1 <= app_rx_byte;
                        if (rx_count == 6'd1) sw2 <= app_rx_byte;
                        rx_count <= rx_count + 1'b1;
                        if (app_rx_last) begin
                            if (rx_count == 6'd1 && sw1 == 8'h90 && app_rx_byte == 8'h00) begin
                                tx_idx <= 5'd0;
                                select_warmup <= 6'd30; // ~30 ms warmup to avoid HCE cold-start drop
                                state  <= ST_AUTH_INIT_SEND;
                            end else begin
                                fault   <= 1'b1;
                                hold_ms <= 12'd3000;
                                state   <= ST_FAIL_HOLD;
                            end
                        end
                    end
                end

                ST_AUTH_INIT_SEND: begin
                    busy         <= 1'b1;
                    if (select_warmup != 0) begin
                        if (ms_tick) begin
                            select_warmup <= select_warmup - 1'b1;
                        end
                    end else begin
                    app_tx_valid <= !busy_in;
                    app_tx_byte  <= auth_init_cmd_byte(tx_idx[2:0]);
                    app_tx_last  <= (tx_idx == 5'd4);
                    if (!busy_in && app_tx_ready) begin
                        if (tx_idx == 5'd4) begin
                            tx_idx       <= 5'd0;
                            rx_count     <= 6'd0;
                            expected_len <= 6'd16;
                            sw1          <= 8'h00;
                            sw2          <= 8'h00;
                            auth_init_cipher <= 128'h0;
                            state        <= ST_AUTH_INIT_WAIT;
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                        end
                    end
                    end
                end

                ST_AUTH_INIT_WAIT: begin
                    busy         <= 1'b1;
                    app_rx_ready <= !busy_in;
                    if (!busy_in && app_rx_valid && app_rx_ready) begin
                        if (rx_count < expected_len)
                            auth_init_cipher <= {auth_init_cipher[119:0], app_rx_byte};
                        if (rx_count == expected_len) sw1 <= app_rx_byte;
                        if (rx_count == (expected_len + 1'b1)) sw2 <= app_rx_byte;
                        if (app_rx_last) begin
                            if (rx_count == (expected_len + 1'b1) && sw1 == 8'h90 && app_rx_byte == 8'h00) begin
                                state <= ST_DEC_RC_START;
                            end else begin
                                fault   <= 1'b1;
                                hold_ms <= 12'd3000;
                                state   <= ST_FAIL_HOLD;
                            end
                        end
                        rx_count <= rx_count + 1'b1;
                    end
                end

                ST_DEC_RC_START: begin
                    busy         <= 1'b1;
                    aes_key      <= psk_key;
                    aes_block_in <= auth_init_cipher;
                    aes_mode     <= 1'b1; // decrypt
                    aes_start    <= 1'b1;
                    state        <= ST_DEC_RC_WAIT;
                end

                ST_DEC_RC_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        rc    <= aes_block_out[127:64];
                        state <= ST_GEN_RT_REQ;
                    end
                end

                ST_GEN_RT_REQ: begin
                    busy <= 1'b1;
                    if (counter_loaded) begin
                        aes_key      <= psk_key;
                        aes_block_in <= {64'h0, counter_reg};
                        aes_mode     <= 1'b0; // encrypt
                        aes_start    <= 1'b1;
                        state        <= ST_GEN_RT_WAIT;
                    end
                end

                ST_GEN_RT_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        rt           <= aes_block_out[63:0];
                        k_eph        <= {rc, aes_block_out[63:0]};
                        counter_reg  <= counter_reg + 1'b1;
                        counter_dirty<= 1'b1;
                        state        <= ST_ENC_AUTH_START;
                    end
                end

                ST_ENC_AUTH_START: begin
                    busy         <= 1'b1;
                    aes_key      <= psk_key;
                    aes_block_in <= {rt, rc};
                    aes_mode     <= 1'b0; // encrypt
                    aes_start    <= 1'b1;
                    state        <= ST_ENC_AUTH_WAIT;
                end

                ST_ENC_AUTH_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        auth_cipher <= aes_block_out;
                        tx_idx      <= 5'd0;
                        state       <= ST_AUTH_SEND;
                    end
                end

                ST_AUTH_SEND: begin
                    busy         <= 1'b1;
                    app_tx_valid <= !busy_in;
                    app_tx_last  <= (tx_idx == 5'd20);
                    if (tx_idx == 5'd0) app_tx_byte <= 8'h80;
                    else if (tx_idx == 5'd1) app_tx_byte <= 8'h11;
                    else if (tx_idx == 5'd2) app_tx_byte <= 8'h00;
                    else if (tx_idx == 5'd3) app_tx_byte <= 8'h00;
                    else if (tx_idx == 5'd4) app_tx_byte <= 8'h10; // Lc
                    else app_tx_byte <= be_byte(auth_cipher, tx_idx - 5'd5);

                    if (!busy_in && app_tx_ready) begin
                        if (tx_idx == 5'd20) begin
                            tx_idx       <= 5'd0;
                            rx_count     <= 6'd0;
                            expected_len <= 6'd16; // 16-byte AUTH status message + SW1/SW2
                            sw1          <= 8'h00;
                            sw2          <= 8'h00;
                            auth_resp_cipher <= 128'h0;
                            state        <= ST_AUTH_WAIT;
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                        end
                    end
                end

                ST_AUTH_WAIT: begin
                    busy         <= 1'b1;
                    app_rx_ready <= !busy_in;
                    if (!busy_in && app_rx_valid && app_rx_ready) begin
                        if (rx_count < expected_len)
                            auth_resp_cipher <= {auth_resp_cipher[119:0], app_rx_byte};
                        if (rx_count == expected_len) sw1 <= app_rx_byte;
                        if (rx_count == (expected_len + 1'b1)) sw2 <= app_rx_byte;
                        if (app_rx_last) begin
                            if (rx_count == (expected_len + 1'b1) && sw1 == 8'h90 && app_rx_byte == 8'h00) begin
                                state <= ST_DEC_AUTH_START;
                            end else begin
                                fault   <= 1'b1;
                                hold_ms <= 12'd3000;
                                state   <= ST_FAIL_HOLD;
                            end
                        end
                        rx_count <= rx_count + 1'b1;
                    end
                end

                ST_DEC_AUTH_START: begin
                    busy <= 1'b1;
                    aes_key      <= k_eph;
                    aes_block_in <= auth_resp_cipher;
                    aes_mode     <= 1'b1; // decrypt
                    aes_start    <= 1'b1;
                    state        <= ST_DEC_AUTH_WAIT;
                end

                ST_DEC_AUTH_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        if (aes_block_out == AUTH_SUCCESS) begin
                            state  <= ST_GET_ID_SEND;
                            tx_idx <= 5'd0;
                        end else begin
                            fault   <= 1'b1;
                            hold_ms <= 12'd3000;
                            state   <= ST_FAIL_HOLD;
                        end
                    end
                end

                ST_GET_ID_SEND: begin
                    busy         <= 1'b1;
                    app_tx_valid <= !busy_in;
                    app_tx_byte  <= get_id_cmd_byte(tx_idx[2:0]);
                    app_tx_last  <= (tx_idx == 5'd4);
                    if (!busy_in && app_tx_ready) begin
                        if (tx_idx == 5'd4) begin
                            tx_idx       <= 5'd0;
                            rx_count     <= 6'd0;
                            expected_len <= 6'd16;
                            sw1          <= 8'h00;
                            sw2          <= 8'h00;
                            get_id_cipher <= 128'h0;
                            state        <= ST_GET_ID_WAIT;
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                        end
                    end
                end

                ST_GET_ID_WAIT: begin
                    busy         <= 1'b1;
                    app_rx_ready <= !busy_in;
                    if (!busy_in && app_rx_valid && app_rx_ready) begin
                        if (rx_count < expected_len)
                            get_id_cipher <= {get_id_cipher[119:0], app_rx_byte};
                        if (rx_count == expected_len) sw1 <= app_rx_byte;
                        if (rx_count == (expected_len + 1'b1)) sw2 <= app_rx_byte;
                        if (app_rx_last) begin
                            if (rx_count == (expected_len + 1'b1) && sw1 == 8'h90 &&
                                    (app_rx_byte == 8'h00 || app_rx_byte == 8'h01)) begin
                                new_key_pending <= (app_rx_byte == 8'h01);
                                state <= ST_DEC_ID_START;
                            end else begin
                                fault   <= 1'b1;
                                hold_ms <= 12'd3000;
                                state   <= ST_FAIL_HOLD;
                            end
                        end
                        rx_count <= rx_count + 1'b1;
                    end
                end

                ST_DEC_ID_START: begin
                    busy         <= 1'b1;
                    aes_key      <= k_eph;
                    aes_block_in <= get_id_cipher;
                    aes_mode     <= 1'b1; // decrypt
                    aes_start    <= 1'b1;
                    state        <= ST_DEC_ID_WAIT;
                end

                ST_DEC_ID_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        card_id_plain <= aes_block_out;
                        if (!allowed_ids_valid || !id_in_list(aes_block_out)) begin
                            fault   <= 1'b1;
                            hold_ms <= 12'd3000;
                            state   <= ST_FAIL_HOLD;
                        end else if (new_key_pending) begin
                            tx_idx         <= 5'd0;
                            rx_count       <= 6'd0;
                            expected_len   <= 6'd16;
                            sw1            <= 8'h00;
                            sw2            <= 8'h00;
                            new_key_cipher <= 128'h0;
                            state          <= ST_GET_NEW_KEY_SEND;
                        end else begin
                            unlock  <= 1'b1;
                            hold_ms <= 12'd3000;
                            state   <= ST_SUCCESS_HOLD;
                        end
                    end
                end

                ST_SUCCESS_HOLD: begin
                    busy   <= 1'b0;
                    fault  <= 1'b0;
                    unlock <= 1'b1;
                    if (ms_tick) begin
                        if (hold_ms != 0)
                            hold_ms <= hold_ms - 1'b1;
                        else begin
                            unlock <= 1'b0;
                            if (counter_dirty) begin
                                state <= ST_WRITE_CTR_REQ;
                            end else begin
                                restart_link <= 1'b1;
                                state  <= ST_IDLE;
                            end
                        end
                    end
                end

                ST_FAIL_HOLD: begin
                    busy   <= 1'b0;
                    fault  <= 1'b1;
                    unlock <= 1'b0;
                    if (ms_tick) begin
                        if (hold_ms != 0)
                            hold_ms <= hold_ms - 1'b1;
                        else begin
                            fault <= 1'b0;
                            if (counter_dirty) begin
                                state <= ST_WRITE_CTR_REQ;
                            end else begin
                                restart_link <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end
                end

                // -----------------------------------------------------------------
                // Key rollover
                // -----------------------------------------------------------------
                ST_GET_NEW_KEY_SEND: begin
                    busy         <= 1'b1;
                    app_tx_valid <= !busy_in;
                    app_tx_byte  <= get_new_key_cmd_byte(tx_idx[2:0]);
                    app_tx_last  <= (tx_idx == 5'd4);
                    if (!busy_in && app_tx_ready) begin
                        if (tx_idx == 5'd4) begin
                            tx_idx       <= 5'd0;
                            rx_count     <= 6'd0;
                            expected_len <= 6'd16;
                            sw1          <= 8'h00;
                            sw2          <= 8'h00;
                            new_key_cipher <= 128'h0;
                            state        <= ST_GET_NEW_KEY_WAIT;
                        end else begin
                            tx_idx <= tx_idx + 1'b1;
                        end
                    end
                end

                ST_GET_NEW_KEY_WAIT: begin
                    busy         <= 1'b1;
                    app_rx_ready <= !busy_in;
                    if (!busy_in && app_rx_valid && app_rx_ready) begin
                        if (rx_count < expected_len)
                            new_key_cipher <= {new_key_cipher[119:0], app_rx_byte};
                        if (rx_count == expected_len) sw1 <= app_rx_byte;
                        if (rx_count == (expected_len + 1'b1)) sw2 <= app_rx_byte;
                        if (app_rx_last) begin
                            if (rx_count == (expected_len + 1'b1) && sw1 == 8'h90 && app_rx_byte == 8'h00) begin
                                state <= ST_DEC_NEW_KEY_START;
                            end else begin
                                fault   <= 1'b1;
                                hold_ms <= 12'd3000;
                                state   <= ST_FAIL_HOLD;
                            end
                        end
                        rx_count <= rx_count + 1'b1;
                    end
                end

                ST_DEC_NEW_KEY_START: begin
                    busy         <= 1'b1;
                    aes_key      <= k_eph;
                    aes_block_in <= new_key_cipher;
                    aes_mode     <= 1'b1; // decrypt
                    aes_start    <= 1'b1;
                    state        <= ST_DEC_NEW_KEY_WAIT;
                end

                ST_DEC_NEW_KEY_WAIT: begin
                    busy <= 1'b1;
                    if (aes_done) begin
                        key_write_data <= aes_block_out;
                        state          <= ST_WRITE_KEY_REQ;
                    end
                end

                ST_WRITE_KEY_REQ: begin
                    busy <= 1'b1;
                    key_write_req <= 1'b1;
                    state <= ST_WRITE_KEY_WAIT;
                end

                // Excluded from !link_ready escape guard: EEPROM write must
                // complete even if the NFC link drops (MFRC reset by eeprom_busy).
                ST_WRITE_KEY_WAIT: begin
                    busy <= 1'b1;
                    if (key_write_done) begin
                        new_key_pending <= 1'b0;
                        unlock  <= 1'b1;
                        hold_ms <= 12'd3000;
                        state   <= ST_SUCCESS_HOLD;
                    end
                end

                ST_WRITE_CTR_REQ: begin
                    busy <= 1'b1;
                    restart_link <= 1'b1;
                    counter_write_data <= counter_reg;
                    counter_write_req  <= 1'b1;
                    state <= ST_WRITE_CTR_WAIT;
                end

                ST_WRITE_CTR_WAIT: begin
                    busy <= 1'b1;
                    if (counter_write_done) begin
                        restart_link <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            if (!link_ready &&
                    (state != ST_SUCCESS_HOLD) &&
                    (state != ST_FAIL_HOLD) &&
                    (state != ST_DEC_NEW_KEY_START) &&
                    (state != ST_DEC_NEW_KEY_WAIT) &&
                    (state != ST_WRITE_KEY_REQ) &&
                    (state != ST_WRITE_KEY_WAIT) &&
                    (state != ST_WRITE_CTR_REQ) &&
                    (state != ST_WRITE_CTR_WAIT) &&
                    link_seen) begin
                // Soft reset on link drop: no fault, restart link for a clean retry.
                state         <= ST_IDLE;
                unlock        <= 1'b0;
                fault         <= 1'b0;
                busy          <= 1'b0;
                tx_idx        <= 5'd0;
                rx_count      <= 6'd0;
                expected_len  <= 6'd0;
                select_warmup <= 6'd0;
                link_seen     <= 1'b0;
                restart_link  <= 1'b1;
            end

        end
    end

endmodule
