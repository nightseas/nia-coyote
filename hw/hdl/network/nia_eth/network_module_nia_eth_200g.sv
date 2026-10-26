/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2026, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

`timescale 1ns / 1ps

import lynxTypes::*;

module network_module_nia_eth_200g (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         gt_refclk_p,
    input  wire         gt_refclk_n,

    input  wire [3:0]   gt_rxp_in,
    input  wire [3:0]   gt_rxn_in,
    output wire [3:0]   gt_txp_out,
    output wire [3:0]   gt_txn_out,

    AXI4S.m             m_axis_net_rx,
    AXI4S.s             s_axis_net_tx,

    input  wire         stat_clk,
    output wire [63:0]  m_seam_rx_stat
);

localparam integer NIA_ETH_SEG_COUNT             = 4;
localparam integer NIA_ETH_SEG_BITS              = 128;
localparam integer NIA_ETH_STREAM_BITS           = 1024;
localparam integer NIA_ETH_STREAM_KEEP_BITS      = NIA_ETH_STREAM_BITS / 8;
localparam integer NIA_ETH_RX_BUFFER_ADDR_BITS   = 11;
localparam integer NIA_ETH_MAC_SLOTS_PER_PORT    = 2;
localparam integer NIA_ETH_MAC_SLOT_FIRST        = 0;
localparam integer NIA_ETH_MAC_SLOT_COUNT        = 6;
localparam integer NIA_ETH_SEG_CLK_CYCLES_PER_MS = 390625;
localparam integer NIA_ETH_CTL_CLK_CYCLES_PER_MS = 250000;
localparam integer NIA_ETH_LINK_WATCHDOG_MS      = 750;
localparam logic [7:0] NIA_ETH_QSFP0_TX_POLARITY = 8'b0000_1100;
localparam logic [7:0] NIA_ETH_QSFP0_RX_POLARITY = 8'b0000_0000;

wire nia_eth_stream_clk;
wire nia_eth_stream_reset;
wire nia_eth_stream_resetn;
wire nia_eth_rx_clk;
wire nia_eth_rx_reset;
wire nia_eth_seg_clk;

wire [31:0] mac_rx_drop_frames;
wire [31:0] mac_rx_err_frames;
wire        mac_rx_overflow;
wire        mac_rx_trunc;
wire [31:0] seam_rx_drop_frames;
wire        seam_rx_overflow;

reg mac_rx_overflow_held = 1'b0;
reg mac_rx_trunc_held = 1'b0;
reg seam_rx_overflow_held = 1'b0;

wire [31:0] mac_rx_drop_frames_stat;
wire [12:0] mac_rx_err_frames_stat;
wire [15:0] seam_rx_drop_frames_stat;
wire [1:0]  mac_rx_flags_stat;
wire        seam_rx_overflow_stat;

assign nia_eth_stream_resetn = ~nia_eth_stream_reset;

wire [NIA_ETH_STREAM_BITS-1:0]      nia_eth_rx_tdata;
wire [NIA_ETH_STREAM_KEEP_BITS-1:0] nia_eth_rx_tkeep;
wire                                nia_eth_rx_tvalid;
wire                                nia_eth_rx_tlast;
wire                                nia_eth_rx_tuser;
wire                                nia_eth_rx_buffer_tready;

wire [NIA_ETH_STREAM_BITS-1:0]      nia_eth_rx_buffered_tdata;
wire [NIA_ETH_STREAM_KEEP_BITS-1:0] nia_eth_rx_buffered_tkeep;
wire                                nia_eth_rx_buffered_tvalid;
wire                                nia_eth_rx_buffered_tready;
wire                                nia_eth_rx_buffered_tlast;

wire [NIA_ETH_STREAM_BITS-1:0]      nia_eth_tx_tdata;
wire [NIA_ETH_STREAM_KEEP_BITS-1:0] nia_eth_tx_tkeep;
wire                                nia_eth_tx_tvalid;
wire                                nia_eth_tx_tready;
wire                                nia_eth_tx_tlast;

AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) axis_net_tx_padded (.aclk(aclk), .aresetn(aresetn));
AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) axis_net_rx_aclk (.aclk(aclk), .aresetn(aresetn));
AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) axis_net_rx_stream_clk (.aclk(nia_eth_stream_clk), .aresetn(nia_eth_stream_resetn));
AXI4S #(.AXI4S_DATA_BITS(AXI_NET_BITS)) axis_net_tx_stream_clk (.aclk(nia_eth_stream_clk), .aresetn(nia_eth_stream_resetn));

ethernet_frame_padding_512_ip inst_frame_padding (
    .ap_clk(aclk),
    .ap_rst_n(aresetn),
    .s_axis_TVALID(s_axis_net_tx.tvalid),
    .s_axis_TREADY(s_axis_net_tx.tready),
    .s_axis_TDATA(s_axis_net_tx.tdata),
    .s_axis_TKEEP(s_axis_net_tx.tkeep),
    .s_axis_TLAST(s_axis_net_tx.tlast),
    .m_axis_TVALID(axis_net_tx_padded.tvalid),
    .m_axis_TREADY(axis_net_tx_padded.tready),
    .m_axis_TDATA(axis_net_tx_padded.tdata),
    .m_axis_TKEEP(axis_net_tx_padded.tkeep),
    .m_axis_TLAST(axis_net_tx_padded.tlast)
);

network_ccross_early #(
    .ENABLED(1),
    .N_STGS(2)
) inst_stream_clk_ccross (
    .rclk(nia_eth_stream_clk),
    .rresetn(nia_eth_stream_resetn),
    .nclk(aclk),
    .nresetn(aresetn),
    .s_axis_rclk(axis_net_rx_stream_clk),
    .m_axis_rclk(axis_net_tx_stream_clk),
    .s_axis_nclk(axis_net_tx_padded),
    .m_axis_nclk(axis_net_rx_aclk)
);

axis_reg_array #(.N_STAGES(2)) inst_reg_net_rx (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axis(axis_net_rx_aclk),
    .m_axis(m_axis_net_rx)
);

dcmac_axis_frame_fifo #(
    .DATA_W(NIA_ETH_STREAM_BITS),
    .KEEP_W(NIA_ETH_STREAM_KEEP_BITS),
    .USER_W(1),
    .ADDR_W(NIA_ETH_RX_BUFFER_ADDR_BITS),
    .DROP_BAD_FRAME(1'b0),
    .FLAG_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1),
    .MAX_FRAME_BEATS(0),
    .MEM_STYLE("block")
) inst_nia_eth_rx_buffer (
    .clk(nia_eth_stream_clk),
    .rstn(nia_eth_stream_resetn),
    .abort(1'b0),
    .s_axis_tdata(nia_eth_rx_tdata),
    .s_axis_tkeep(nia_eth_rx_tkeep),
    .s_axis_tvalid(nia_eth_rx_tvalid),
    .s_axis_tready(nia_eth_rx_buffer_tready),
    .s_axis_tlast(nia_eth_rx_tlast),
    .s_axis_tuser(nia_eth_rx_tuser),
    .m_axis_tdata(nia_eth_rx_buffered_tdata),
    .m_axis_tkeep(nia_eth_rx_buffered_tkeep),
    .m_axis_tvalid(nia_eth_rx_buffered_tvalid),
    .m_axis_tready(nia_eth_rx_buffered_tready),
    .m_axis_tlast(nia_eth_rx_buffered_tlast),
    .m_axis_tuser(),
    .drop_frames(seam_rx_drop_frames),
    .overflow(seam_rx_overflow)
);

axis_dwidth_converter_nia_eth_rx_1024_to_512 inst_nia_eth_rx_dwidth (
    .aclk(nia_eth_stream_clk),
    .aresetn(nia_eth_stream_resetn),
    .s_axis_tvalid(nia_eth_rx_buffered_tvalid),
    .s_axis_tready(nia_eth_rx_buffered_tready),
    .s_axis_tdata(nia_eth_rx_buffered_tdata),
    .s_axis_tkeep(nia_eth_rx_buffered_tkeep),
    .s_axis_tlast(nia_eth_rx_buffered_tlast),
    .m_axis_tvalid(axis_net_rx_stream_clk.tvalid),
    .m_axis_tready(axis_net_rx_stream_clk.tready),
    .m_axis_tdata(axis_net_rx_stream_clk.tdata),
    .m_axis_tkeep(axis_net_rx_stream_clk.tkeep),
    .m_axis_tlast(axis_net_rx_stream_clk.tlast)
);

axis_dwidth_converter_nia_eth_tx_512_to_1024 inst_nia_eth_tx_dwidth (
    .aclk(nia_eth_stream_clk),
    .aresetn(nia_eth_stream_resetn),
    .s_axis_tvalid(axis_net_tx_stream_clk.tvalid),
    .s_axis_tready(axis_net_tx_stream_clk.tready),
    .s_axis_tdata(axis_net_tx_stream_clk.tdata),
    .s_axis_tkeep(axis_net_tx_stream_clk.tkeep),
    .s_axis_tlast(axis_net_tx_stream_clk.tlast),
    .m_axis_tvalid(nia_eth_tx_tvalid),
    .m_axis_tready(nia_eth_tx_tready),
    .m_axis_tdata(nia_eth_tx_tdata),
    .m_axis_tkeep(nia_eth_tx_tkeep),
    .m_axis_tlast(nia_eth_tx_tlast)
);

dcmac_axis_top #(
    .N_SEG(NIA_ETH_SEG_COUNT),
    .SEG_W(NIA_ETH_SEG_BITS),
    .DATA_W(NIA_ETH_STREAM_BITS),
    .PTP_TS_EN(0),
    .TX_TAG_W(0),
    .SEG_CYC_PER_MS(NIA_ETH_SEG_CLK_CYCLES_PER_MS),
    .LINK_WDT_MS(NIA_ETH_LINK_WATCHDOG_MS),
    .PORT_MAX(NIA_ETH_MAC_SLOT_COUNT),
    .NPORTS(NIA_ETH_MAC_SLOTS_PER_PORT),
    .ANCHOR(NIA_ETH_MAC_SLOT_FIRST),
    .LOOPBACK_MODE(3'b000),
    .EN_CTL_SEQ(1),
    .CTL_CYC_PER_MS(NIA_ETH_CTL_CLK_CYCLES_PER_MS),
    .DONE_MASK(dcmac_ctl_pkg::DONEMASK_200G),
    .RATE_CODE(dcmac_ctl_pkg::RATE_CODE_200G),
    .RATE_FIELD(dcmac_ctl_pkg::RATE_FIELD_200G),
    .POLARITY_TX_Q0(NIA_ETH_QSFP0_TX_POLARITY),
    .POLARITY_RX_Q0(NIA_ETH_QSFP0_RX_POLARITY)
) inst_nia_eth_mac (
    .sys_reset(~aresetn),
    .gt_ref_clk_p(gt_refclk_p),
    .gt_ref_clk_n(gt_refclk_n),
    .gt_rxp_in(gt_rxp_in),
    .gt_rxn_in(gt_rxn_in),
    .gt_txp_out(gt_txp_out),
    .gt_txn_out(gt_txn_out),

    .tx_clk(nia_eth_stream_clk),
    .tx_rst(nia_eth_stream_reset),
    .rx_clk(nia_eth_rx_clk),
    .rx_rst(nia_eth_rx_reset),

    .s_axis_tx_tdata(nia_eth_tx_tdata),
    .s_axis_tx_tkeep(nia_eth_tx_tkeep),
    .s_axis_tx_tvalid(nia_eth_tx_tvalid),
    .s_axis_tx_tready(nia_eth_tx_tready),
    .s_axis_tx_tlast(nia_eth_tx_tlast),
    .s_axis_tx_tuser(1'b0),

    .m_axis_tx_cpl_valid(),
    .m_axis_tx_cpl_ready(1'b1),
    .m_axis_tx_cpl_ts(),
    .m_axis_tx_cpl_tag(),

    .m_axis_rx_tdata(nia_eth_rx_tdata),
    .m_axis_rx_tkeep(nia_eth_rx_tkeep),
    .m_axis_rx_tvalid(nia_eth_rx_tvalid),
    .m_axis_rx_tlast(nia_eth_rx_tlast),
    .m_axis_rx_tuser(nia_eth_rx_tuser),

    .seg_ptp_time(80'd0),
    .seg_clk(nia_eth_seg_clk),

    .tx_status(),
    .rx_status(),
    .link_up(),
    .rx_overflow(mac_rx_overflow),
    .rx_trunc(mac_rx_trunc),
    .rx_err_frames(mac_rx_err_frames),
    .rx_align_stat(),
    .rx_drop_frames(mac_rx_drop_frames),
    .tx_cpl_overflow(),
    .mac_fsm_state(),

    .ctl_bringup_restart_req(1'b0),
    .ctl_stats_req(1'b0),
    .ctl_rx_force_resync_req(1'b0),
    .ctl_rx_datapath_reset_req(1'b0),
    .ctl_tx_datapath_reset_req(1'b0),
    .ctl_link_fault(),
    .ctl_access_fault(),
    .ctl_seq_busy(),
    .ctl_rx_phy_status(),
    .ctl_retry_cnt(),
    .ctl_seq_state(),
    .ctl_seq_pc(),
    .ctl_stat_rd_idx(8'd0),
    .ctl_stat_rd_data(),

    .s_axil_awaddr(20'd0),
    .s_axil_awvalid(1'b0),
    .s_axil_awready(),
    .s_axil_wdata(32'd0),
    .s_axil_wstrb(4'd0),
    .s_axil_wvalid(1'b0),
    .s_axil_wready(),
    .s_axil_bresp(),
    .s_axil_bvalid(),
    .s_axil_bready(1'b1),
    .s_axil_araddr(20'd0),
    .s_axil_arvalid(1'b0),
    .s_axil_arready(),
    .s_axil_rdata(),
    .s_axil_rresp(),
    .s_axil_rvalid(),
    .s_axil_rready(1'b1)
);

always_ff @(posedge nia_eth_seg_clk) begin
    if (mac_rx_overflow) mac_rx_overflow_held <= 1'b1;
    if (mac_rx_trunc)    mac_rx_trunc_held    <= 1'b1;
end

always_ff @(posedge nia_eth_stream_clk) begin
    if (seam_rx_overflow) seam_rx_overflow_held <= 1'b1;
end

xpm_cdc_gray #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .REG_OUTPUT(1),
    .SIM_ASSERT_CHK(0),
    .SIM_LOSSLESS_GRAY_CHK(0),
    .WIDTH(32)
) inst_cdc_mac_rx_drop_frames (
    .src_clk(nia_eth_seg_clk),
    .src_in_bin(mac_rx_drop_frames),
    .dest_clk(stat_clk),
    .dest_out_bin(mac_rx_drop_frames_stat)
);

xpm_cdc_gray #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .REG_OUTPUT(1),
    .SIM_ASSERT_CHK(0),
    .SIM_LOSSLESS_GRAY_CHK(0),
    .WIDTH(13)
) inst_cdc_mac_rx_err_frames (
    .src_clk(nia_eth_seg_clk),
    .src_in_bin(mac_rx_err_frames[12:0]),
    .dest_clk(stat_clk),
    .dest_out_bin(mac_rx_err_frames_stat)
);

xpm_cdc_gray #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .REG_OUTPUT(1),
    .SIM_ASSERT_CHK(0),
    .SIM_LOSSLESS_GRAY_CHK(0),
    .WIDTH(16)
) inst_cdc_seam_rx_drop_frames (
    .src_clk(nia_eth_stream_clk),
    .src_in_bin(seam_rx_drop_frames[15:0]),
    .dest_clk(stat_clk),
    .dest_out_bin(seam_rx_drop_frames_stat)
);

xpm_cdc_array_single #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .SIM_ASSERT_CHK(0),
    .SRC_INPUT_REG(0),
    .WIDTH(2)
) inst_cdc_mac_rx_flags (
    .src_clk(nia_eth_seg_clk),
    .src_in({mac_rx_trunc_held, mac_rx_overflow_held}),
    .dest_clk(stat_clk),
    .dest_out(mac_rx_flags_stat)
);

xpm_cdc_single #(
    .DEST_SYNC_FF(4),
    .INIT_SYNC_FF(0),
    .SIM_ASSERT_CHK(0),
    .SRC_INPUT_REG(0)
) inst_cdc_seam_rx_overflow (
    .src_clk(nia_eth_stream_clk),
    .src_in(seam_rx_overflow_held),
    .dest_clk(stat_clk),
    .dest_out(seam_rx_overflow_stat)
);

assign m_seam_rx_stat = {
    mac_rx_flags_stat[0],
    mac_rx_flags_stat[1],
    seam_rx_overflow_stat,
    mac_rx_err_frames_stat,
    seam_rx_drop_frames_stat,
    mac_rx_drop_frames_stat
};

endmodule
