// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_wr_credits_retention;

    localparam integer CLK_PERIOD = 4000;
    localparam integer REFUSE_TIMEOUT = 200;
    localparam integer REQUEST_LEN = 4096;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;
    logic xfer = 1'b0;

    integer failures = 0;
    integer expect_reset_clears = 0;

    always #(CLK_PERIOD/2) aclk = ~aclk;

`ifdef DREQ_WR
    metaIntf #(.STYPE(dreq_t)) s_req (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dreq_t)) m_req (.aclk(aclk), .aresetn(aresetn));

    dreq_credits_wr dut (
        .aclk(aclk), .aresetn(aresetn), .s_req(s_req), .m_req(m_req), .xfer(xfer)
    );
`else
    metaIntf #(.STYPE(req_t)) s_req (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(req_t)) m_req (.aclk(aclk), .aresetn(aresetn));

    req_credits_wr dut (
        .aclk(aclk), .aresetn(aresetn), .s_req(s_req), .m_req(m_req), .xfer(xfer)
    );
`endif

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
`ifdef DREQ_WR
        s_req.data.req_1.opcode = RC_RDMA_WRITE_ONLY;
        s_req.data.req_1.len = len;
        s_req.data.req_1.vaddr = 64'h5000;
`else
        s_req.data.opcode = RC_RDMA_WRITE_ONLY;
        s_req.data.len = len;
        s_req.data.vaddr = 64'h5000;
`endif
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

    task automatic report_state(input string tag);
`ifdef DREQ_WR
        $display("WCREDRET STATE %s cnt_C=%0h", tag, dut.cnt_C);
`else
        $display("WCREDRET STATE %s cnt_C=%0h xfer_int=%0b", tag, dut.cnt_C, dut.xfer_int);
`endif
    endtask

    task automatic check(input string name, input bit got, input bit want);
        if (got === want) begin
            $display("WCREDRET RESULT PASS %s", name);
        end
        else begin
            $display("WCREDRET RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    initial begin
        bit accepted;
        int beats;

        void'($value$plusargs("expect_reset_clears=%d", expect_reset_clears));

        beats = REQUEST_LEN/(AXI_DATA_BITS/8);

        s_req.valid = 1'b0;
        s_req.data = '0;
        pulse_reset(8);

        $display("WCREDRET CONFIG beat_log_bits=%0d blen_bits=%0d beats_per_request=%0d expect_reset_clears=%0d",
                 BEAT_LOG_BITS, BLEN_BITS, beats, expect_reset_clears);
        report_state("after_initial_reset");

        $display("WCREDRET CASE 1 a request offered before its beats arrive is refused");
        offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
        check("request_without_credit_is_refused", accepted, 1'b0);
        report_state("no_credit");

        $display("WCREDRET CASE 2 beats delivered first, then the request is admitted");
        deliver_beats(beats);
        report_state("credit_built");
        offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
        check("request_with_credit_is_admitted", accepted, 1'b1);
        report_state("credit_spent");

        $display("WCREDRET CASE 3 the credit is consumed, so a second request is refused");
        offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
        check("second_request_without_fresh_beats_is_refused", accepted, 1'b0);

        $display("WCREDRET CASE 4 a reset taken while a beat is in flight");
        xfer = 1'b1;
        repeat (4) @(posedge aclk);
        aresetn = 1'b0;
        repeat (8) @(posedge aclk);
        aresetn = 1'b1;
        xfer = 1'b0;
        repeat (256) @(posedge aclk);
        report_state("after_reset_with_xfer");
        offer_request(REQUEST_LEN, REFUSE_TIMEOUT, accepted);
        if (expect_reset_clears != 0) begin
            check("reset_clears_the_transfer_flag_so_no_credit_accrues", accepted, 1'b0);
        end
        else begin
            check("a_retained_transfer_flag_accrues_credit_with_no_beat_delivered", accepted, 1'b1);
        end

        if (failures == 0) begin
            $display("WCREDRET RESULT PASS all cases");
        end
        else begin
            $display("WCREDRET RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
