// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_rdma_flow_window;

    localparam integer CLK_PERIOD = 2558;
    localparam integer OST = RDMA_N_WR_OUTSTANDING;
    localparam integer REFUSE_TIMEOUT = 200;
    localparam integer RESET_SETTLE = 2**(1+N_REGIONS_BITS+PID_BITS) + 32;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    integer failures = 0;
    integer expect_reset_clears_window = 0;
    integer expect_entry_alias = 1;
    integer expect_completion_loss = 1;

    always #(CLK_PERIOD/2) aclk = ~aclk;

    metaIntf #(.STYPE(dreq_t)) s_req (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dreq_t)) m_req (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dack_t)) s_ack (.aclk(aclk), .aresetn(aresetn));
    metaIntf #(.STYPE(dack_t)) m_ack (.aclk(aclk), .aresetn(aresetn));

    rdma_flow dut (
        .s_req(s_req),
        .m_req(m_req),
        .s_ack(s_ack),
        .m_ack(m_ack),
        .aclk(aclk),
        .aresetn(aresetn)
    );

    logic m_ack_ready = 1'b1;
    logic clr_cnt = 1'b0;
    integer cnt_ack_in = 0;
    integer cnt_cq_out = 0;

    assign m_req.ready = 1'b1;
    assign m_ack.ready = m_ack_ready;

    always_ff @(posedge aclk) begin
        if (!aresetn || clr_cnt) begin
            cnt_cq_out <= 0;
        end
        else begin
            if (m_ack.valid && m_ack.ready) cnt_cq_out <= cnt_cq_out + 1;
        end
    end

    task automatic prime_pointer_table();
        for (int i = 0; i < 2**(1+N_REGIONS_BITS+PID_BITS); i++) begin
            dut.inst_pntr_table.g_dist.ram[i] = 16'h0000;
        end
        dut.inst_pntr_table.g_dist.a_data_reg = 16'h0000;
    endtask

    task automatic pulse_reset(input int cycles);
        aresetn = 1'b0;
        repeat (cycles) @(posedge aclk);
        aresetn = 1'b1;
        repeat (RESET_SETTLE) @(posedge aclk);
    endtask

    task automatic offer_request(input logic [OPCODE_BITS-1:0] opcode,
                                 input int timeout_cycles,
                                 output bit accepted);
        int waited;
        accepted = 1'b0;
        waited = 0;
        s_req.data = '0;
        s_req.data.req_1.opcode = opcode;
        s_req.data.req_1.vfid = '0;
        s_req.data.req_1.pid = '0;
        s_req.data.req_1.len = 4096;
        s_req.valid = 1'b1;
        while (waited < timeout_cycles && accepted == 1'b0) begin
            @(posedge aclk);
            if (s_req.ready) accepted = 1'b1;
            waited = waited + 1;
        end
        s_req.valid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic clear_ack_counts();
        clr_cnt = 1'b1;
        @(posedge aclk);
        @(posedge aclk);
        clr_cnt = 1'b0;
        @(posedge aclk);
    endtask

    task automatic check_int(input string name, input integer got, input integer want);
        if (got === want) begin
            $display("FLOWWIN RESULT PASS %s", name);
        end
        else begin
            $display("FLOWWIN RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    task automatic offer_ack_counted(input logic [OPCODE_BITS-1:0] opcode, input logic last, output bit taken);
        int waited;
        taken = 1'b0;
        waited = 0;
        s_ack.data = '0;
        s_ack.data.ack.opcode = opcode;
        s_ack.data.ack.vfid = '0;
        s_ack.data.ack.pid = '0;
        s_ack.data.last = last;
        s_ack.valid = 1'b1;
        while (waited < REFUSE_TIMEOUT) begin
            @(posedge aclk);
            if (s_ack.ready) begin
                taken = 1'b1;
                break;
            end
            waited = waited + 1;
        end
        s_ack.valid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic offer_request_pid(input logic [OPCODE_BITS-1:0] opcode,
                                     input int pid,
                                     input int timeout_cycles,
                                     output bit accepted);
        int waited;
        accepted = 1'b0;
        waited = 0;
        s_req.data = '0;
        s_req.data.req_1.opcode = opcode;
        s_req.data.req_1.vfid = '0;
        s_req.data.req_1.pid = pid[PID_BITS-1:0];
        s_req.data.req_1.len = 4096;
        s_req.valid = 1'b1;
        while (waited < timeout_cycles && accepted == 1'b0) begin
            @(posedge aclk);
            if (s_req.ready) accepted = 1'b1;
            waited = waited + 1;
        end
        s_req.valid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic offer_ack(input logic [OPCODE_BITS-1:0] opcode, input logic last);
        int waited;
        waited = 0;
        s_ack.data = '0;
        s_ack.data.ack.opcode = opcode;
        s_ack.data.ack.vfid = '0;
        s_ack.data.ack.pid = '0;
        s_ack.data.last = last;
        s_ack.valid = 1'b1;
        while (waited < REFUSE_TIMEOUT) begin
            @(posedge aclk);
            if (s_ack.ready) break;
            waited = waited + 1;
        end
        s_ack.valid = 1'b0;
        @(posedge aclk);
    endtask

    task automatic report_window(input string tag);
        $display("FLOWWIN STATE %s entry_rd=%04h entry_wr=%04h",
                 tag,
                 dut.inst_pntr_table.g_dist.ram[{1'b1, {N_REGIONS_BITS{1'b0}}, {PID_BITS{1'b0}}}],
                 dut.inst_pntr_table.g_dist.ram[{1'b0, {N_REGIONS_BITS{1'b0}}, {PID_BITS{1'b0}}}]);
    endtask

    task automatic check(input string name, input bit got, input bit want);
        if (got === want) begin
            $display("FLOWWIN RESULT PASS %s", name);
        end
        else begin
            $display("FLOWWIN RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    integer acks_taken = 0;

    initial begin
        bit accepted;
        bit ack_taken;

        void'($value$plusargs("expect_reset_clears_window=%d", expect_reset_clears_window));
        void'($value$plusargs("expect_entry_alias=%d", expect_entry_alias));
        void'($value$plusargs("expect_completion_loss=%d", expect_completion_loss));

        s_req.valid = 1'b0;
        s_ack.valid = 1'b0;
        s_req.data = '0;
        s_ack.data = '0;

        prime_pointer_table();
        pulse_reset(8);

        $display("FLOWWIN CONFIG outstanding=%0d addr_bits=%0d reset_settle=%0d", OST, 1+N_REGIONS_BITS+PID_BITS, RESET_SETTLE);
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("module_available_after_reset_settle", accepted, 1'b1);
        if (accepted) offer_ack(RC_ACK, 1'b1);

        $display("FLOWWIN CASE 1 balanced write traffic, one acknowledgement per request");
        accepted = 1'b1;
        for (int i = 0; i < 4*OST && accepted; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (accepted) offer_ack(RC_ACK, 1'b1);
        end
        check("balanced_write_never_blocks", accepted, 1'b1);
        report_window("after_case1");

        $display("FLOWWIN CASE 2 one request answered by four acknowledgements");
        accepted = 1'b1;
        for (int i = 0; i < OST && accepted; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (accepted) begin
                offer_ack(RC_ACK, 1'b0);
                offer_ack(RC_ACK, 1'b0);
                offer_ack(RC_ACK, 1'b0);
                offer_ack(RC_ACK, 1'b1);
            end
        end
        check("over_acknowledgement_is_self_clearing", accepted, 1'b1);
        report_window("after_case2");

        $display("FLOWWIN CASE 3 window full with no acknowledgement, then one acknowledgement");
        for (int i = 0; i < OST; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (!accepted) $display("FLOWWIN NOTE case 3 request %0d was refused", i);
        end
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("window_closes_after_outstanding_limit", accepted, 1'b0);
        report_window("window_closed");
        offer_ack(RC_ACK, 1'b1);
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("one_acknowledgement_reopens_the_window", accepted, 1'b1);

        $display("FLOWWIN CASE 4 the closed window against a reset");
        for (int i = 0; i < 2*OST; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        end
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("write_entry_closed_before_reset", accepted, 1'b0);
        report_window("before_reset");
        pulse_reset(16);
        report_window("after_reset");
        offer_request(RC_RDMA_WRITE_ONLY, 4*REFUSE_TIMEOUT, accepted);
        if (expect_reset_clears_window != 0) begin
            check("reset_clears_the_closed_window", accepted, 1'b1);
        end
        else begin
            check("reset_does_not_clear_the_closed_window", accepted, 1'b0);
        end

        $display("FLOWWIN CASE 5 the read entry while the write entry is closed");
        if (expect_reset_clears_window == 0) begin
            offer_request(RC_RDMA_READ_REQUEST, REFUSE_TIMEOUT, accepted);
            if (expect_entry_alias != 0) begin
                check("read_request_refused_while_only_entry_zero_is_closed", accepted, 1'b0);
            end
            else begin
                check("read_request_admitted_while_only_the_write_entry_is_closed", accepted, 1'b1);
            end
            report_window("read_after_write_closed");
        end

        $display("FLOWWIN CASE 6 recovery by clearing the table, which models configuration");
        prime_pointer_table();
        repeat (4) @(posedge aclk);
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("table_clear_restores_the_write_entry", accepted, 1'b1);

        $display("FLOWWIN CASE 7 the read entry driven closed while entry zero stays open");
        prime_pointer_table();
        repeat (4) @(posedge aclk);
        for (int i = 0; i < 2*OST; i++) begin
            offer_request(RC_RDMA_READ_REQUEST, REFUSE_TIMEOUT, accepted);
        end
        report_window("read_entry_driven");
        offer_request(RC_RDMA_READ_REQUEST, REFUSE_TIMEOUT, accepted);
        if (expect_entry_alias != 0) begin
            check("read_request_admitted_although_its_own_entry_is_closed", accepted, 1'b1);
            check("read_entry_head_does_not_advance_past_one",
                  dut.inst_pntr_table.g_dist.ram[8'h80][7:4] == 4'h1, 1'b1);
        end
        else begin
            check("read_request_refused_once_its_own_entry_is_closed", accepted, 1'b0);
            check("read_entry_head_advances_with_its_own_requests",
                  dut.inst_pntr_table.g_dist.ram[8'h80][7:4] != 4'h1, 1'b1);
        end
        check("entry_zero_untouched_by_read_requests",
              dut.inst_pntr_table.g_dist.ram[8'h00] == 16'h0000, 1'b1);
        report_window("after_case7");

        $display("FLOWWIN CASE 8 alternating directions, one matching acknowledgement each");
        prime_pointer_table();
        repeat (4) @(posedge aclk);
        accepted = 1'b1;
        for (int i = 0; i < 4*OST && accepted; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (accepted) offer_ack(RC_ACK, 1'b1);
            offer_request(RC_RDMA_READ_REQUEST, REFUSE_TIMEOUT, accepted);
            if (accepted) offer_ack(RC_RDMA_READ_RESP_ONLY, 1'b1);
        end
        check("balanced_alternating_never_blocks", accepted, 1'b1);
        report_window("after_case8");

        $display("FLOWWIN CASE 9 a write acknowledged on the read entry, which is the mixed direction fault");
        prime_pointer_table();
        repeat (4) @(posedge aclk);
        for (int i = 0; i < OST; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (accepted) offer_ack(RC_RDMA_READ_RESP_ONLY, 1'b1);
        end
        report_window("writes_acked_on_the_read_entry");
        offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
        check("the_write_entry_closes_when_its_acknowledgements_land_elsewhere", accepted, 1'b0);
        offer_request(RC_RDMA_READ_REQUEST, REFUSE_TIMEOUT, accepted);
        if (expect_entry_alias != 0) begin
            check("the_closed_write_entry_also_refuses_a_read_request", accepted, 1'b0);
        end
        else begin
            check("the_closed_write_entry_leaves_a_read_request_admitted", accepted, 1'b1);
        end
        report_window("after_case9");

        $display("FLOWWIN CASE 10 recovery of the mixed direction fault");
        pulse_reset(16);
        offer_request(RC_RDMA_WRITE_ONLY, 4*REFUSE_TIMEOUT, accepted);
        if (expect_reset_clears_window != 0) begin
            check("a_reset_recovers_the_mixed_direction_fault", accepted, 1'b1);
        end
        else begin
            check("a_reset_does_not_recover_the_mixed_direction_fault", accepted, 1'b0);
            prime_pointer_table();
            repeat (4) @(posedge aclk);
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            check("only_a_table_clear_recovers_the_mixed_direction_fault", accepted, 1'b1);
        end

        $display("FLOWWIN CASE 12 one queue pair closed, another queue pair offered");
        prime_pointer_table();
        pulse_reset(8);
        for (int i = 0; i < 2*OST; i++) begin
            offer_request_pid(RC_RDMA_WRITE_ONLY, 0, REFUSE_TIMEOUT, accepted);
        end
        offer_request_pid(RC_RDMA_WRITE_ONLY, 0, REFUSE_TIMEOUT, accepted);
        check("queue_pair_zero_write_entry_closed", accepted, 1'b0);
        report_window("qp0_closed");
        offer_request_pid(RC_RDMA_WRITE_ONLY, 1, REFUSE_TIMEOUT, accepted);
        if (expect_entry_alias != 0) begin
            check("a_closed_queue_pair_refuses_every_other_queue_pair", accepted, 1'b0);
        end
        else begin
            check("a_closed_queue_pair_leaves_every_other_queue_pair_admitted", accepted, 1'b1);
        end
        $display("FLOWWIN STATE qp1_after entry_qp0_wr=%04h entry_qp1_wr=%04h",
                 dut.inst_pntr_table.g_dist.ram[{1'b0, {N_REGIONS_BITS{1'b0}}, {PID_BITS{1'b0}}}],
                 dut.inst_pntr_table.g_dist.ram[{1'b0, {N_REGIONS_BITS{1'b0}}, {{PID_BITS-1{1'b0}}, 1'b1}}]);

        $display("FLOWWIN CASE 11 the completion queue held, which must not lose a completion");
        prime_pointer_table();
        pulse_reset(8);
        clear_ack_counts();
        acks_taken = 0;
        m_ack_ready = 1'b0;
        for (int i = 0; i < 4*OST; i++) begin
            offer_request(RC_RDMA_WRITE_ONLY, REFUSE_TIMEOUT, accepted);
            if (accepted) begin
                offer_ack_counted(RC_ACK, 1'b1, ack_taken);
                if (ack_taken) acks_taken = acks_taken + 1;
            end
        end
        cnt_ack_in = acks_taken;
        $display("FLOWWIN NOTE acknowledgements taken while the completion queue is held: %0d", cnt_ack_in);
        m_ack_ready = 1'b1;
        repeat (4*OST + 64) @(posedge aclk);
        $display("FLOWWIN NOTE completions emitted after release: %0d", cnt_cq_out);
        if (expect_completion_loss != 0) begin
            check("a_held_completion_queue_loses_completions", (cnt_cq_out < cnt_ack_in) ? 1'b1 : 1'b0, 1'b1);
        end
        else begin
            check_int("every_taken_acknowledgement_yields_one_completion", cnt_cq_out, cnt_ack_in);
        end

        if (failures == 0) begin
            $display("FLOWWIN RESULT PASS all cases");
        end
        else begin
            $display("FLOWWIN RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
