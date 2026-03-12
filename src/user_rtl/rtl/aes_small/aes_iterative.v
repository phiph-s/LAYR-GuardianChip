// =============================================================================
// aes_iterative.v
// Compact iterative AES-128 core (encrypt/decrypt, one round per cycle).


// =============================================================================

module aes_iterative (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        mode,       // 0=encrypt, 1=decrypt
    input  wire [127:0] key,
    input  wire [127:0] block_in,
    output reg  [127:0] block_out,
    output reg         done
);

    // -------------------------------------------------------------------------
    // GF(2^8) helpers
    // -------------------------------------------------------------------------
    function [7:0] xtime;
        input [7:0] a;
        begin
            xtime = {a[6:0], 1'b0} ^ (8'h1b & {8{a[7]}});
        end
    endfunction

    function [7:0] mul2;
        input [7:0] a;
        begin
            mul2 = xtime(a);
        end
    endfunction

    function [7:0] mul3;
        input [7:0] a;
        begin
            mul3 = xtime(a) ^ a;
        end
    endfunction

    function [7:0] mul9;
        input [7:0] a;
        begin
            mul9 = xtime(xtime(xtime(a))) ^ a;
        end
    endfunction

    function [7:0] mul11;
        input [7:0] a;
        begin
            mul11 = xtime(xtime(xtime(a)) ^ a) ^ a;
        end
    endfunction

    function [7:0] mul13;
        input [7:0] a;
        begin
            mul13 = xtime(xtime(xtime(a) ^ a)) ^ a;
        end
    endfunction

    function [7:0] mul14;
        input [7:0] a;
        begin
            mul14 = xtime(xtime(xtime(a) ^ a) ^ a);
        end
    endfunction

    // -------------------------------------------------------------------------
    // State transforms
    // -------------------------------------------------------------------------
    function [127:0] shiftrows_state;
        input [127:0] s;
        reg [7:0] b [0:15];
        begin
            b[0]  = s[127:120]; b[1]  = s[119:112]; b[2]  = s[111:104]; b[3]  = s[103:96];
            b[4]  = s[95:88];   b[5]  = s[87:80];   b[6]  = s[79:72];   b[7]  = s[71:64];
            b[8]  = s[63:56];   b[9]  = s[55:48];   b[10] = s[47:40];   b[11] = s[39:32];
            b[12] = s[31:24];   b[13] = s[23:16];   b[14] = s[15:8];    b[15] = s[7:0];

            shiftrows_state = {
                b[0],  b[5],  b[10], b[15],
                b[4],  b[9],  b[14], b[3],
                b[8],  b[13], b[2],  b[7],
                b[12], b[1],  b[6],  b[11]
            };
        end
    endfunction

    function [127:0] inv_shiftrows_state;
        input [127:0] s;
        reg [7:0] b [0:15];
        begin
            b[0]  = s[127:120]; b[1]  = s[119:112]; b[2]  = s[111:104]; b[3]  = s[103:96];
            b[4]  = s[95:88];   b[5]  = s[87:80];   b[6]  = s[79:72];   b[7]  = s[71:64];
            b[8]  = s[63:56];   b[9]  = s[55:48];   b[10] = s[47:40];   b[11] = s[39:32];
            b[12] = s[31:24];   b[13] = s[23:16];   b[14] = s[15:8];    b[15] = s[7:0];

            inv_shiftrows_state = {
                b[0],  b[13], b[10], b[7],
                b[4],  b[1],  b[14], b[11],
                b[8],  b[5],  b[2],  b[15],
                b[12], b[9],  b[6],  b[3]
            };
        end
    endfunction

    function [31:0] mixcol;
        input [31:0] c;
        reg [7:0] b0, b1, b2, b3;
        begin
            b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
            mixcol = { mul2(b0) ^ mul3(b1) ^ b2 ^ b3,
                       b0 ^ mul2(b1) ^ mul3(b2) ^ b3,
                       b0 ^ b1 ^ mul2(b2) ^ mul3(b3),
                       mul3(b0) ^ b1 ^ b2 ^ mul2(b3) };
        end
    endfunction

    function [31:0] inv_mixcol;
        input [31:0] c;
        reg [7:0] b0, b1, b2, b3;
        begin
            b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
            inv_mixcol = { mul14(b0) ^ mul11(b1) ^ mul13(b2) ^ mul9(b3),
                           mul9(b0) ^ mul14(b1) ^ mul11(b2) ^ mul13(b3),
                           mul13(b0) ^ mul9(b1) ^ mul14(b2) ^ mul11(b3),
                           mul11(b0) ^ mul13(b1) ^ mul9(b2) ^ mul14(b3) };
        end
    endfunction

    function [127:0] mixcolumns_state;
        input [127:0] s;
        begin
            mixcolumns_state = {
                mixcol(s[127:96]),
                mixcol(s[95:64]),
                mixcol(s[63:32]),
                mixcol(s[31:0])
            };
        end
    endfunction

    function [127:0] inv_mixcolumns_state;
        input [127:0] s;
        begin
            inv_mixcolumns_state = {
                inv_mixcol(s[127:96]),
                inv_mixcol(s[95:64]),
                inv_mixcol(s[63:32]),
                inv_mixcol(s[31:0])
            };
        end
    endfunction

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    reg [127:0] round_keys [0:10];
    reg [127:0] state;
    reg [3:0]   round;
    reg         active;
    reg         key_expanding;
    reg [3:0]   key_exp_round;  // next round key index to compute (1..10)
    reg         mode_reg;
    reg [127:0] block_in_lat;   // block_in latched at start

    integer k;

    // -------------------------------------------------------------------------
    // S-Box wiring (Canright)
    // -------------------------------------------------------------------------
    wire [127:0] enc_subbytes;
    wire [127:0] enc_shiftrows;
    wire [127:0] enc_mixcolumns;
    wire [127:0] enc_final;

    wire [127:0] dec_shiftrows;
    wire [127:0] dec_subbytes;
    wire [127:0] dec_addroundkey;
    wire [127:0] dec_mixcolumns;
    wire [127:0] dec_final;

    aes_sbox128 u_enc_sbox (
        .in_bytes (state),
        .out_bytes(enc_subbytes)
    );

    assign enc_shiftrows  = shiftrows_state(enc_subbytes);
    assign enc_mixcolumns = mixcolumns_state(enc_shiftrows);
    assign enc_final      = enc_shiftrows ^ round_keys[10];

    assign dec_shiftrows  = inv_shiftrows_state(state);
    aes_inv_sbox128 u_dec_sbox (
        .in_bytes (dec_shiftrows),
        .out_bytes(dec_subbytes)
    );

    assign dec_addroundkey = dec_subbytes ^ round_keys[round];
    assign dec_mixcolumns  = inv_mixcolumns_state(dec_addroundkey);
    assign dec_final       = dec_subbytes ^ round_keys[0];

    // -------------------------------------------------------------------------
    // Key schedule (Canright S-Box)
    // -------------------------------------------------------------------------
    wire [127:0] key_sched_in;
    wire [3:0]   key_sched_rnd;
    wire [127:0] key_sched_next;

    assign key_sched_in  = round_keys[key_exp_round - 1'b1];
    assign key_sched_rnd = key_exp_round;

    aes_key_schedule_step u_key_sched (
        .cur_rk (key_sched_in),
        .rnd    (key_sched_rnd),
        .next_rk(key_sched_next)
    );

    // -------------------------------------------------------------------------
    // Control
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= 128'h0;
            block_out     <= 128'h0;
            block_in_lat  <= 128'h0;
            round         <= 4'd0;
            active        <= 1'b0;
            key_expanding <= 1'b0;
            key_exp_round <= 4'd0;
            mode_reg      <= 1'b0;
            done          <= 1'b0;
            for (k = 0; k < 11; k = k + 1)
                round_keys[k] <= 128'h0;
        end else begin
            done <= 1'b0;

            if (key_expanding) begin
                // Iterative key schedule: one round key per cycle.
                // Combinatorial depth is only one key_schedule_step (~8 LUT levels),
                // versus the old always @* which chained all 10 steps combinatorially.
                round_keys[key_exp_round] <= key_sched_next;

                if (key_exp_round == 4'd10) begin
                    key_expanding <= 1'b0;
                    active        <= 1'b1;
                    if (!mode_reg) begin
                        // Encryption: initial AddRoundKey with round_keys[0]
                        state <= block_in_lat ^ round_keys[0];
                        round <= 4'd1;
                    end else begin
                        // Decryption: initial AddRoundKey with round_keys[10].
                        // round_keys[10] is being written this cycle; use the
                        // combinatorial result directly to avoid a one-cycle stall.
                        state <= block_in_lat ^ key_sched_next;
                        round <= 4'd9;
                    end
                end else begin
                    key_exp_round <= key_exp_round + 1'b1;
                end

            end else if (start && !active) begin
                // Latch inputs and begin iterative key expansion
                round_keys[0]  <= key;
                block_in_lat   <= block_in;
                key_exp_round  <= 4'd1;
                key_expanding  <= 1'b1;
                mode_reg       <= mode;

            end else if (active) begin
                if (!mode_reg) begin
                    // Encryption rounds
                    if (round <= 4'd9) begin
                        state <= enc_mixcolumns ^ round_keys[round];
                        round <= round + 1'b1;
                    end else begin
                        state     <= enc_final;
                        block_out <= enc_final;
                        done      <= 1'b1;
                        active    <= 1'b0;
                    end
                end else begin
                    // Decryption rounds
                    if (round >= 4'd1) begin
                        state <= dec_mixcolumns;
                        round <= round - 1'b1;
                    end else begin
                        state     <= dec_final;
                        block_out <= dec_final;
                        done      <= 1'b1;
                        active    <= 1'b0;
                    end
                end
            end
        end
    end

endmodule

// -----------------------------------------------------------------------------
// Canright S-Box wrappers
// -----------------------------------------------------------------------------
module aes_sbox_byte (
    input  wire [7:0] in_byte,
    output wire [7:0] out_byte
);
    bSbox u_sbox (
        .A      (in_byte),
        .encrypt(1'b1),
        .Q      (out_byte)
    );
endmodule

module aes_inv_sbox_byte (
    input  wire [7:0] in_byte,
    output wire [7:0] out_byte
);
    bSbox u_sbox (
        .A      (in_byte),
        .encrypt(1'b0),
        .Q      (out_byte)
    );
endmodule

module aes_sbox32 (
    input  wire [31:0] in_word,
    output wire [31:0] out_word
);
    aes_sbox_byte u0(.in_byte(in_word[31:24]), .out_byte(out_word[31:24]));
    aes_sbox_byte u1(.in_byte(in_word[23:16]), .out_byte(out_word[23:16]));
    aes_sbox_byte u2(.in_byte(in_word[15:8]),  .out_byte(out_word[15:8]));
    aes_sbox_byte u3(.in_byte(in_word[7:0]),   .out_byte(out_word[7:0]));
endmodule

module aes_sbox128 (
    input  wire [127:0] in_bytes,
    output wire [127:0] out_bytes
);
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_sbox
            aes_sbox_byte u_sb (
                .in_byte (in_bytes[127 - i*8 -: 8]),
                .out_byte(out_bytes[127 - i*8 -: 8])
            );
        end
    endgenerate
endmodule

module aes_inv_sbox128 (
    input  wire [127:0] in_bytes,
    output wire [127:0] out_bytes
);
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_inv_sbox
            aes_inv_sbox_byte u_sb (
                .in_byte (in_bytes[127 - i*8 -: 8]),
                .out_byte(out_bytes[127 - i*8 -: 8])
            );
        end
    endgenerate
endmodule

// -----------------------------------------------------------------------------
// Key schedule step using Canright S-Box
// -----------------------------------------------------------------------------
module aes_key_schedule_step (
    input  wire [127:0] cur_rk,
    input  wire [3:0]   rnd,
    output wire [127:0] next_rk
);
    wire [31:0] rot_word;
    wire [31:0] sub_word;
    wire [31:0] rcon_word;
    wire [31:0] temp;
    wire [31:0] w0, w1, w2, w3;

    assign rot_word = {cur_rk[23:0], cur_rk[31:24]};
    aes_sbox32 u_subword (.in_word(rot_word), .out_word(sub_word));

    assign rcon_word = (rnd == 4'd1)  ? 32'h01000000 :
                       (rnd == 4'd2)  ? 32'h02000000 :
                       (rnd == 4'd3)  ? 32'h04000000 :
                       (rnd == 4'd4)  ? 32'h08000000 :
                       (rnd == 4'd5)  ? 32'h10000000 :
                       (rnd == 4'd6)  ? 32'h20000000 :
                       (rnd == 4'd7)  ? 32'h40000000 :
                       (rnd == 4'd8)  ? 32'h80000000 :
                       (rnd == 4'd9)  ? 32'h1b000000 :
                       (rnd == 4'd10) ? 32'h36000000 :
                                       32'h00000000;

    assign temp = sub_word ^ rcon_word;
    assign w0 = cur_rk[127:96] ^ temp;
    assign w1 = cur_rk[95:64]  ^ w0;
    assign w2 = cur_rk[63:32]  ^ w1;
    assign w3 = cur_rk[31:0]   ^ w2;

    assign next_rk = {w0, w1, w2, w3};
endmodule
