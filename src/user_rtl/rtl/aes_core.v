// =============================================================================
// aes_core.v
// Wrapper for compact iterative AES-128 implementation.
// =============================================================================

module aes_core (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,        // Start encryption/decryption
  input  logic         mode,         // 0=encrypt, 1=decrypt
  input  logic [127:0] key,
  input  logic [127:0] block_in,
  output logic [127:0] block_out,
  output logic         done          // Operation complete
);

  aes_iterative u_aes_iter (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (start),
    .mode     (mode),
    .key      (key),
    .block_in (block_in),
    .block_out(block_out),
    .done     (done)
  );

endmodule
