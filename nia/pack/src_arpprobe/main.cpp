// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

#include <iostream>
#include <string>
#include <cstdint>
#include <cstdlib>
#include <thread>
#include <chrono>
#include <unistd.h>

#include <coyote/cThread.hpp>

int main(int argc, char *argv[]) {
    unsigned  device      = 0;
    unsigned  vfid        = 0;
    unsigned  count       = 5;
    unsigned  interval_ms = 100;
    uint32_t  target_ip   = 0;
    bool      have_target = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](const char *what) -> std::string {
            if (i + 1 >= argc) { std::cerr << "missing value for " << what << "\n"; std::exit(2); }
            return argv[++i];
        };
        if      (a == "--device"      || a == "-d") device      = std::stoul(next("--device"));
        else if (a == "--vfid")                    vfid        = std::stoul(next("--vfid"));
        else if (a == "--count"       || a == "-n") count      = std::stoul(next("--count"));
        else if (a == "--interval-ms")             interval_ms = std::stoul(next("--interval-ms"));
        else if (a == "--target-ip"   || a == "-t") {
            target_ip = static_cast<uint32_t>(std::stoul(next("--target-ip"), nullptr, 16));
            have_target = true;
        }
        else if (a == "--help" || a == "-h") {
            std::cout << "usage: arpprobe --device N --target-ip <hex ip of the PEER FPGA> "
                         "[--count N] [--interval-ms N] [--vfid N]\n";
            return 0;
        }
        else { std::cerr << "unknown option: " << a << "\n"; return 2; }
    }
    if (!have_target) {
        std::cerr << "--target-ip is required (the PEER FPGA's IP, hex, as cyt_attr_ip prints it)\n";
        return 2;
    }

    std::cout << "arpprobe: device " << device << " vfid " << vfid
              << " -> target IP 0x" << std::hex << target_ip << std::dec
              << ", " << count << " lookups every " << interval_ms << " ms\n";

    try {
        coyote::cThread thread(vfid, getpid(), device);
        std::cout << "arpprobe: cThread opened; issuing lookups\n";
        for (unsigned i = 0; i < count; ++i) {
            thread.doArpLookup(target_ip);
            std::cout << "  lookup " << (i + 1) << "/" << count << " issued\n" << std::flush;
            if (i + 1 < count)
                std::this_thread::sleep_for(std::chrono::milliseconds(interval_ms));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        std::cout << "arpprobe: DONE, issued " << count << " ARP lookups\n";
    } catch (const std::exception &e) {
        std::cerr << "arpprobe: FAILED: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
