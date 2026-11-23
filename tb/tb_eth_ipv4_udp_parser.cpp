#include <iostream>
#include <iomanip>
#include <vector>
#include <queue>
#include <cstdlib>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Veth_ipv4_udp_parser.h"

struct Beat {
    uint64_t data;
    uint8_t  keep;
    uint8_t  last;
};

// 构造完整以太网帧 (14B Eth + 20B IPv4 + 8B UDP + Payload)
std::vector<uint8_t> build_frame(uint16_t eth_type, uint8_t ip_proto,
                                 uint16_t dst_port, const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> frame;
    // 1. Ethernet Header (14B)
    uint8_t dst_mac[6] = {0x01, 0x00, 0x5E, 0x00, 0x00, 0x01};
    uint8_t src_mac[6] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55};
    frame.insert(frame.end(), dst_mac, dst_mac + 6);
    frame.insert(frame.end(), src_mac, src_mac + 6);
    frame.push_back((eth_type >> 8) & 0xFF);
    frame.push_back(eth_type & 0xFF);

    // 2. IPv4 Header (20B)
    uint16_t ip_len = 20 + 8 + payload.size();
    frame.push_back(0x45); // Ver=4, IHL=5
    frame.push_back(0x00); // TOS
    frame.push_back((ip_len >> 8) & 0xFF);
    frame.push_back(ip_len & 0xFF);
    frame.push_back(0x00); frame.push_back(0x01); // ID
    frame.push_back(0x40); frame.push_back(0x00); // Flags/Frag
    frame.push_back(64);                          // TTL
    frame.push_back(ip_proto);                    // Protocol
    frame.push_back(0x00); frame.push_back(0x00); // Checksum
    uint8_t src_ip[4] = {192, 168, 1, 10};
    uint8_t dst_ip[4] = {239, 1, 1, 1};
    frame.insert(frame.end(), src_ip, src_ip + 4);
    frame.insert(frame.end(), dst_ip, dst_ip + 4);

    // 3. UDP Header (8B)
    uint16_t udp_len = 8 + payload.size();
    uint16_t src_port = 54321;
    frame.push_back((src_port >> 8) & 0xFF);
    frame.push_back(src_port & 0xFF);
    frame.push_back((dst_port >> 8) & 0xFF);
    frame.push_back(dst_port & 0xFF);
    frame.push_back((udp_len >> 8) & 0xFF);
    frame.push_back(udp_len & 0xFF);
    frame.push_back(0x00); frame.push_back(0x00); // UDP Checksum = 0

    // 4. Payload
    frame.insert(frame.end(), payload.begin(), payload.end());
    return frame;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Veth_ipv4_udp_parser* dut = new Veth_ipv4_udp_parser;
    VerilatedVcdC* tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("dump_parser.vcd");

    uint64_t sim_time = 0;
    auto half_tick = [&](uint8_t clk_val) {
        dut->clk = clk_val;
        dut->eval();
        tfp->dump(sim_time++);
    };

    // 准备 8 个混合测试包（合法行情包 + 各种干扰垃圾包）
    struct TestCase {
        uint16_t eth_type;
        uint8_t  ip_proto;
        uint16_t dst_port;
        int      payload_len;
        uint8_t  seed_byte;
    };

    std::vector<TestCase> tests = {
        {0x0800, 17, 12345, 11, 0xA0}, // #1 合法包：11B 载荷 (走 PAYLOAD + FLUSH)
        {0x0806, 17, 12345, 18, 0x10}, // #2 干扰包：ARP 帧 (Beat 1 丢弃)
        {0x0800, 17, 12345,  6, 0xB0}, // #3 合法包：6B 极短载荷 (Beat 5 直跳 FLUSH)
        {0x0800, 17, 12346, 20, 0x20}, // #4 干扰包：错误端口 (Beat 4 丢弃)
        {0x0800, 17, 12345,  8, 0xC0}, // #5 合法包：8B 整除载荷 (Beat 6 直接结束)
        {0x0800,  6, 12345, 22, 0x30}, // #6 干扰包：TCP 帧 (Beat 2 丢弃)
        {0x0800, 17, 12345,  0, 0x40}, // #7 合法空包：0B 载荷 (不输出任何拍)
        {0x0800, 17, 12345, 20, 0xD0}  // #8 合法长包：20B 载荷 (3 拍输出)
    };

    std::queue<Beat> in_beats;
    std::queue<Beat> exp_out_beats;

    for (const auto& tc : tests) {
        std::vector<uint8_t> payload;
        for (int i = 0; i < tc.payload_len; ++i) {
            payload.push_back(tc.seed_byte + i);
        }
        auto frame = build_frame(tc.eth_type, tc.ip_proto, tc.dst_port, payload);

        // 切分成输入 64-bit Beats
        for (size_t i = 0; i < frame.size(); i += 8) {
            Beat b{0, 0, 0};
            for (size_t slot = 0; slot < 8 && (i + slot) < frame.size(); ++slot) {
                b.data |= (static_cast<uint64_t>(frame[i + slot]) << (slot * 8));
                b.keep |= (1 << slot);
            }
            if (i + 8 >= frame.size()) b.last = 1;
            in_beats.push(b);
        }

        // 若为合法目标包且有载荷，生成黄金预期输出 Beats
        if (tc.eth_type == 0x0800 && tc.ip_proto == 17 && tc.dst_port == 12345 && !payload.empty()) {
            for (size_t i = 0; i < payload.size(); i += 8) {
                Beat b{0, 0, 0};
                for (size_t slot = 0; slot < 8 && (i + slot) < payload.size(); ++slot) {
                    b.data |= (static_cast<uint64_t>(payload[i + slot]) << (slot * 8));
                    b.keep |= (1 << slot);
                }
                if (i + 8 >= payload.size()) b.last = 1;
                exp_out_beats.push(b);
            }
        }
    }

    int total_exp_beats = exp_out_beats.size();

    // 复位
    dut->rst_n    = 0;
    dut->s_tvalid = 0;
    dut->s_tdata  = 0;
    dut->s_tkeep  = 0;
    dut->s_tlast  = 0;
    dut->m_tready = 0;
    for (int i = 0; i < 2; ++i) {
        half_tick(0);
        half_tick(1);
    }
    dut->rst_n = 1;

    srand(2026);
    bool hold_valid = false;

    for (int cycle = 0; cycle < 400; ++cycle) {
        half_tick(0);

        dut->m_tready = (cycle < 15) ? 1 : (rand() % 10 < 7);

        if (!hold_valid) {
            if (!in_beats.empty() && (rand() % 10 < 8)) {
                Beat b = in_beats.front();
                dut->s_tvalid = 1;
                dut->s_tdata  = b.data;
                dut->s_tkeep  = b.keep;
                dut->s_tlast  = b.last;
            } else {
                dut->s_tvalid = 0;
                dut->s_tlast  = 0;
            }
        }

        dut->eval();

        // 上游握手检查
        if (dut->s_tvalid) {
            if (dut->s_tready) {
                in_beats.pop();
                hold_valid = false;
            } else {
                hold_valid = true;
            }
        }

        // 下游输出比对
        if (dut->m_tvalid && dut->m_tready) {
            if (exp_out_beats.empty()) {
                std::cerr << "[FAIL] Cycle " << cycle << ": 收到多余的未过滤数据 data=0x"
                          << std::hex << dut->m_tdata << std::dec << "\n";
                return 1;
            }
            Beat exp = exp_out_beats.front();
            exp_out_beats.pop();

            if (dut->m_tdata != exp.data || dut->m_tkeep != exp.keep || dut->m_tlast != exp.last) {
                std::cerr << "[FAIL] Cycle " << cycle << " 解析剥离结果错误！\n"
                          << "  期望: data=0x" << std::hex << exp.data
                          << " keep=0x" << (int)exp.keep << " last=" << (int)exp.last << "\n"
                          << "  实际: data=0x" << dut->m_tdata
                          << " keep=0x" << (int)dut->m_tkeep << " last=" << (int)dut->m_tlast
                          << std::dec << "\n";
                return 1;
            }
        }

        half_tick(1);
    }

    if (!in_beats.empty() || !exp_out_beats.empty()) {
        std::cerr << "[FAIL] 仿真结束仍有残留未处理数据！in=" << in_beats.size()
                  << " exp_out=" << exp_out_beats.size() << "\n";
        return 1;
    }

    std::cout << "[PASS] Ethernet/IPv4/UDP Parser verified! Filtered 4 junk frames and extracted all "
              << total_exp_beats << " aligned payload beats cleanly!\n";

    dut->final();
    tfp->close();
    delete tfp;
    delete dut;
    return 0;
}
