// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_host_req_mux;

    localparam integer CLK_PERIOD = 4000;
    localparam integer OFFER_TIMEOUT = 400;
    localparam integer FILL_ATTEMPTS = 8;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    integer failures = 0;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    metaIntf #(.STYPE(dreq_t)) host_sq (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(req_t))  host_local_rd (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(req_t))  host_local_wr (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dreq_t)) host_remote_rd (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dreq_t)) host_remote_wr (.aclk(aclk), .aresetn(aresetn));

    host_req_mux dut (
        .host_sq(host_sq),
        .host_local_rd(host_local_rd),
        .host_local_wr(host_local_wr),
        .host_remote_rd(host_remote_rd),
        .host_remote_wr(host_remote_wr),
        .aclk(aclk),
        .aresetn(aresetn)
    );

    logic local_rd_ready = 1'b1;
    logic local_wr_ready = 1'b1;
    logic remote_rd_ready = 1'b1;
    logic remote_wr_ready = 1'b1;

    assign host_local_rd.ready = local_rd_ready;
    assign host_local_wr.ready = local_wr_ready;
    assign host_remote_rd.ready = remote_rd_ready;
    assign host_remote_wr.ready = remote_wr_ready;

    logic clr_cnt = 1'b0;
    integer cnt_local_rd = 0;
    integer cnt_local_wr = 0;
    integer cnt_remote_rd = 0;
    integer cnt_remote_wr = 0;

    always_ff @(posedge aclk) begin
        if (!aresetn || clr_cnt) begin
            cnt_local_rd <= 0;
            cnt_local_wr <= 0;
            cnt_remote_rd <= 0;
            cnt_remote_wr <= 0;
        end
        else begin
            if (host_local_rd.valid && host_local_rd.ready) cnt_local_rd <= cnt_local_rd + 1;
            if (host_local_wr.valid && host_local_wr.ready) cnt_local_wr <= cnt_local_wr + 1;
            if (host_remote_rd.valid && host_remote_rd.ready) cnt_remote_rd <= cnt_remote_rd + 1;
            if (host_remote_wr.valid && host_remote_wr.ready) cnt_remote_wr <= cnt_remote_wr + 1;
        end
    end

    task automatic pulse_reset(input int cycles);
        aresetn = 1'b0;
        repeat (cycles) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge aclk);
    endtask

    task automatic clear_counts();
        clr_cnt = 1'b1;
        @(posedge aclk);
        @(posedge aclk);
        clr_cnt = 1'b0;
        @(posedge aclk);
    endtask

    task automatic offer(input bit a1, input bit a2, input int strm1, input int strm2,
                         input int timeout_cycles, output bit accepted);
        int waited;
        accepted = 1'b0;
        waited = 0;
        host_sq.data = '0;
        host_sq.data.req_1.actv = a1;
        host_sq.data.req_1.strm = strm1[STRM_BITS-1:0];
        host_sq.data.req_1.len = 4096;
        host_sq.data.req_1.vaddr = 64'h3000;
        host_sq.data.req_1.opcode = RC_RDMA_READ_REQUEST;
        host_sq.data.req_2.actv = a2;
        host_sq.data.req_2.strm = strm2[STRM_BITS-1:0];
        host_sq.data.req_2.len = 4096;
        host_sq.data.req_2.vaddr = 64'h4000;
        host_sq.data.req_2.opcode = RC_RDMA_WRITE_ONLY;
        host_sq.valid = 1'b1;
        while (waited < timeout_cycles && accepted == 1'b0) begin
            @(posedge aclk);
            if (host_sq.ready) accepted = 1'b1;
            waited = waited + 1;
        end
        host_sq.valid = 1'b0;
        repeat (8) @(posedge aclk);
    endtask

    task automatic offer_until_refused(input bit a1, input bit a2, input int strm1, input int strm2,
                                       output int admitted);
        bit accepted;
        admitted = 0;
        accepted = 1'b1;
        for (int i = 0; i < FILL_ATTEMPTS && accepted; i++) begin
            offer(a1, a2, strm1, strm2, OFFER_TIMEOUT, accepted);
            if (accepted) admitted = admitted + 1;
        end
    endtask

    task automatic report_counts(input string tag);
        $display("HOSTMUX COUNTS %s local_rd=%0d local_wr=%0d remote_rd=%0d remote_wr=%0d picked_wr=%0b picked_rd=%0b",
                 tag, cnt_local_rd, cnt_local_wr, cnt_remote_rd, cnt_remote_wr,
                 dut.remote_wr_picked_up, dut.local_rd_picked_up);
    endtask

    task automatic check(input string name, input integer got, input integer want);
        if (got === want) begin
            $display("HOSTMUX RESULT PASS %s", name);
        end
        else begin
            $display("HOSTMUX RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    initial begin
        bit accepted;
        int admitted;

        host_sq.valid = 1'b0;
        host_sq.data = '0;
        pulse_reset(8);
        $display("HOSTMUX CONFIG strm_host=%0d strm_rdma=%0d fill_attempts=%0d", STRM_HOST, STRM_RDMA, FILL_ATTEMPTS);

        $display("HOSTMUX CASE 1 local read");
        clear_counts();
        offer(1'b1, 1'b0, STRM_HOST, STRM_HOST, OFFER_TIMEOUT, accepted);
        check("local_read_accepted", accepted, 1);
        check("local_read_goes_to_local_rd_once", cnt_local_rd, 1);
        check("local_read_touches_nothing_else", cnt_local_wr + cnt_remote_rd + cnt_remote_wr, 0);

        $display("HOSTMUX CASE 2 local write");
        clear_counts();
        offer(1'b0, 1'b1, STRM_HOST, STRM_HOST, OFFER_TIMEOUT, accepted);
        check("local_write_accepted", accepted, 1);
        check("local_write_goes_to_local_wr_once", cnt_local_wr, 1);
        check("local_write_touches_nothing_else", cnt_local_rd + cnt_remote_rd + cnt_remote_wr, 0);

        $display("HOSTMUX CASE 3 local transfer, both active");
        clear_counts();
        offer(1'b1, 1'b1, STRM_HOST, STRM_HOST, OFFER_TIMEOUT, accepted);
        check("local_transfer_accepted", accepted, 1);
        check("local_transfer_forks_to_both_once", cnt_local_rd + cnt_local_wr, 2);

        $display("HOSTMUX CASE 4 remote read");
        clear_counts();
        offer(1'b1, 1'b0, STRM_RDMA, STRM_HOST, OFFER_TIMEOUT, accepted);
        check("remote_read_accepted", accepted, 1);
        check("remote_read_goes_to_remote_rd_once", cnt_remote_rd, 1);
        check("remote_read_does_not_fetch_locally", cnt_local_rd, 0);

        $display("HOSTMUX CASE 5 remote write forks to the remote path and the host fetch");
        clear_counts();
        offer(1'b0, 1'b1, STRM_HOST, STRM_RDMA, OFFER_TIMEOUT, accepted);
        check("remote_write_accepted", accepted, 1);
        check("remote_write_goes_to_remote_wr_once", cnt_remote_wr, 1);
        check("remote_write_takes_one_host_fetch", cnt_local_rd, 1);
        report_counts("after_case5");

        $display("HOSTMUX CASE 6 the remote consumer held, the output register fills, then release");
        clear_counts();
        remote_wr_ready = 1'b0;
        offer_until_refused(1'b0, 1'b1, STRM_HOST, STRM_RDMA, admitted);
        $display("HOSTMUX NOTE remote writes admitted while the remote consumer is held: %0d of %0d", admitted, FILL_ATTEMPTS);
        check("a_held_remote_consumer_eventually_refuses_the_host_queue", (admitted < FILL_ATTEMPTS) ? 1 : 0, 1);
        report_counts("remote_held");
        check("each_admitted_remote_write_took_one_host_fetch", cnt_local_rd, admitted);
        remote_wr_ready = 1'b1;
        repeat (64) @(posedge aclk);
        report_counts("remote_released");
        check("every_admitted_remote_write_reaches_the_remote_path", cnt_remote_wr, admitted);

        $display("HOSTMUX CASE 7 the host fetch held, the output register fills, then release");
        clear_counts();
        local_rd_ready = 1'b0;
        offer_until_refused(1'b0, 1'b1, STRM_HOST, STRM_RDMA, admitted);
        $display("HOSTMUX NOTE remote writes admitted while the host fetch is held: %0d of %0d", admitted, FILL_ATTEMPTS);
        check("a_held_host_fetch_eventually_refuses_the_host_queue", (admitted < FILL_ATTEMPTS) ? 1 : 0, 1);
        report_counts("fetch_held");
        check("each_admitted_remote_write_reached_the_remote_path", cnt_remote_wr, admitted);
        local_rd_ready = 1'b1;
        repeat (64) @(posedge aclk);
        report_counts("fetch_released");
        check("every_admitted_remote_write_took_one_host_fetch", cnt_local_rd, admitted);

        $display("HOSTMUX CASE 8 a local read after the stalls leaves no residue");
        clear_counts();
        offer(1'b1, 1'b0, STRM_HOST, STRM_HOST, OFFER_TIMEOUT, accepted);
        check("local_read_after_stall_accepted", accepted, 1);
        check("local_read_after_stall_once", cnt_local_rd, 1);

        $display("HOSTMUX CASE 9 the remote path held forever blocks a later local read");
        clear_counts();
        remote_wr_ready = 1'b0;
        offer_until_refused(1'b0, 1'b1, STRM_HOST, STRM_RDMA, admitted);
        $display("HOSTMUX NOTE remote writes admitted before the queue blocked: %0d", admitted);
        report_counts("remote_blocked");
        offer(1'b1, 1'b0, STRM_HOST, STRM_HOST, OFFER_TIMEOUT, accepted);
        $display("HOSTMUX NOTE a local read offered while the remote write is stuck: accepted=%0d", accepted);
        check("the_single_host_queue_blocks_a_local_read_behind_a_stuck_remote_write", accepted, 0);

        $display("HOSTMUX CASE 10 a reset clears the pick up flags and the path recovers");
        pulse_reset(16);
        report_counts("after_reset");
        check("reset_clears_remote_wr_picked_up", dut.remote_wr_picked_up, 0);
        check("reset_clears_local_rd_picked_up", dut.local_rd_picked_up, 0);
        remote_wr_ready = 1'b1;
        clear_counts();
        offer(1'b0, 1'b1, STRM_HOST, STRM_RDMA, OFFER_TIMEOUT, accepted);
        check("remote_write_accepted_after_reset", accepted, 1);
        check("remote_write_once_after_reset", cnt_remote_wr, 1);
        check("host_fetch_once_after_reset", cnt_local_rd, 1);

        if (failures == 0) begin
            $display("HOSTMUX RESULT PASS all cases");
        end
        else begin
            $display("HOSTMUX RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
