// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

`ifdef DCMAC_FRAME_FIFO_BRAM
  `define DCMAC_RX_FRAME_FIFO_MEM_STYLE "block"
`else
  `define DCMAC_RX_FRAME_FIFO_MEM_STYLE "distributed"
`endif
`ifdef DCMAC_TX_FRAME_FIFO_BRAM
  `define DCMAC_TX_FRAME_FIFO_MEM_STYLE "block"
`else
  `define DCMAC_TX_FRAME_FIFO_MEM_STYLE "distributed"
`endif

`ifdef DCMAC_FIFO_IP
  `define DCMAC_ASYNC_FIFO_MOD nia_axis_async_fifo_ip
  `ifdef DCMAC_FRAME_FIFO_BRAM
    `define DCMAC_RX_FRAME_FIFO_MOD dcmac_axis_frame_fifo
  `else
    `define DCMAC_RX_FRAME_FIFO_MOD dcmac_axis_frame_fifo_ip
  `endif
  `ifdef DCMAC_TX_FRAME_FIFO_BRAM
    `define DCMAC_TX_FRAME_FIFO_MOD dcmac_axis_frame_fifo
  `else
    `define DCMAC_TX_FRAME_FIFO_MOD dcmac_axis_frame_fifo_ip
  `endif
`else
  `define DCMAC_ASYNC_FIFO_MOD nia_axis_async_fifo
  `define DCMAC_RX_FRAME_FIFO_MOD dcmac_axis_frame_fifo
  `define DCMAC_TX_FRAME_FIFO_MOD dcmac_axis_frame_fifo
