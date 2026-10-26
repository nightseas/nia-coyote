// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_req_credits_retention;

    localparam integer CLK_PERIOD = 4000;
    localparam integer REFUSE_TIMEOUT = 200;
    localparam integer REQUEST_LEN = 4096;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    logic xfer = 1'b0;

    integer failures = 0;
    integer expect_reset_clears = 0;
    integer expect_credits_initialised = 1;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    metaIntf #(.STYPE(req_t)) s_req (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(req_t)) m_req (.aclk(aclk), .aresetn(aresetn));

    req_credits_rd dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_req(s_req),
        .m_req(m_req),
        .xfer(xfer)
    );

    assign m_req.ready = 1'b1;

    task automatic pulse_reset(input int cycles);
        aresetn = 1'b0;
        repeat (cycles) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge aclk);
    endtask

    task automatic offer_request(input int len, input int timeout_cycles, output bit accepted);
        int waited;
        accepted = 1'b0;
        waited = 0;
        s_req.data = '0;
        s_req.data.opcode = RC_RDMA_WRITE_ONLY;
        s_req.data.len = len;
        s_req.data.vaddr = 64'h1000;
        s_req.valid = 1'b1;
        while (waited < timeout_cycles && accepted == 1'b0) begin
            @(posedge aclk);
            if (s_req.ready) accepted = 1'b1;
            waited = waited + 1;
        end
        s_req.valid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic deliver_beats(input int beats);
        for (int i = 0; i < beats; i++) begin
            xfer = 1'b1;
            @(posedge aclk);
        end
        xfer = 1'b0;
        @(posedge aclk);
    endtask

    task automatic report_credits(input string tag);
        $display("CREDRET STATE %s cred_reg_C=%0d cnt_C=%0h xfer_int=%0b state_C=%0d",
                 tag, dut.cred_reg_C, dut.cnt_C, dut.xfer_int, dut.state_C);
    endtask

    task automatic check(input string name, input bit got, input bit want);
        if (got === want) begin
            $display("CREDRET RESULT PASS %s", name);
        end
        else begin
            $display("CREDRET RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    initial begin
        bit accepted;
        int admitted;

        void'($value$plusargs("expect_reset_clears=%d", expect_reset_clears));
        void'($value$plusargs("expect_credits_initialised=%d", expect_credits_initialised));

        s_req.valid = 1'b0;
        s_req.data = '0;
        pulse_reset(8);

        $display("CREDRET CONFIG outstanding=%0d beat_log_bits=%0d blen_bits=%0d expect_reset_clears=%0d",
                 N_OUTSTANDING, BEAT_LOG_BITS, BLEN_BITS, expect_reset_clears);
        report_credits("after_initial_reset");

        $display("CREDRET CASE 1 requests whose beats are delivered");
        accepted = 1'b1;
        for (int i = 0; i < 4*N_OUTSTANDING && accepted; i++) begin
            offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
            if (accepted) deliver_beats(REQUEST_LEN/(AXI_DATA_BITS/8));
        end
        if (expect_credits_initialised != 0) begin
            check("drained_requests_never_exhaust_credits", accepted, 1'b1);
        end
        else begin
            check("uninitialised_credit_count_refuses_every_request", accepted, 1'b0);
        end
        report_credits("after_case1");

        $display("CREDRET CASE 2 requests whose beats are never delivered");
        admitted = 0;
        accepted = 1'b1;
        for (int i = 0; i < 4*N_OUTSTANDING && accepted; i++) begin
            offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
            if (accepted) admitted = admitted + 1;
        end
        $display("CREDRET NOTE undrained requests admitted before refusal: %0d", admitted);
        check("undrained_requests_exhaust_the_path", accepted, 1'b0);
        report_credits("exhausted");

        $display("CREDRET CASE 3 the exhausted path against a reset");
        pulse_reset(16);
        report_credits("after_reset");
        offer_request(REQUEST_LEN, 4*REFUSE_TIMEOUT, accepted);
        if (expect_reset_clears != 0) begin
            check("reset_clears_the_outstanding_count", accepted, 1'b1);
        end
        else begin
            check("reset_does_not_clear_the_outstanding_count", accepted, 1'b0);
        end

        if (failures == 0) begin
            $display("CREDRET RESULT PASS all cases");
        end
        else begin
            $display("CREDRET RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
