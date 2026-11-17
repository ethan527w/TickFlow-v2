TOP_MODULE = axis_skid_buffer
RTL_SRCS   = ../rtl/common/axis_skid_buffer.sv
TB_SRC     = tb_skid_buffer.cpp

sim:
	verilator -Wall --cc --exe --build --trace \
		-j 0 \
		--top-module $(TOP_MODULE) \
		$(RTL_SRCS) $(TB_SRC)
	./obj_dir/V$(TOP_MODULE)

wave:
	gtkwave dump.vcd &

clean:
	rm -rf obj_dir dump.vcd