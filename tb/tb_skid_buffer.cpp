#include <iostream>
#include <iomanip>
#include <queue>
#include <cassert>
#include <cstdlib>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vaxis_skid_buffer.h"

struct AxisBeat
{
    uint64_t data;
    uint8_t keep;
    uint8_t last;
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(1);

    Vaxis_skid_buffer *dut = new Vaxis_skid_buffer;
    VerilatedVcdC *tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("dump.vcd");

    uint64_t sim_time = 0;
    std::queue<AxisBeat> expected_q;

    // auxiliary function
    auto half_tick = [&](uint8_t clk_val)
    {
        dut->clk = clk_val;
        dut->eval();
        tfp->dump(sim_time++);
    };

    // =========================================
    // Test Start - reset
    //==========================================

    dut->rst_n = 0;
    dut->s_tvalid = 0;
    dut->s_tdata = 0;
    dut->s_tkeep = 0;
    dut->s_tlast = 0;
    dut->m_tready = 0;

    for (int i = 0; i < 2; ++i)
    {
        half_tick(0);
        half_tick(1);
    }
    dut->rst_n = 1;

    // =========================================
    // Test - backpressure & ramdom data*200
    //==========================================
    srand(325799);
    uint64_t next_tx_data = 0x1000;
    bool can_send_new = 1;

    // downstream
    for (int cycle = 0; cycle < 200; ++cycle)
    {
        half_tick(0); // negedge

        if (cycle < 10)
        {
            dut->m_tready = 1;
        }
        else if (cycle >= 10 && cycle <= 12)
        {
            dut->m_tready = 0;
        }
        else
        {
            dut->m_tready = rand() % 2;
        }

        // upstream
        if (can_send_new)
        {
            if (rand() % 10 < 8) // 80% to send a data, 20% send nothing
            {
                dut->s_tvalid = 1;
                dut->s_tdata = next_tx_data++;
                dut->s_tkeep = 0xFF;
                dut->s_tlast = (next_tx_data % 4 == 0) ? 1 : 0;
            }
            else
            {
                dut->s_tvalid = 0;
                dut->s_tlast = 0;
            }
        }

        // eval
        dut->eval();

        // examination - upstream
        if (dut->s_tvalid)
        {
            if (dut->s_tready)
            {
                expected_q.push({dut->s_tdata, dut->s_tkeep, dut->s_tlast});
                can_send_new = 1;
            }
            else
            {
                can_send_new = 0;
            }
        }
        else
        {
            can_send_new = 1;
        }

        // examination - downstream
        if (dut->m_tvalid && dut->m_tready)
        {
            if (expected_q.empty())
            {
                std::cerr << "[FAIL] Cycle " << cycle << ": 下游凭空多收了无效数据！\n";
                return 1;
            }
            AxisBeat exp = expected_q.front();
            expected_q.pop();

            if (dut->m_tdata != exp.data || dut->m_tkeep != exp.keep || dut->m_tlast != exp.last)
            {
                std::cerr << "[FAIL] Cycle " << cycle << " 数据不匹配！\n"
                          << "  期望 data = 0x" << std::hex << exp.data
                          << ", 实际 data = 0x" << dut->m_tdata << std::dec << "\n";
                return 1;
            }
        }

        half_tick(1);
    }

    // Ending
    std::cout << "[PASS] 200 cycles verified with zero errors! "
              << "(In-flight beats remaining in buffer: " << expected_q.size() << ")\n";

    dut->final();
    tfp->close();
    delete tfp;
    delete dut;
    return 0;
}