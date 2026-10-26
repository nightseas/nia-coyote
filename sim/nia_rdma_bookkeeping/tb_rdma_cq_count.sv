// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_rdma_cq_count;

    localparam integer CLK_PERIOD = 4000;
    localparam integer POLL_BUDGET = 400;
    localparam integer TEST_PID = 3;
    localparam integer MAX_WR = 256;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    integer failures = 0;
    integer expect_read_counts = 1;
    integer expect_no_discard = 1;
    integer messages = 12;
    integer gap = 6;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    metaIntf #(.STYPE(ack_t)) s_rdma_done (.aclk(aclk), .aresetn(aresetn));

    logic clear_rd = 1'b0;
    logic clear_wr = 1'b0;
    logic [PID_BITS-1:0] clear_addr_rd = TEST_PID;
    logic [PID_BITS-1:0] clear_addr_wr = TEST_PID;
    logic [PID_BITS-1:0] stat_pid = TEST_PID;
    logic [31:0] stat_cnt_rd;
    logic [31:0] stat_cnt_wr;

    rdma_cq_count dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_rdma_done(s_rdma_done),
        .clear_rd(clear_rd),
        .clear_addr_rd(clear_addr_rd),
        .clear_wr(clear_wr),
        .clear_addr_wr(clear_addr_wr),
        .stat_pid(stat_pid),
        .stat_cnt_rd(stat_cnt_rd),
        .stat_cnt_wr(stat_cnt_wr)
    );

    integer offered_rd = 0;
    integer offered_wr = 0;
    integer refused = 0;

    integer decr_read = 0;
    integer decr_write = 0;
    integer polled_rd = 0;
    integer polled_wr = 0;

    bit wr_is_read [MAX_WR];
    integer wr_posted = 0;
    integer wr_head = 0;

    task automatic pulse_reset(input int cycles);
        aresetn = 1'b0;
        repeat (cycles) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge aclk);
    endtask

    task automatic offer_completion(input bit is_read, input int pid);
        s_rdma_done.data = '0;
        s_rdma_done.data.opcode = is_read ? RC_RDMA_READ_RESP_ONLY : RC_ACK;
        s_rdma_done.data.pid = pid[PID_BITS-1:0];
        s_rdma_done.data.vfid = 0;
        s_rdma_done.data.remote = 1'b1;
        s_rdma_done.valid = 1'b1;
        @(posedge aclk);
        if (!s_rdma_done.ready) begin
            refused = refused + 1;
            while (!s_rdma_done.ready) @(posedge aclk);
        end
        s_rdma_done.valid = 1'b0;
        if (is_read) offered_rd = offered_rd + 1;
        else offered_wr = offered_wr + 1;
        repeat (gap) @(posedge aclk);
    endtask

    task automatic post_wr(input bit is_read);
        wr_is_read[wr_posted] = is_read;
        wr_posted = wr_posted + 1;
    endtask

    task automatic poll_cq(output int fulfilled);
        int avail_rd;
        int avail_wr;
        fulfilled = 0;
        @(posedge aclk);
        avail_wr = stat_cnt_wr - decr_write;
        avail_rd = stat_cnt_rd - decr_read;
        while (wr_head < wr_posted) begin
            if (wr_is_read[wr_head]) begin
                if (avail_rd >= 1) begin
                    avail_rd = avail_rd - 1;
                    decr_read = decr_read + 1;
                    polled_rd = polled_rd + 1;
                    wr_head = wr_head + 1;
                    fulfilled = fulfilled + 1;
                end
                else break;
            end
            else begin
                if (avail_wr >= 1) begin
                    avail_wr = avail_wr - 1;
                    decr_write = decr_write + 1;
                    polled_wr = polled_wr + 1;
                    wr_head = wr_head + 1;
                    fulfilled = fulfilled + 1;
                end
                else break;
            end
        end
    endtask

    task automatic drain_cq(input int budget, output int polls_spent);
        int got;
        polls_spent = 0;
        while (wr_head < wr_posted && polls_spent < budget) begin
            poll_cq(got);
            polls_spent = polls_spent + 1;
        end
    endtask

    task automatic report_counts(input string tag);
        $display("CQCNT STATE %s offered_rd=%0d offered_wr=%0d cnt_rd=%0d cnt_wr=%0d polled_rd=%0d polled_wr=%0d outstanding=%0d refused=%0d",
                 tag, offered_rd, offered_wr, stat_cnt_rd, stat_cnt_wr,
                 polled_rd, polled_wr, wr_posted - wr_head, refused);
    endtask

    task automatic check(input string name, input bit got, input bit want);
        if (got === want) begin
            $display("CQCNT RESULT PASS %s", name);
        end
        else begin
            $display("CQCNT RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    task automatic check_int(input string name, input int got, input int want);
        if (got === want) begin
            $display("CQCNT RESULT PASS %s value=%0d", name, got);
        end
        else begin
            $display("CQCNT RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    task automatic clear_counters();
        clear_rd = 1'b1;
        clear_wr = 1'b1;
        @(posedge aclk);
        clear_rd = 1'b0;
        clear_wr = 1'b0;
        repeat (4) @(posedge aclk);
    endtask

    task automatic reset_tracking();
        offered_rd = 0;
        offered_wr = 0;
        refused = 0;
        decr_read = 0;
        decr_write = 0;
        polled_rd = 0;
        polled_wr = 0;
        wr_posted = 0;
        wr_head = 0;
    endtask

    task automatic run_single_direction(input bit is_read, input int n);
        int polls;
        for (int i = 0; i < n; i++) begin
            post_wr(is_read);
            offer_completion(is_read, TEST_PID);
        end
        drain_cq(POLL_BUDGET, polls);
    endtask

    task automatic run_alternating(input int n);
        int polls;
        for (int i = 0; i < n; i++) begin
            post_wr(1'b0);
            offer_completion(1'b0, TEST_PID);
            drain_cq(POLL_BUDGET, polls);
            post_wr(1'b1);
            offer_completion(1'b1, TEST_PID);
            drain_cq(POLL_BUDGET, polls);
        end
    endtask

    initial begin
        int polls;
        int phase_wr;

        void'($value$plusargs("expect_read_counts=%d", expect_read_counts));
        void'($value$plusargs("expect_no_discard=%d", expect_no_discard));
        void'($value$plusargs("messages=%d", messages));
        void'($value$plusargs("gap=%d", gap));

        s_rdma_done.valid = 1'b0;
        s_rdma_done.data = '0;
        pulse_reset(8);
        clear_counters();
        reset_tracking();

        $display("CQCNT CONFIG expect_read_counts=%0d expect_no_discard=%0d messages=%0d gap=%0d",
                 expect_read_counts, expect_no_discard, messages, gap);

        $display("CQCNT CASE 1 the write direction alone, which the upstream example measures");
        run_single_direction(1'b0, messages);
        report_counts("case1_write_only");
        check_int("case1_write_counter_equals_write_completions", stat_cnt_wr, messages);
        check("case1_every_write_request_fulfilled", (wr_head == wr_posted), 1'b1);

        $display("CQCNT CASE 2 the read direction alone, from a cleared device");
        clear_counters();
        reset_tracking();
        run_single_direction(1'b1, messages);
        report_counts("case2_read_only");
        if (expect_read_counts) begin
            check_int("case2_read_counter_equals_read_completions", stat_cnt_rd, messages);
            check("case2_every_read_request_fulfilled", (wr_head == wr_posted), 1'b1);
        end
        else begin
            check("case2_read_counter_does_not_count_read_completions", (stat_cnt_rd != messages), 1'b1);
            check("case2_read_requests_left_unfulfilled", (wr_head < wr_posted), 1'b1);
        end

        $display("CQCNT CASE 3 a write phase then a read phase, the direction change of the measured wedge");
        clear_counters();
        reset_tracking();
        for (int i = 0; i < messages; i++) begin
            post_wr(1'b0);
            offer_completion(1'b0, TEST_PID);
        end
        drain_cq(POLL_BUDGET, polls);
        phase_wr = stat_cnt_wr;
        for (int i = 0; i < messages; i++) begin
            post_wr(1'b1);
            offer_completion(1'b1, TEST_PID);
        end
        drain_cq(POLL_BUDGET, polls);
        report_counts("case3_write_then_read");
        if (expect_read_counts) begin
            check_int("case3_read_counter_equals_read_completions", stat_cnt_rd, messages);
            check("case3_every_request_fulfilled_after_the_direction_change", (wr_head == wr_posted), 1'b1);
        end
        else begin
            check_int("case3_read_counter_tracks_the_write_counter", stat_cnt_rd, phase_wr + 1);
            check("case3_read_counter_differs_from_the_read_completions", (stat_cnt_rd != messages), 1'b1);
            check("case3_host_credited_for_a_read_completion_the_device_did_not_produce", (stat_cnt_rd > messages), 1'b1);
        end

        $display("CQCNT CASE 4 alternating one message per direction, polled after each");
        clear_counters();
        reset_tracking();
        run_alternating(messages);
        report_counts("case4_alternating");
        if (expect_read_counts) begin
            check_int("case4_read_counter_equals_read_completions", stat_cnt_rd, messages);
            check_int("case4_write_counter_equals_write_completions", stat_cnt_wr, messages);
            check("case4_every_request_fulfilled", (wr_head == wr_posted), 1'b1);
        end
        else begin
            check("case4_read_counter_differs_from_the_read_completions", (stat_cnt_rd != messages), 1'b1);
        end

        $display("CQCNT CASE 5 completions offered back to back, which tests the eight entry queue");
        clear_counters();
        reset_tracking();
        gap = 0;
        for (int i = 0; i < 32; i++) begin
            post_wr(1'b0);
            offer_completion(1'b0, TEST_PID);
        end
        drain_cq(POLL_BUDGET, polls);
        report_counts("case5_back_to_back");
        if (expect_no_discard) begin
            check_int("case5_write_counter_equals_offered_completions", stat_cnt_wr, 32);
            check("case5_every_request_fulfilled", (wr_head == wr_posted), 1'b1);
        end
        else begin
            check("case5_completions_discarded_at_a_full_queue", (stat_cnt_wr < 32), 1'b1);
            check("case5_requests_left_unfulfilled", (wr_head < wr_posted), 1'b1);
        end
        gap = 6;

        $display("CQCNT CASE 6 the counters against a shell reset, which a driver reload issues");
        clear_counters();
        reset_tracking();
        run_single_direction(1'b0, 4);
        report_counts("case6_before_reset");
        pulse_reset(8);
        repeat (8) @(posedge aclk);
        report_counts("case6_after_reset");
        check_int("case6_write_counter_survives_a_reset", stat_cnt_wr, 4);

        $display("CQCNT CASE 7 the counters against a register clear, which device configuration performs");
        clear_counters();
        repeat (4) @(posedge aclk);
        report_counts("case7_after_clear");
        check_int("case7_write_counter_cleared", stat_cnt_wr, 0);
        check_int("case7_read_counter_cleared", stat_cnt_rd, 0);

        if (failures == 0) begin
            $display("CQCNT RESULT PASS all cases");
        end
        else begin
            $display("CQCNT RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