`endif

module dcmac_axis_core #(
  parameter int N_SEG           = 2,
  parameter int SEG_W           = 128,
  parameter int AXI_NET_BITS    = 512,
  parameter int RX_FIFO_AW      = 9,
  parameter int RX_CDC_AW       = 9,
  parameter int TX_FIFO_AW      = 8,
  parameter int TX_CDC_AW        = 9,
  parameter int RX_RESET_CYCLES = 16,
  parameter int PORT_MAX        = 6,
  parameter int NPORTS          = 1,
  parameter int ANCHOR          = 0
)(
  input  logic                        seg_clk,
  input  logic                        seg_rstn,
  input  logic                        usr_clk,
  input  logic                        usr_rstn,

  output logic [AXI_NET_BITS-1:0]     m_rx_axis_tdata,
  output logic [AXI_NET_BITS/8-1:0]   m_rx_axis_tkeep,
  output logic                        m_rx_axis_tvalid,
  input  logic                        m_rx_axis_tready,
  output logic                        m_rx_axis_tlast,

  input  logic [AXI_NET_BITS-1:0]     s_tx_axis_tdata,
  input  logic [AXI_NET_BITS/8-1:0]   s_tx_axis_tkeep,
  input  logic                        s_tx_axis_tvalid,
  output logic                        s_tx_axis_tready,
  input  logic                        s_tx_axis_tlast,

  input  logic                        rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]      rx_seg_dat,
  input  logic [N_SEG-1:0]            rx_seg_ena,
  input  logic [N_SEG-1:0]            rx_seg_sop,
  input  logic [N_SEG-1:0]            rx_seg_eop,
  input  logic [N_SEG-1:0]            rx_seg_err,
  input  logic [N_SEG*4-1:0]          rx_seg_mty,

  input  logic                        tx_seg_ready,
  output logic                        tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]      tx_seg_dat,
  output logic [N_SEG-1:0]            tx_seg_ena,
  output logic [N_SEG-1:0]            tx_seg_sop,
  output logic [N_SEG-1:0]            tx_seg_eop,
  output logic [N_SEG-1:0]            tx_seg_err,
  output logic [N_SEG*4-1:0]          tx_seg_mty,

  input  logic                        stat_rx_aligned,
  input  logic                        rx_datapath_reset_req,
  input  logic                        tx_datapath_reset_req,
  input  logic                        rx_force_resync_req,
  output logic                        ctl_rx_enable,
  output logic                        ctl_rx_force_resync,
  output logic                        ctl_tx_enable,
  output logic                        ctl_tx_send_idle,
  output logic                        ctl_tx_send_lfi,
  output logic                        ctl_tx_send_rfi,
  output logic                        rx_datapath_reset,
  output logic                        tx_datapath_reset,
  output logic [PORT_MAX-1:0]         rx_datapath_reset_ports,
  output logic                        tx_rst,
  output logic [2:0]                  fsm_state,
  output logic                        link_up,
  output logic                        rx_overflow,
  output logic                        rx_trunc,
  output logic [31:0]                 rx_err_frames,
  output logic [31:0]                 rx_drop_frames
);
  localparam int SEG_BITS = N_SEG*SEG_W;
  localparam int SEG_KEEP = SEG_BITS/8;
  localparam int NET_KEEP = AXI_NET_BITS/8;

  logic tx_rst_seg;

  dcmac_mac_ctl_fsm #(
    .RX_RESET_CYCLES(RX_RESET_CYCLES), .PORT_MAX(PORT_MAX), .NPORTS(NPORTS), .ANCHOR(ANCHOR)
  ) u_fsm (
    .seg_clk               (seg_clk),
    .seg_rstn              (seg_rstn),
    .stat_rx_aligned       (stat_rx_aligned),
    .rx_datapath_reset_req (rx_datapath_reset_req),
    .tx_datapath_reset_req (tx_datapath_reset_req),
    .rx_force_resync_req   (rx_force_resync_req),
    .ctl_rx_enable         (ctl_rx_enable),
    .ctl_rx_force_resync   (ctl_rx_force_resync),
    .ctl_tx_enable         (ctl_tx_enable),
    .ctl_tx_send_idle      (ctl_tx_send_idle),
    .ctl_tx_send_lfi       (ctl_tx_send_lfi),
    .ctl_tx_send_rfi       (ctl_tx_send_rfi),
    .rx_datapath_reset     (rx_datapath_reset),
    .tx_datapath_reset     (tx_datapath_reset),
    .rx_datapath_reset_ports(rx_datapath_reset_ports),
    .tx_rst_seg            (tx_rst_seg),
    .link_up               (link_up),
    .fsm_state             (fsm_state)
  );

  (* ASYNC_REG = "TRUE" *) logic tx_rst_sync0 = 1'b1;
  (* ASYNC_REG = "TRUE" *) logic tx_rst_sync1 = 1'b1;
  always_ff @(posedge usr_clk) begin
    tx_rst_sync0 <= tx_rst_seg;
    tx_rst_sync1 <= tx_rst_sync0;
  end
  assign tx_rst = tx_rst_sync1;

  logic rx_gated_valid;
  assign rx_gated_valid = rx_seg_valid & link_up;

  logic [SEG_BITS-1:0] rxa_tdata;
  logic [SEG_KEEP-1:0] rxa_tkeep;
  logic                rxa_tvalid, rxa_tready, rxa_tlast, rxa_tuser;

  dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_seg_rx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .rx_seg_valid  (rx_gated_valid),
    .rx_seg_dat    (rx_seg_dat),
    .rx_seg_ena    (rx_seg_ena),
    .rx_seg_sop    (rx_seg_sop),
    .rx_seg_eop    (rx_seg_eop),
    .rx_seg_err    (rx_seg_err),
    .rx_seg_mty    (rx_seg_mty),
    .m_axis_tdata  (rxa_tdata),
    .m_axis_tkeep  (rxa_tkeep),
    .m_axis_tvalid (rxa_tvalid),
    .m_axis_tready (rxa_tready),
    .m_axis_tlast  (rxa_tlast),
    .m_axis_tuser  (rxa_tuser)
  );

  logic        rxa_err_seen;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                    rxa_err_seen <= 1'b0;
    else if (rxa_tvalid && rxa_tlast) rxa_err_seen <= 1'b0;
    else if (rxa_tvalid)              rxa_err_seen <= rxa_err_seen | rxa_tuser;
  end

  logic [31:0] rx_err_cnt;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                                  rx_err_cnt <= '0;
    else if (rxa_tvalid && rxa_tlast && (rxa_tuser | rxa_err_seen) &&
             rx_err_cnt != 32'hFFFF_FFFF)           rx_err_cnt <= rx_err_cnt + 1'b1;
  end
  assign rx_err_frames = rx_err_cnt;

  logic rx_in_frame;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)         rx_in_frame <= 1'b0;
    else if (rxa_tvalid)   rx_in_frame <= ~rxa_tlast;
  end

  logic        link_up_1d;
  logic        rx_abort;
  logic [2:0]  rx_flush_cnt;
  logic        rx_trunc_r;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      link_up_1d   <= 1'b0;
      rx_flush_cnt <= '0;
      rx_trunc_r   <= 1'b0;
    end else begin
      link_up_1d <= link_up;
      if (rx_abort) begin
        rx_flush_cnt <= 3'd4;
        rx_trunc_r   <= 1'b1;
      end else if (rx_flush_cnt != '0) begin
        rx_flush_cnt <= rx_flush_cnt - 1'b1;
      end
    end
  end
  assign rx_abort = link_up_1d & ~link_up & rx_in_frame;
  assign rx_trunc = rx_trunc_r;

  logic rx_up_rstn;
  assign rx_up_rstn = seg_rstn & ~(rx_abort | (rx_flush_cnt != 3'd0));

  logic [AXI_NET_BITS-1:0] rxu_tdata;
  logic [NET_KEEP-1:0]     rxu_tkeep;
  logic                    rxu_tvalid, rxu_tready, rxu_tlast, rxu_tuser;

  nia_axis_dwidth_up #(.IN_W(SEG_BITS), .OUT_W(AXI_NET_BITS)) u_rx_up (
    .clk           (seg_clk),
    .rstn          (rx_up_rstn),
    .s_axis_tdata  (rxa_tdata),
    .s_axis_tkeep  (rxa_tkeep),
    .s_axis_tvalid (rxa_tvalid),
    .s_axis_tready (rxa_tready),
    .s_axis_tlast  (rxa_tlast),
    .s_axis_tuser  (rxa_tuser),
    .m_axis_tdata  (rxu_tdata),
    .m_axis_tkeep  (rxu_tkeep),
    .m_axis_tvalid (rxu_tvalid),
    .m_axis_tready (rxu_tready),
    .m_axis_tlast  (rxu_tlast),
    .m_axis_tuser  (rxu_tuser)
  );

  logic rx_gearbox_drop;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                            rx_gearbox_drop <= 1'b0;
    else if (rxa_tvalid && !rxa_tready)       rx_gearbox_drop <= 1'b1;
  end

  logic rx_fifo_overflow;
  logic rx_cdc_overflow;

  logic [AXI_NET_BITS-1:0] rxq_tdata;
  logic [NET_KEEP-1:0]     rxq_tkeep;
  logic                    rxq_tvalid, rxq_tready, rxq_tlast, rxq_tuser;
  logic [31:0]             rx_drop_cnt;

  `DCMAC_RX_FRAME_FIFO_MOD #(
    .DATA_W(AXI_NET_BITS), .KEEP_W(NET_KEEP), .ADDR_W(RX_FIFO_AW),
    .DROP_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1),
    .MEM_STYLE(`DCMAC_RX_FRAME_FIFO_MEM_STYLE)
  ) u_rx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .abort         (rx_abort),
    .s_axis_tdata  (rxu_tdata),
    .s_axis_tkeep  (rxu_tkeep),
    .s_axis_tvalid (rxu_tvalid),
    .s_axis_tready (rxu_tready),
    .s_axis_tlast  (rxu_tlast),
    .s_axis_tuser  (rxu_tuser),
    .m_axis_tdata  (rxq_tdata),
    .m_axis_tkeep  (rxq_tkeep),
    .m_axis_tvalid (rxq_tvalid),
    .m_axis_tready (rxq_tready),
    .m_axis_tlast  (rxq_tlast),
    .m_axis_tuser  (rxq_tuser),
    .drop_frames   (rx_drop_cnt),
    .overflow      (rx_fifo_overflow)
  );
  assign rx_drop_frames = rx_drop_cnt;

  `DCMAC_ASYNC_FIFO_MOD #(
    .DATA_W(AXI_NET_BITS), .KEEP_W(NET_KEEP), .ADDR_W(RX_CDC_AW), .DROP_ON_FULL(1'b0)
  ) u_rx_cdc (
    .s_clk         (seg_clk),
    .s_rstn        (seg_rstn),
    .s_axis_tdata  (rxq_tdata),
    .s_axis_tkeep  (rxq_tkeep),
    .s_axis_tvalid (rxq_tvalid),
    .s_axis_tready (rxq_tready),
    .s_axis_tlast  (rxq_tlast),
    .s_axis_tuser  (rxq_tuser),
    .m_clk         (usr_clk),
    .m_rstn        (usr_rstn),
    .m_axis_tdata  (m_rx_axis_tdata),
    .m_axis_tkeep  (m_rx_axis_tkeep),
    .m_axis_tvalid (m_rx_axis_tvalid),
    .m_axis_tready (m_rx_axis_tready),
    .m_axis_tlast  (m_rx_axis_tlast),
    .m_axis_tuser  (),
    .overflow      (rx_cdc_overflow)
  );

  assign rx_overflow = rx_fifo_overflow | rx_cdc_overflow | rx_gearbox_drop;

  logic [AXI_NET_BITS-1:0] txf_tdata;
  logic [NET_KEEP-1:0]     txf_tkeep;
  logic                    txf_tvalid, txf_tready, txf_tlast, txf_tuser;

  `DCMAC_ASYNC_FIFO_MOD #(
    .DATA_W(AXI_NET_BITS), .KEEP_W(NET_KEEP), .ADDR_W(TX_CDC_AW), .DROP_ON_FULL(1'b0)
  ) u_tx_cdc (
    .s_clk         (usr_clk),
    .s_rstn        (usr_rstn),
    .s_axis_tdata  (s_tx_axis_tdata),
    .s_axis_tkeep  (s_tx_axis_tkeep),
    .s_axis_tvalid (s_tx_axis_tvalid),
    .s_axis_tready (s_tx_axis_tready),
    .s_axis_tlast  (s_tx_axis_tlast),
    .s_axis_tuser  (1'b0),
    .m_clk         (seg_clk),
    .m_rstn        (seg_rstn),
    .m_axis_tdata  (txf_tdata),
    .m_axis_tkeep  (txf_tkeep),
    .m_axis_tvalid (txf_tvalid),
    .m_axis_tready (txf_tready),
    .m_axis_tlast  (txf_tlast),
    .m_axis_tuser  (txf_tuser),
    .overflow      ()
  );

  logic [AXI_NET_BITS-1:0] txp_tdata;
  logic [NET_KEEP-1:0]     txp_tkeep;
  logic                    txp_tvalid, txp_tready, txp_tlast, txp_tuser;

  `DCMAC_TX_FRAME_FIFO_MOD #(
    .DATA_W(AXI_NET_BITS), .KEEP_W(NET_KEEP), .ADDR_W(TX_FIFO_AW),
    .DROP_BAD_FRAME(1'b0), .DROP_WHEN_FULL(1'b0),
    .MEM_STYLE(`DCMAC_TX_FRAME_FIFO_MEM_STYLE)
  ) u_tx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .abort         (1'b0),
    .s_axis_tdata  (txf_tdata),
    .s_axis_tkeep  (txf_tkeep),
    .s_axis_tvalid (txf_tvalid),
    .s_axis_tready (txf_tready),
    .s_axis_tlast  (txf_tlast),
    .s_axis_tuser  (txf_tuser),
    .m_axis_tdata  (txp_tdata),
    .m_axis_tkeep  (txp_tkeep),
    .m_axis_tvalid (txp_tvalid),
    .m_axis_tready (txp_tready),
    .m_axis_tlast  (txp_tlast),
    .m_axis_tuser  (txp_tuser),
    .drop_frames   (),
    .overflow      ()
  );

  logic tx_gate, tx_in_frame;
  logic [AXI_NET_BITS-1:0] txg_tdata;
  logic [NET_KEEP-1:0]     txg_tkeep;
  logic                    txg_tvalid, txg_tready, txg_tlast, txg_tuser;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                          tx_in_frame <= 1'b0;
    else if (txg_tvalid && txg_tready)      tx_in_frame <= ~txg_tlast;
  end

  assign tx_gate    = ctl_tx_enable | tx_in_frame;
  assign txg_tdata  = txp_tdata;
  assign txg_tkeep  = txp_tkeep;
  assign txg_tlast  = txp_tlast;
  assign txg_tuser  = txp_tuser;
  assign txg_tvalid = txp_tvalid & tx_gate;
  assign txp_tready = txg_tready & tx_gate;

  logic [SEG_BITS-1:0] txd_tdata;
  logic [SEG_KEEP-1:0] txd_tkeep;
  logic                txd_tvalid, txd_tready, txd_tlast, txd_tuser;

  nia_axis_dwidth_down #(.IN_W(AXI_NET_BITS), .OUT_W(SEG_BITS)) u_tx_dn (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txg_tdata),
    .s_axis_tkeep  (txg_tkeep),
    .s_axis_tvalid (txg_tvalid),
    .s_axis_tready (txg_tready),
    .s_axis_tlast  (txg_tlast),
    .s_axis_tuser  (txg_tuser),
    .m_axis_tdata  (txd_tdata),
    .m_axis_tkeep  (txd_tkeep),
    .m_axis_tvalid (txd_tvalid),
    .m_axis_tready (txd_tready),
    .m_axis_tlast  (txd_tlast),
    .m_axis_tuser  (txd_tuser)
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_seg_tx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txd_tdata),
    .s_axis_tkeep  (txd_tkeep),
    .s_axis_tvalid (txd_tvalid),
    .s_axis_tready (txd_tready),
    .s_axis_tlast  (txd_tlast),
    .s_axis_tuser  (txd_tuser),
    .tx_seg_ready  (tx_seg_ready),
    .tx_seg_valid  (tx_seg_valid),
    .tx_seg_dat    (tx_seg_dat),
    .tx_seg_ena    (tx_seg_ena),
    .tx_seg_sop    (tx_seg_sop),
    .tx_seg_eop    (tx_seg_eop),
    .tx_seg_err    (tx_seg_err),
    .tx_seg_mty    (tx_seg_mty)
  );
endmodule
