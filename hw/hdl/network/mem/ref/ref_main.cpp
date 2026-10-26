// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "dummy_memory_reparam.hpp"

#define WIDTH 512

static std::vector<unsigned char> from_hex(const std::string &s) {
    std::vector<unsigned char> v;
    v.reserve(s.size() / 2);
    for (size_t i = 0; i + 1 < s.size(); i += 2) {
        v.push_back((unsigned char)strtoul(s.substr(i, 2).c_str(), nullptr, 16));
    }
    return v;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <ref_trace.txt> <ref_golden.txt>\n", argv[0]);
        return 2;
    }
    std::ifstream in(argv[1]);
    std::ofstream out(argv[2]);
    if (!in) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    dummyMemory<WIDTH> mem;
    std::string line;
    long nw = 0, nr = 0;

    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string op;
        ss >> op;
        if (op == "W") {
            unsigned long saddr;
            std::string hex;
            ss >> saddr >> hex;
            std::vector<unsigned char> payload = from_hex(hex);
            mem.setWriteCmd(mmCmd((ap_uint<32>)saddr, (ap_uint<16>)payload.size()));
            size_t off = 0;
            while (off < payload.size()) {
                net_axis<WIDTH> w;
                w.data = 0;
                w.keep = 0;
                size_t n = payload.size() - off;
                if (n > WIDTH / 8) n = WIDTH / 8;
                for (size_t i = 0; i < n; i++) {
                    w.data((i * 8) + 7, i * 8) = payload[off + i];
                    w.keep[i] = 1;
                }
                off += n;
                w.last = (off >= payload.size()) ? 1 : 0;
                mem.writeWord(w);
            }
            nw++;
        } else if (op == "R") {
            long idx;
            unsigned long saddr, nbytes;
            ss >> idx >> saddr >> nbytes;
            mem.setReadCmd(mmCmd((ap_uint<32>)saddr, (ap_uint<16>)nbytes));
            std::string hex;
            char buf[3];
            size_t got = 0;
            while (got < nbytes) {
                net_axis<WIDTH> w;
                mem.readWord(w);
                for (size_t i = 0; i < WIDTH / 8 && got < nbytes; i++) {
                    if (w.keep[i]) {
                        unsigned v = (unsigned)w.data((i * 8) + 7, i * 8);
                        snprintf(buf, sizeof(buf), "%02x", v & 0xFF);
                        hex += buf;
                        got++;
                    }
                }
                if (w.last) break;
            }
            out << idx << " " << hex << "\n";
            nr++;
        }
    }
    fprintf(stderr, "REF_WRITES=%ld\nREF_READS=%ld\nREF_DONE\n", nw, nr);
    return 0;
}
