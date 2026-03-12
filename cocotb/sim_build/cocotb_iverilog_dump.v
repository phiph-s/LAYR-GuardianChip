module cocotb_iverilog_dump();
initial begin
    string dumpfile_path;    if ($value$plusargs("dumpfile_path=%s", dumpfile_path)) begin
        $dumpfile(dumpfile_path);
    end else begin
        $dumpfile("/home/phiph/Downloads/OCDCPro-padframe-main/24/cocotb/sim_build/layr_core.fst");
    end
    $dumpvars(0, layr_core);
end
endmodule
