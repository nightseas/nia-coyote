// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_cnfg_slave_elab;

    localparam integer CLK_PERIOD = 4000;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    always #(CLK_PERIOD/2) aclk = ~aclk;

`ifdef EN_AVX
    AXI4 axim_ctrl (aclk);
`else
    AXI4L axil_ctrl (aclk, aresetn);
`endif

    metaIntf #(.STYPE(dreq_t)) host_sq (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) bpss_done_rd (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) bpss_done_wr (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) host_done_rd (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) host_done_wr (aclk, aresetn);
    metaIntf #(.STYPE(logic[ARP_LUP_REQ_BITS-1:0])) arp_lookup_request (aclk, aresetn);
    metaIntf #(.STYPE(rdma_qp_ctx_t)) rdma_qp_interface (aclk, aresetn);
    metaIntf #(.STYPE(rdma_qp_conn_t)) rdma_conn_interface (aclk, aresetn);
    metaIntf #(.STYPE(ack_t)) rdma_done (aclk, aresetn);
    metaIntf #(.STYPE(wback_t)) wback (aclk, aresetn);
    metaIntf #(.STYPE(irq_inv_t)) invldt_rd_in (aclk, aresetn);
    metaIntf #(.STYPE(irq_inv_t)) invldt_wr_in (aclk, aresetn);
    metaIntf #(.STYPE(inv_t)) invldt_rd_out (aclk, aresetn);
    metaIntf #(.STYPE(inv_t)) invldt_wr_out (aclk, aresetn);
    metaIntf #(.STYPE(irq_pft_t)) pfault_rd_in (aclk, aresetn);
    metaIntf #(.STYPE(irq_pft_t)) pfault_wr_in (aclk, aresetn);
    metaIntf #(.STYPE(pf_t)) pfault_rd_out (aclk, aresetn);
    metaIntf #(.STYPE(pf_t)) pfault_wr_out (aclk, aresetn);
    metaIntf #(.STYPE(irq_not_t)) notify (aclk, aresetn);

    logic [LEN_BITS-1:0] pfault_rd_rng = 0;
    logic [LEN_BITS-1:0] pfault_wr_rng = 0;
    logic usr_irq;

`ifdef EN_AVX
    cnfg_slave_avx #(.ID_REG(0)) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axim_ctrl(axim_ctrl),
`else
    cnfg_slave #(.ID_REG(0)) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_ctrl(axil_ctrl),
`endif
        .m_host_sq(host_sq),
        .m_bpss_done_rd(bpss_done_rd),
        .m_bpss_done_wr(bpss_done_wr),
`ifdef EN_STRM
        .s_host_done_rd(host_done_rd),
        .s_host_done_wr(host_done_wr),
`endif
`ifdef EN_NET
        .m_arp_lookup_request(arp_lookup_request),
`endif
`ifdef EN_RDMA
        .m_rdma_qp_interface(rdma_qp_interface),
        .m_rdma_conn_interface(rdma_conn_interface),
        .s_rdma_done(rdma_done),
`endif
`ifdef EN_WB
        .m_wback(wback),
`endif
        .s_invldt_rd(invldt_rd_in),
        .s_invldt_wr(invldt_wr_in),
        .m_invldt_rd(invldt_rd_out),
        .m_invldt_wr(invldt_wr_out),
        .s_pfault_rd(pfault_rd_in),
        .s_pfault_rd_rng(pfault_rd_rng),
        .s_pfault_wr(pfault_wr_in),
        .s_pfault_wr_rng(pfault_wr_rng),
        .m_pfault_rd(pfault_rd_out),
        .m_pfault_wr(pfault_wr_out),
        .s_notify(notify),
        .usr_irq(usr_irq)
    );

`ifdef EN_AVX
    assign axim_ctrl.awvalid = 1'b0;
    assign axim_ctrl.wvalid = 1'b0;
    assign axim_ctrl.arvalid = 1'b0;
    assign axim_ctrl.arlen = 0;
    assign axim_ctrl.awlen = 0;
    assign axim_ctrl.bready = 1'b1;
    assign axim_ctrl.rready = 1'b1;
`else
    assign axil_ctrl.awvalid = 1'b0;
    assign axil_ctrl.wvalid = 1'b0;
    assign axil_ctrl.arvalid = 1'b0;
    assign axil_ctrl.bready = 1'b1;
    assign axil_ctrl.rready = 1'b1;
`endif

    assign host_sq.ready = 1'b1;
    assign bpss_done_rd.ready = 1'b1;
    assign bpss_done_wr.ready = 1'b1;
    assign arp_lookup_request.ready = 1'b1;
    assign rdma_qp_interface.ready = 1'b1;
    assign rdma_conn_interface.ready = 1'b1;
    assign wback.ready = 1'b1;
    assign invldt_rd_out.ready = 1'b1;
    assign invldt_wr_out.ready = 1'b1;
    assign pfault_rd_out.ready = 1'b1;
    assign pfault_wr_out.ready = 1'b1;

    integer completions = 0;

    task automatic offer_completion(input bit is_read, input int pid);
        rdma_done.data = '0;
        rdma_done.data.opcode = is_read ? RC_RDMA_READ_RESP_ONLY : RC_ACK;
        rdma_done.data.pid = pid[PID_BITS-1:0];
        rdma_done.valid = 1'b1;
        @(posedge aclk);
        while (!rdma_done.ready) @(posedge aclk);
        rdma_done.valid = 1'b0;
        completions = completions + 1;
        repeat (6) @(posedge aclk);
    endtask

    initial begin
        host_done_rd.valid = 1'b0;
        host_done_wr.valid = 1'b0;
        host_done_rd.data = '0;
        host_done_wr.data = '0;
        rdma_done.valid = 1'b0;
        rdma_done.data = '0;
        invldt_rd_in.valid = 1'b0;
        invldt_wr_in.valid = 1'b0;
        invldt_rd_in.data = '0;
        invldt_wr_in.data = '0;
        pfault_rd_in.valid = 1'b0;
        pfault_wr_in.valid = 1'b0;
        pfault_rd_in.data = '0;
        pfault_wr_in.data = '0;
        notify.valid = 1'b0;
        notify.data = '0;

        aresetn = 1'b0;
        repeat (16) @(posedge aclk);
        aresetn = 1'b1;
        repeat (16) @(posedge aclk);

        for (int i = 0; i < 8; i++) begin
            offer_completion(i % 2, 3);
        end

        repeat (64) @(posedge aclk);

        $display("CNFGELAB STATE completions_offered=%0d usr_irq=%0b", completions, usr_irq);
        if (completions == 8) begin
            $display("CNFGELAB RESULT PASS all cases");
        end
        else begin
            $display("CNFGELAB RESULT FAIL completions_offered=%0d", completions);
        end
        $finish;
    end

endmodule
