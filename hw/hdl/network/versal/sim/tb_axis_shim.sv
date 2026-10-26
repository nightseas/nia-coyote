// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT

`timescale 1ns / 1ps

module tb_axis_shim #(
    parameter int NSLV = 4
) ();

    typedef struct packed {
        logic [511:0] d;
        logic [63:0]  k;
        logic         l;
    } beat_t;

    localparam int MAXS = 4;

    logic clk = 1'b0;
    logic rstn = 1'b0;
    always #2.0 clk = ~clk;

    logic [MAXS-1:0]  sv, sr, sl, ss;
    logic [511:0]     sd [MAXS];
    logic [63:0]      sk [MAXS];

    logic             mv, mr, ml;
    logic [511:0]     md;
    logic [63:0]      mk;

    generate
        if (NSLV == 4) begin : g_dut4
            axis_interconnect_512_4to1 dut (
                .ACLK(clk), .ARESETN(rstn),
                .S00_AXIS_ACLK(clk), .S01_AXIS_ACLK(clk),
                .S02_AXIS_ACLK(clk), .S03_AXIS_ACLK(clk),
                .S00_AXIS_ARESETN(rstn), .S01_AXIS_ARESETN(rstn),
                .S02_AXIS_ARESETN(rstn), .S03_AXIS_ARESETN(rstn),
                .S00_AXIS_TVALID(sv[0]), .S00_AXIS_TREADY(sr[0]),
                .S00_AXIS_TDATA(sd[0]),  .S00_AXIS_TKEEP(sk[0]), .S00_AXIS_TLAST(sl[0]),
                .S01_AXIS_TVALID(sv[1]), .S01_AXIS_TREADY(sr[1]),
                .S01_AXIS_TDATA(sd[1]),  .S01_AXIS_TKEEP(sk[1]), .S01_AXIS_TLAST(sl[1]),
                .S02_AXIS_TVALID(sv[2]), .S02_AXIS_TREADY(sr[2]),
                .S02_AXIS_TDATA(sd[2]),  .S02_AXIS_TKEEP(sk[2]), .S02_AXIS_TLAST(sl[2]),
                .S03_AXIS_TVALID(sv[3]), .S03_AXIS_TREADY(sr[3]),
                .S03_AXIS_TDATA(sd[3]),  .S03_AXIS_TKEEP(sk[3]), .S03_AXIS_TLAST(sl[3]),
                .M00_AXIS_ACLK(clk), .M00_AXIS_ARESETN(rstn),
                .M00_AXIS_TVALID(mv), .M00_AXIS_TREADY(mr),
                .M00_AXIS_TDATA(md),  .M00_AXIS_TKEEP(mk), .M00_AXIS_TLAST(ml),
                .S00_ARB_REQ_SUPPRESS(ss[0]), .S01_ARB_REQ_SUPPRESS(ss[1]),
                .S02_ARB_REQ_SUPPRESS(ss[2]), .S03_ARB_REQ_SUPPRESS(ss[3])
            );
        end else begin : g_dut2
            axis_interconnect_512_2to1 dut (
                .ACLK(clk), .ARESETN(rstn),
                .S00_AXIS_ACLK(clk), .S01_AXIS_ACLK(clk),
                .S00_AXIS_ARESETN(rstn), .S01_AXIS_ARESETN(rstn),
                .S00_AXIS_TVALID(sv[0]), .S00_AXIS_TREADY(sr[0]),
                .S00_AXIS_TDATA(sd[0]),  .S00_AXIS_TKEEP(sk[0]), .S00_AXIS_TLAST(sl[0]),
                .S01_AXIS_TVALID(sv[1]), .S01_AXIS_TREADY(sr[1]),
                .S01_AXIS_TDATA(sd[1]),  .S01_AXIS_TKEEP(sk[1]), .S01_AXIS_TLAST(sl[1]),
                .M00_AXIS_ACLK(clk), .M00_AXIS_ARESETN(rstn),
                .M00_AXIS_TVALID(mv), .M00_AXIS_TREADY(mr),
                .M00_AXIS_TDATA(md),  .M00_AXIS_TKEEP(mk), .M00_AXIS_TLAST(ml),
                .S00_ARB_REQ_SUPPRESS(ss[0]), .S01_ARB_REQ_SUPPRESS(ss[1])
            );
            always_comb begin
                for (int q = 2; q < MAXS; q++) begin
                    sd[q] = '0; sk[q] = '0;
                end
            end
        end
    endgenerate

    int unsigned prng [0:7];
    int unsigned seed = 1;
    int unsigned neg_mode = 0;

    function automatic int unsigned rnd(int ch);
        int unsigned x;
        x = prng[ch];
        x = x ^ (x << 13);
        x = x ^ (x >> 17);
        x = x ^ (x << 5);
        prng[ch] = x;
        return x;
    endfunction

    function automatic int rnd_range(int ch, int lo, int hi);
        if (hi <= lo) return lo;
        return lo + int'(rnd(ch) % int'(unsigned'(hi - lo + 1)));
    endfunction

    beat_t tx_q  [MAXS][$];
    int    tx_n  [MAXS][$];
    beat_t exp_q [MAXS][$];
    int    exp_n [MAXS][$];

    int  gap_max   [MAXS];
    int  stall_pct = 0;
    bit  drv_en    = 0;
    bit  chk_en    = 0;

    int  frames_src [MAXS];
    int  beats_src  [MAXS];
    int  seq_src    [MAXS];

    int  obs_multi_hs         = 0;
    int  obs_partial_at_reset = 0;
    int  obs_first_granted    = -1;

    string tst_name = "none";
    int    nerr = 0, tests_run = 0, tests_pass = 0, tests_fail = 0;

    task automatic err(string what, string detail);
        nerr++;
        if (nerr <= 30)
            $display("S23 ERROR [%s] %s : %s  (t=%0t)", tst_name, what, detail, $time);
        else if (nerr == 31)
            $display("S23 ERROR [%s] ERROR_CAP_REACHED : further errors in this test are counted but not printed",
                     tst_name);
    endtask

    function automatic logic [7:0] pbyte(int src, int seq, int j);
        return 8'((src * 8'h37) ^ (seq * 8'h5B) ^ (j * 8'h1D) ^ (j >> 3));
    endfunction

    task automatic gen_frame(int src, int len);
        int    nb, lanes, sq;
        beat_t bt;
        sq = seq_src[src]; seq_src[src] = sq + 1;
        nb = (len + 63) / 64;
        for (int b = 0; b < nb; b++) begin
            lanes = (b == nb-1) ? (len - 64*b) : 64;
            bt.d = '0; bt.k = '0;
            for (int t = 0; t < lanes; t++) begin
                bt.d[8*t +: 8] = (t == 0) ? (8'hA0 + 8'(src)) : pbyte(src, sq, 64*b + t);
                bt.k[t]        = 1'b1;
            end
            bt.l = (b == nb-1);
            tx_q[src].push_back(bt);
            if (neg_mode == 1 && src == 0 && bt.l && bt.k != {64{1'b1}}) begin
                beat_t bad = bt;
                bad.k = bt.k ^ 64'h1;
                exp_q[src].push_back(bad);
            end else begin
                exp_q[src].push_back(bt);
            end
        end
        tx_n[src].push_back(nb);
        exp_n[src].push_back(nb);
    endtask

    task automatic slot_driver(int i);
        int    nb, g;
        beat_t bt;
        bit    aborted;
        @(negedge clk);
        sv[i] = 1'b0; sd[i] = '0; sk[i] = '0; sl[i] = 1'b0;
        forever begin
            while (!drv_en || !rstn || tx_n[i].size() == 0) begin
                sv[i] = 1'b0; sl[i] = 1'b0;
                @(negedge clk);
            end
            if (gap_max[i] > 0) begin
                g = rnd_range(i, 0, gap_max[i]);
                repeat (g) begin sv[i] = 1'b0; @(negedge clk); end
            end
            if (tx_n[i].size() == 0) continue;
            nb = tx_n[i].pop_front();
            aborted = 1'b0;
            for (int b = 0; b < nb; b++) begin
                bt = tx_q[i].pop_front();
                sv[i] = 1'b1; sd[i] = bt.d; sk[i] = bt.k; sl[i] = bt.l;
                forever begin
                    @(posedge clk);
                    if (!rstn || !drv_en) begin aborted = 1'b1; break; end
                    if (sr[i] === 1'b1) break;
                end
                if (aborted) break;
                @(negedge clk);
            end
            sv[i] = 1'b0; sl[i] = 1'b0;
            if (aborted) begin
                tx_q[i].delete(); tx_n[i].delete();
                @(negedge clk);
            end
        end
    endtask

    generate
        for (genvar gi = 0; gi < NSLV; gi++) begin : g_drv
            initial slot_driver(gi);
        end
        for (genvar gj = NSLV; gj < MAXS; gj++) begin : g_park
            initial begin sv[gj] = 1'b0; sl[gj] = 1'b0; ss[gj] = 1'b0; end
        end
    endgenerate

    initial begin
        mr = 1'b1;
        @(negedge clk);
        forever begin
            mr = (stall_pct == 0) ? 1'b1 : ((rnd_range(6, 0, 99) >= stall_pct) ? 1'b1 : 1'b0);
            @(negedge clk);
        end
    end

    int    cur_src   = -1;
    bit    cur_open  = 1'b0;
    int    cur_beats = 0;

    bit           held_v = 1'b0;
    logic [511:0] held_d;
    logic [63:0]  held_k;
    logic         held_l;

    task automatic accept_beat();
        int    src, n;
        beat_t e;
        src = int'(md[7:0]) - 8'hA0;
        if (src < 0 || src >= NSLV) begin
            err("BAD_SRC_TAG", $sformatf("byte0=0x%02h -> src=%0d", md[7:0], src));
            return;
        end
        if (cur_open) begin
            if (src != cur_src)
                err("ATOMICITY", $sformatf("frame opened by src%0d, beat %0d came from src%0d",
                                           cur_src, cur_beats, src));
        end else begin
            cur_src = src; cur_open = 1'b1; cur_beats = 0;
            if (obs_first_granted < 0) obs_first_granted = src;
        end
        if (exp_q[src].size() == 0) begin
            err("UNEXPECTED_BEAT", $sformatf("src%0d produced a beat with nothing expected", src));
        end else begin
            e = exp_q[src].pop_front();
            if (md !== e.d)
                err("DATA_MISMATCH", $sformatf("src%0d beat%0d exp %h got %h",
                                               src, cur_beats, e.d[63:0], md[63:0]));
            if (mk !== e.k)
                err("TKEEP_MISMATCH", $sformatf("src%0d beat%0d exp %h got %h",
                                                src, cur_beats, e.k, mk));
            if (ml !== e.l)
                err("TLAST_MISMATCH", $sformatf("src%0d beat%0d exp %b got %b",
                                                src, cur_beats, e.l, ml));
        end
        cur_beats++;
        beats_src[src]++;
        if (ml === 1'b1) begin
            if (exp_n[src].size() == 0)
                err("UNEXPECTED_FRAME", $sformatf("src%0d closed a frame with none expected", src));
            else begin
                n = exp_n[src].pop_front();
                if (n != cur_beats)
                    err("FRAME_LEN_MISMATCH",
                        $sformatf("src%0d expected %0d beats, saw %0d", src, n, cur_beats));
            end
            frames_src[src]++;
            cur_open = 1'b0; cur_beats = 0; cur_src = -1;
        end
    endtask

    always @(posedge clk) begin
        if (!rstn) begin
            if (cur_open) obs_partial_at_reset++;
            cur_open = 1'b0; cur_beats = 0; cur_src = -1; held_v = 1'b0;
        end else if (chk_en) begin
            int hs;
            if (held_v) begin
                if (mv !== 1'b1)
                    err("TVALID_DROPPED_WHILE_STALLED", "M00 TVALID fell with TREADY low");
                else if (md !== held_d || mk !== held_k || ml !== held_l)
                    err("M00_NOT_STABLE_WHILE_STALLED", "M00 payload changed with TREADY low");
            end
            if (mv === 1'b1 && mr !== 1'b1) begin
                held_v = 1'b1; held_d = md; held_k = mk; held_l = ml;
            end else begin
                held_v = 1'b0;
            end
            if (mv === 1'b1 && mr === 1'b1) accept_beat();
            hs = 0;
            for (int i = 0; i < NSLV; i++) if (sv[i] === 1'b1 && sr[i] === 1'b1) hs++;
            if (hs > 1) obs_multi_hs++;
        end
    end

    function automatic int pend_beats();
        int t = 0;
        for (int i = 0; i < NSLV; i++) t += exp_q[i].size();
        return t;
    endfunction

    task automatic clear_all();
        for (int i = 0; i < MAXS; i++) begin
            tx_q[i].delete(); tx_n[i].delete(); exp_q[i].delete(); exp_n[i].delete();
            frames_src[i] = 0; beats_src[i] = 0; gap_max[i] = 0; ss[i] = 1'b0;
        end
        cur_src = -1; cur_open = 1'b0; cur_beats = 0; held_v = 1'b0;
        obs_first_granted = -1;
    endtask

    task automatic do_reset();
        drv_en = 1'b0;
        chk_en = 1'b0;
        repeat (4) @(negedge clk);
        rstn = 1'b0;
        repeat (8) @(negedge clk);
        clear_all();
        rstn = 1'b1;
        repeat (6) @(negedge clk);
        chk_en = 1'b1;
        drv_en = 1'b1;
    endtask

    task automatic begin_test(string name);
        tst_name = name;
        nerr = 0;
        stall_pct = 0;
        do_reset();
        $display("S23 TEST %s START t=%0t", name, $time);
    endtask

    function automatic int pend_tx();
        int t = 0;
        for (int i = 0; i < NSLV; i++) t += tx_n[i].size();
        return t;
    endfunction

    task automatic drain(int max_cycles);
        int c = 0, idle = 0;
        while (c < max_cycles) begin
            @(negedge clk);
            c++;
            if (pend_beats() == 0 && pend_tx() == 0) idle++;
            else                                    idle = 0;
            if (idle >= 20) return;
        end
        err("DRAIN_TIMEOUT", $sformatf("%0d beats still expected after %0d cycles",
                                      pend_beats(), max_cycles));
    endtask

    task automatic end_test();
        int leftover = 0;
        for (int i = 0; i < NSLV; i++) leftover += exp_q[i].size() + exp_n[i].size();
        if (leftover != 0)
            err("LEFTOVER_EXPECTED", $sformatf("%0d beats/frames never arrived", leftover));
        if (cur_open)
            err("FRAME_LEFT_OPEN", "a frame was still open at end of test");
        tests_run++;
        if (nerr == 0) begin
            tests_pass++;
            $display("S23 TEST %s PASS   frames=[%0d %0d %0d %0d]",
                     tst_name, frames_src[0], frames_src[1], frames_src[2], frames_src[3]);
        end else begin
            tests_fail++;
            $display("S23 TEST %s FAIL errors=%0d  frames=[%0d %0d %0d %0d]",
                     tst_name, nerr, frames_src[0], frames_src[1], frames_src[2], frames_src[3]);
        end
    endtask

    task automatic t_atomicity();
        begin_test("t_atomicity");
        for (int i = 0; i < NSLV; i++) gap_max[i] = 0;
        for (int f = 0; f < 24; f++)
            for (int i = 0; i < NSLV; i++)
                gen_frame(i, rnd_range(i, 65, 600));
        drain(200000);
        end_test();
    endtask

    task automatic t_byte_exact_order();
        begin_test("t_byte_exact_order");
        for (int i = 0; i < NSLV; i++) gap_max[i] = rnd_range(i, 0, 4);
        for (int f = 0; f < 40; f++)
            for (int i = 0; i < NSLV; i++)
                gen_frame(i, rnd_range(i, 1, 1518));
        drain(400000);
        end_test();
    endtask

    task automatic t_keep_tlast();
        int lens [] = '{1, 2, 3, 17, 63, 64, 65, 127, 128, 129, 191, 192, 193, 1500, 1518};
        begin_test("t_keep_tlast");
        for (int i = 0; i < NSLV; i++) begin
            foreach (lens[x]) gen_frame(i, lens[x]);
            drain(100000);
        end
        end_test();
    endtask

    task automatic t_backpressure();
        begin_test("t_backpressure");
        stall_pct = 45;
        for (int i = 0; i < NSLV; i++) gap_max[i] = rnd_range(i, 0, 6);
        for (int f = 0; f < 24; f++)
            for (int i = 0; i < NSLV; i++)
                gen_frame(i, rnd_range(i, 1, 700));
        drain(400000);
        end_test();
    endtask

    task automatic t_fairness();
        int mn, total;
        begin_test("t_fairness");
        for (int i = 0; i < NSLV; i++) gap_max[i] = 0;
        for (int f = 0; f < 30; f++)
            for (int i = 0; i < NSLV; i++)
                gen_frame(i, 128);
        repeat (30 * NSLV) @(negedge clk);
        mn = frames_src[0]; total = 0;
        for (int i = 0; i < NSLV; i++) begin
            if (frames_src[i] < mn) mn = frames_src[i];
            total += frames_src[i];
        end
        $display("S23 OBS fairness partial frames=[%0d %0d %0d %0d] total=%0d",
                 frames_src[0], frames_src[1], frames_src[2], frames_src[3], total);
        if (total < 4 * NSLV)
            err("FAIRNESS_NO_PROGRESS", $sformatf("only %0d frames in the window", total));
        else if (mn * 2 * NSLV < total)
            err("STARVATION", $sformatf("min per-source %0d vs total %0d", mn, total));
        drain(400000);
        end_test();
    endtask

    task automatic t_arb_req_suppress();
        int victim, others;
        begin_test("t_arb_req_suppress");
        victim = 1;
        ss[victim] = 1'b1;
        for (int i = 0; i < NSLV; i++) gap_max[i] = 0;
        for (int f = 0; f < 12; f++)
            for (int i = 0; i < NSLV; i++)
                gen_frame(i, 128);
        repeat (4000) @(negedge clk);
        others = 0;
        for (int i = 0; i < NSLV; i++) if (i != victim) others += frames_src[i];
        $display("S23 OBS suppress window: victim=S%02d frames=%0d others=%0d",
                 victim, frames_src[victim], others);
        if (frames_src[victim] != 0)
            err("SUPPRESS_NOT_HONOURED",
                $sformatf("S%02d delivered %0d frames while suppressed", victim, frames_src[victim]));
        if (others == 0)
            err("SUPPRESS_BLOCKED_EVERYTHING", "no un-suppressed source made progress");
        ss[victim] = 1'b0;
        drain(400000);
        if (frames_src[victim] == 0)
            err("SUPPRESS_NO_RELEASE", $sformatf("S%02d never drained after release", victim));
        end_test();
    endtask

    task automatic t_reset_midframe();
        int pre_cnt;
        begin_test("t_reset_midframe");
        stall_pct = 0;
        for (int i = 0; i < NSLV; i++) gap_max[i] = 0;
        gen_frame(0, 1518);
        repeat (6) @(negedge clk);
        stall_pct = 100;
        repeat (10) @(negedge clk);
        pre_cnt = obs_partial_at_reset;
        chk_en = 1'b0;
        rstn   = 1'b0;
        drv_en = 1'b0;
        repeat (10) @(negedge clk);
        clear_all();
        rstn      = 1'b1;
        stall_pct = 0;
        repeat (8) @(negedge clk);
        chk_en = 1'b1;
        drv_en = 1'b1;
        $display("S23 OBS reset landed with an output frame open: %0d (delta=%0d)",
                 obs_partial_at_reset, obs_partial_at_reset - pre_cnt);
        for (int i = 0; i < NSLV; i++) gen_frame(i, 200);
        drain(200000);
        for (int i = 0; i < NSLV; i++)
            if (frames_src[i] != 1)
                err("POST_RESET_UNUSABLE",
                    $sformatf("S%02d delivered %0d frames after reset (want 1)", i, frames_src[i]));
        end_test();
    endtask

    task automatic t_slot_order_rotation();
        int fs [0:7];
        int fwd = 0, rev = 0, mask = 0, base, d;
        begin_test("t_slot_order_rotation");
        for (int e = 0; e < 2*NSLV; e++) begin
            do_reset();
            drv_en = 1'b0;
            repeat (2 + e) @(negedge clk);
            for (int i = 0; i < NSLV; i++) begin gap_max[i] = 0; gen_frame(i, 64); end
            obs_first_granted = -1;
            @(posedge clk);
            drv_en = 1'b1;
            drain(20000);
            fs[e] = obs_first_granted;
            if (fs[e] >= 0) mask = mask | (1 << fs[e]);
            $display("S23 OBS rotation extra_idle=%0d first_granted=S%02d", e, fs[e]);
        end
        base = fs[0];
        for (int e = 0; e < 2*NSLV; e++)
            if (fs[e] != ((base + e) % NSLV))
                err("ROTATION_LAW",
                    $sformatf("extra_idle=%0d gave S%02d, +1-per-idle-cycle predicts S%02d",
                              e, fs[e], (base + e) % NSLV));
        if (mask != ((1 << NSLV) - 1))
            err("SLOT_UNREACHABLE",
                $sformatf("only slots 0x%0h ever won over a %0d-step sweep", mask, 2*NSLV));
        for (int e = 0; e + 1 < 2*NSLV; e++) begin
            d = (((fs[e+1] - fs[e]) % NSLV) + NSLV) % NSLV;
            if (d == 1)           fwd++;
            else if (d == NSLV-1) rev++;
        end
        if (NSLV > 2) begin
            $display("S23 OBS rotation direction forward=%0d reverse=%0d (a reversed slave concatenation inverts this)",
                     fwd, rev);
            if (fwd <= rev)
                err("SLOT_ORDER_REVERSED",
                    $sformatf("forward steps %0d <= reverse steps %0d", fwd, rev));
        end else begin
            $display("S23 OBS rotation direction UNOBSERVABLE for NSLV=2 (+1 == -1 mod 2): the 2-slot concatenation order rests on the IP XML bit ranges and the identical idiom, not on this test");
        end
        end_test();
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        void'($value$plusargs("NEG=%d", neg_mode));
        for (int c = 0; c < 8; c++) begin
            prng[c] = (seed * 32'h9E3779B1) ^ (32'h85EBCA6B * (c + 1));
            if (prng[c] == 0) prng[c] = 32'hDEADBEEF + c;
        end
        for (int i = 0; i < MAXS; i++) begin
            gap_max[i] = 0; ss[i] = 1'b0; seq_src[i] = 0;
            frames_src[i] = 0; beats_src[i] = 0;
        end
        $display("S23_DUT=%0dto1", NSLV);
        $display("S23_SEED=%0d", seed);
        $display("S23_NEG=%0d", neg_mode);

        t_atomicity();
        t_byte_exact_order();
        t_keep_tlast();
        t_backpressure();
        t_fairness();
        t_arb_req_suppress();
        t_reset_midframe();
        t_slot_order_rotation();

        $display("S23 OBS multi-slave-handshake cycles = %0d", obs_multi_hs);
        $display("S23_RESULT dut=%0dto1 seed=%0d tests=%0d pass=%0d fail=%0d",
                 NSLV, seed, tests_run, tests_pass, tests_fail);
        $display("S23_DONE rc=%0d", (tests_fail != 0) ? 1 : 0);
        $finish;
    end

    initial begin
        #4000000;
        $display("S23 ERROR [%s] GLOBAL_TIMEOUT", tst_name);
        $display("S23_RESULT dut=%0dto1 seed=%0d tests=%0d pass=%0d fail=%0d",
                 NSLV, seed, tests_run, tests_pass, tests_fail);
        $display("S23_DONE rc=2");
        $finish;
    end

endmodule

module tb_shim_4to1 ();
    tb_axis_shim #(.NSLV(4)) u ();
endmodule

module tb_shim_2to1 ();
    tb_axis_shim #(.NSLV(2)) u ();
endmodule
