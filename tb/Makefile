VERILATOR  = verilator
VFLAGS     = -Wall --cc --exe --build --trace -j 0
RTL_COMMON = ../rtl/common
RTL_PARSER = ../rtl/parser

.PHONY: all skid gearbox parser clean

all: skid gearbox parser

skid: $(RTL_COMMON)/axis_skid_buffer.sv tb_skid_buffer.cpp
	$(VERILATOR) $(VFLAGS) --Mdir obj_skid $^ -o sim_skid
	./obj_skid/sim_skid

gearbox: $(RTL_COMMON)/axis_gearbox_8_to_64.sv tb_gearbox_8_to_64.cpp
	$(VERILATOR) $(VFLAGS) --Mdir obj_gearbox $^ -o sim_gearbox
	./obj_gearbox/sim_gearbox

parser: $(RTL_PARSER)/eth_ipv4_udp_parser.sv tb_eth_ipv4_udp_parser.cpp
	$(VERILATOR) $(VFLAGS) --Mdir obj_parser $^ -o sim_parser
	./obj_parser/sim_parser

clean:
	rm -rf obj_* *.vcd
