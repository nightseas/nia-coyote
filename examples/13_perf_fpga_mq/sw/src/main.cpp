/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2025, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include <chrono>
#include <thread>
#include <vector>
#include <memory>
#include <iomanip>
#include <iostream>
#include <boost/program_options.hpp>

#include <coyote/cThread.hpp>

#define CLOCK_PERIOD_NS 4
#define DEFAULT_VFPGA_ID 0

#define REGS_PER_STREAM 8
enum PerfReg : uint32_t {
    CTRL_REG = 0, DONE_REG = 1, TIMER_REG = 2, VADDR_REG = 3,
    LEN_REG = 4, PID_REG = 5, N_REPS_REG = 6, N_BEATS_REG = 7
};
enum class BenchOp : uint8_t { START_RD = 0x1, START_WR = 0x2 };

static inline uint32_t csr_index(unsigned int s, PerfReg r) {
    return s * REGS_PER_STREAM + static_cast<uint32_t>(r);
}

static double run_stream_once(coyote::cThread &t, unsigned int stream, unsigned int size,
                              int *mem, unsigned int transfers, BenchOp oper) {
    const uint64_t n_beats = (uint64_t) transfers * ((size + 64 - 1) / 64);
    t.setCSR(reinterpret_cast<uint64_t>(mem), csr_index(stream, VADDR_REG));
    t.setCSR(size,                            csr_index(stream, LEN_REG));
    t.setCSR(t.getCtid(),                     csr_index(stream, PID_REG));
    t.setCSR(transfers,                       csr_index(stream, N_REPS_REG));
    t.setCSR(n_beats,                         csr_index(stream, N_BEATS_REG));
    t.setCSR(static_cast<uint64_t>(oper),     csr_index(stream, CTRL_REG));
    while (!t.getCSR(csr_index(stream, DONE_REG))) {}
    return (double) t.getCSR(csr_index(stream, TIMER_REG)) * (double) CLOCK_PERIOD_NS;
}

int main(int argc, char *argv[]) {
    bool operation;
    unsigned int n_threads, n_runs, min_size, max_size;

    boost::program_options::options_description opts("Coyote Multi-Queue Perf FPGA Options");
    opts.add_options()
        ("operation,o", boost::program_options::value<bool>(&operation)->default_value(false), "READ(0) or WRITE(1)")
        ("threads,t",   boost::program_options::value<unsigned int>(&n_threads)->default_value(4), "Concurrent streams/threads (<= N_STRM_AXI=4)")
        ("runs,r",      boost::program_options::value<unsigned int>(&n_runs)->default_value(50), "Repeat count per size")
        ("min_size,x",  boost::program_options::value<unsigned int>(&min_size)->default_value(64), "Min transfer size (B)")
        ("max_size,X",  boost::program_options::value<unsigned int>(&max_size)->default_value(4 * 1024 * 1024), "Max transfer size (B)");
    boost::program_options::variables_map vm;
    boost::program_options::store(boost::program_options::parse_command_line(argc, argv, opts), vm);
    boost::program_options::notify(vm);

    if (n_threads < 1 || n_threads > 4) {
        throw std::runtime_error("This vFPGA is built with N_STRM_AXI=4; threads must be in [1,4].");
    }
    const BenchOp oper = operation ? BenchOp::START_WR : BenchOp::START_RD;
    const unsigned int TR = 32;

    HEADER("CLI PARAMETERS:");
    std::cout << "Operation: " << (operation ? "WRITE" : "READ") << std::endl;
    std::cout << "Streams/threads: " << n_threads << std::endl;
    std::cout << "Runs per size: " << n_runs << std::endl;
    std::cout << "Size range: " << min_size << " .. " << max_size << " B" << std::endl << std::endl;

    std::vector<std::unique_ptr<coyote::cThread>> threads;
    std::vector<int *> mems;
    for (unsigned int i = 0; i < n_threads; i++) {
        threads.emplace_back(new coyote::cThread(DEFAULT_VFPGA_ID, getpid()));
        int *m = (int *) threads[i]->getMem({coyote::CoyoteAllocType::HPF, max_size});
        if (!m) { throw std::runtime_error("getMem failed for stream " + std::to_string(i)); }
        for (unsigned int k = 0; k < max_size / sizeof(int); k++) m[k] = rand() % 1024 - 512;
        mems.push_back(m);
    }

    HEADER("MULTI-QUEUE PERF FPGA");
    for (unsigned int size = min_size; size <= max_size; size *= 2) {
        std::vector<double> per_stream_ns(n_threads, 0.0);

        double agg_wall_ns = 0.0;
        for (unsigned int run = 0; run < n_runs; run++) {
            std::vector<std::thread> workers;
            std::vector<double> t_ns(n_threads, 0.0);
            auto t0 = std::chrono::high_resolution_clock::now();
            for (unsigned int i = 0; i < n_threads; i++) {
                workers.emplace_back([&, i]() {
                    t_ns[i] = run_stream_once(*threads[i], i, size, mems[i], TR, oper);
                });
            }
            for (auto &w : workers) w.join();
            auto t1 = std::chrono::high_resolution_clock::now();
            agg_wall_ns += std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
            for (unsigned int i = 0; i < n_threads; i++) per_stream_ns[i] += t_ns[i];
        }
        agg_wall_ns /= (double) n_runs;

        const double bytes_per_stream = (double) TR * (double) size;
        std::cout << "Size: " << std::setw(9) << size << " B | ";
        double sum_mbps = 0.0;
        for (unsigned int i = 0; i < n_threads; i++) {
            double s_ns  = per_stream_ns[i] / (double) n_runs;
            double s_mbps = bytes_per_stream / (1024.0 * 1024.0 * s_ns * 1e-9);
            sum_mbps += s_mbps;
            std::cout << "s" << i << "=" << std::setw(8) << std::fixed << std::setprecision(1) << s_mbps << " MB/s ";
        }
        double agg_gbps = ((double) n_threads * bytes_per_stream) / (1e9 * agg_wall_ns * 1e-9);
        std::cout << "| SUM(per-stream)=" << std::setw(8) << sum_mbps / 1024.0 << " GB/s"
                  << " | AGG(wall)=" << std::setw(8) << agg_gbps << " GB/s" << std::endl;
    }

    std::cout << "\nDone. AGG(wall) is the concurrent host<->FPGA ceiling across "
              << n_threads << " streams." << std::endl;
    return EXIT_SUCCESS;
}
