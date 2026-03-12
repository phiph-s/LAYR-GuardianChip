TOP = ulx3s_test_top
OUT = ulx3s_rc522_min

DEVICE  = 85k
PACKAGE = CABGA381
FREQ    = 25
LPF     = ulx3s.lpf

RTL = \
  ulx3s_test_top.v \
  ../src/user_rtl/ip/canright-aes-sboxes/verilog/sbox.verilog \
  ../src/user_rtl/rtl/mfrc522_apdu_interface.v \
  ../src/user_rtl/rtl/at25010_interface.v \
  ../src/user_rtl/rtl/layr_core.v \
  ../src/user_rtl/rtl/aes_core.v \
  ../src/user_rtl/rtl/aes_small/aes_iterative.v \
  ../src/user_rtl/rtl/spi_master.v

all: $(OUT).bit

$(OUT).json: $(RTL)
	yosys -p "read_verilog -sv $(RTL); synth_ecp5 -top $(TOP) -json $@"

$(OUT).config: $(OUT).json $(LPF)
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) \
		--json $(OUT).json --lpf $(LPF) --textcfg $@ --freq $(FREQ)

$(OUT).bit: $(OUT).config
	ecppack --compress $< $@

prog: $(OUT).bit
	sudo fujprog $<

clean:
	rm -f *.json *.config *.bit

.PHONY: all clean prog
