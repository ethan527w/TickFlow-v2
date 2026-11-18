VERILATOR_FLAGS = -Wall --cc --exe --build --trace -j 0

.PHONY: skid gearbox clean

skid:
	verilator $(VERILATOR_FLAGS) ../rtl/common/axis_skid_buffer.sv tb_skid_buffer.cpp -o sim_skid
	./obj_dir/sim_skid

gearbox:
	verilator $(VERILATOR_FLAGS) ../rtl/common/axis_gearbox_8_to_64.sv tb_gearbox_8_to_64.cpp -o sim_gearbox
	./obj_dir/sim_gearbox

clean:
	rm -rf obj_dir *.vcd
