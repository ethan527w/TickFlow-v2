#include <iostream>
#include <iomanip>
#include <queue>
#include <cstdlib>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vaxis_gearbox_8_to_64.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vaxis_gearbox_8_to_64* dut = new Vaxis_gearbox_8_to_64;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("dump_gearbox.vcd");

    uint64_t sim_time = 0;
    auto half_tick = [&](uint8_t clk_val) {
        dut->clk = clk_val;
        dut->eval();
        tfp->dump(sim_time++);
    };

    // expected queue
    std::queue<uint8_t> exp_byte_q;
    std::queue<bool>    exp_last_q;

    // reset
    dut->rst_n    = 0;
    dut->s_tvalid = 0;
    dut->s_tdata  = 0;
    dut->s_tlast  = 0;
    dut->m_tready = 0;
    for (int i = 0; i < 2; ++i) {
        half_tick(0);
        half_tick(1);
    }
    dut->rst_n = 1;

    // multiple packets with different length
    // including: 3bytes, 8, 13, 1, 60(min ethernet)
    int pkt_lengths[] = {3, 2, 5, 7, 99, 32, 57, 9};
    int total_pkts = sizeof(pkt_lengths) / sizeof(pkt_lengths[0]);
    int pkt_idx = 0;
    int byte_in_pkt = 0;
    uint8_t byte_val = 0x10;
    bool can_send_new = true;

    srand(1024);

    for (int cycle = 0; cycle < 300; ++cycle) {
        half_tick(0);

        // backpressure where probability of occuring = 0.6
        dut->m_tready = (cycle < 20) ? 1 : (rand() % 10 < 6);

        // upstream
        if (can_send_new) {
            if (pkt_idx < total_pkts && (rand() % 10 < 8)) {
                dut->s_tvalid = 1;
                dut->s_tdata  = byte_val++;
                dut->s_tlast  = (byte_in_pkt == pkt_lengths[pkt_idx] - 1) ? 1 : 0;
            } else {
                dut->s_tvalid = 0;
                dut->s_tlast  = 0;
            }
        }

        dut->eval();

        // monitor s_fire at upstream
        if (dut->s_tvalid) {
            if (dut->s_tready) {
                exp_byte_q.push(dut->s_tdata);
                exp_last_q.push(dut->s_tlast != 0);
                can_send_new = true;

                // move ptr inside the exp queue
                byte_in_pkt++;
                if (byte_in_pkt == pkt_lengths[pkt_idx]) {
                    byte_in_pkt = 0;
                    pkt_idx++;
                }
            } else {
                can_send_new = false;
            }
        } else {
            can_send_new = true;
        }

        // examination & monitor the downstream m_fire
        if (dut->m_tvalid && dut->m_tready) {
            uint64_t exp_data = 0;
            uint8_t  exp_keep = 0;
            uint8_t  exp_last = 0;

            for (int slot = 0; slot < 8; ++slot) {
                if (exp_byte_q.empty()) {
                    std::cerr << "[FAIL] Cycle " << cycle << ": 下游多收了空数据！\n";
                    return 1;
                }
                uint8_t b = exp_byte_q.front(); exp_byte_q.pop();
                bool is_l = exp_last_q.front(); exp_last_q.pop();

                exp_data |= (static_cast<uint64_t>(b) << (slot * 8));
                exp_keep |= (1 << slot);
                if (is_l) {
                    exp_last = 1;
                    break; // early stop
                }
            }

            if (dut->m_tdata != exp_data || dut->m_tkeep != exp_keep || dut->m_tlast != exp_last) {
                std::cerr << "[FAIL] Cycle " << cycle << " packege not matching\n"
                          << "  Expect: data=0x" << std::hex << exp_data
                          << " keep=0x" << (int)exp_keep << " last=" << (int)exp_last << "\n"
                          << "  Actual: data=0x" << dut->m_tdata
                          << " keep=0x" << (int)dut->m_tkeep << " last=" << (int)dut->m_tlast
                          << std::dec << "\n";
                return 1;
            }
        }

        half_tick(1);
    }

    if (!exp_byte_q.empty()) {
        std::cerr << "[FAIL] still " << exp_byte_q.size() << " bytes not sending\n";
        return 1;
    }

    std::cout << "[PASS] Gearbox 8-to-64 verified! All " << total_pkts
              << " packets (aligned & unaligned) packed with zero errors!\n";

    dut->final();
    tfp->close();
    delete tfp;
    delete dut;
    return 0;
}