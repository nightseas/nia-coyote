// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module dcmac_link_ctl
  import dcmac_ctl_pkg::*;
#(

  parameter int          PORT_MAX    = 6,
  parameter int          NPORTS      = 1,

  parameter int          RATE_CODE   = RATE_CODE_100G,
  parameter int          RATE_FIELD  = RATE_FIELD_100G,
  parameter int          ANCHOR      = 0,
  parameter int          N_GROUP     = 1,
  parameter int          ANCHOR_1    = 1,
  parameter logic [19:0] BASE        = 20'h0,

  parameter int T_SAMPLE_MS = 50,
  parameter int N_BUS_ERR   = 16,
  parameter int          CYC_PER_MS  = 250_000,
  parameter bit          EN_STATS    = 1'b1,
  parameter bit          EN_RR_POLL  = 1'b1,
  parameter int          LINK_CONFIRM_N_BRINGUP = 2,

  parameter int          POLL_TRIES  = 60,
  parameter logic [7:0]  DONE_MASK   = DONEMASK_100G,

  parameter int LINK_WDT_MS     = 750,
  parameter int LINK_WDT_MS_MIN = 10,
  parameter int LINK_WDT_MS_MAX = 60000,
  parameter int LINK_CONFIRM_N  = 2,
  parameter int ESC_MAX_STAGE   = 3,
  parameter int T_RXDP_MS       = 100,
  parameter int T_SETTLE_MS     = 10,
  parameter int T_ERR_MS        = 10,

  parameter int SEG_CYC_PER_MS  = 390930,
  parameter int T_SERDES_MS     = 100,
  parameter int ALIGN_EXPORT_MODE = 1
) (
  input  wire                       aclk,
  input  wire                       aresetn,

  input  wire                       seg_clk,
  input  wire [N_GROUP-1:0]         seg_rstn,

  output wire [N_GROUP-1:0]         link_up,
  output wire [N_GROUP-1:0]         tx_rst_seg,
  output wire [N_GROUP-1:0]         carrier,
  output wire [3*N_GROUP-1:0]       mac_fsm_state,
  output wire [N_GROUP-1:0]         ctl_rx_enable,
  output wire [N_GROUP-1:0]         ctl_rx_force_resync,
  output wire [N_GROUP-1:0]         ctl_tx_enable,
  output wire [N_GROUP-1:0]         ctl_tx_send_idle,
  output wire [N_GROUP-1:0]         ctl_tx_send_lfi,
  output wire [N_GROUP-1:0]         ctl_tx_send_rfi,
  output wire [N_GROUP-1:0]         fsm_rx_datapath_reset,
  output wire [N_GROUP-1:0]         fsm_rx_pll_datapath_reset,
  output wire [N_GROUP-1:0]         fsm_gt_all_reset,
  output wire [N_GROUP-1:0]         fsm_rx_serdes_reset,
  output wire [N_GROUP-1:0]         fsm_rx_flush,
  input  wire [N_GROUP-1:0]         fsm_gt_rx_done,
  output wire [8*N_GROUP-1:0]       fsm_repair_count,
  output wire [8*N_GROUP-1:0]       fsm_repair_tmo_count,
  output wire [PORT_MAX*N_GROUP-1:0] fsm_rx_datapath_reset_ports,

  input  wire [N_GROUP-1:0]         host_link_reset_req,
  input  wire [N_GROUP-1:0]         host_rx_force_resync_req,

  output wire [19:0]                m_axil_awaddr,
  output wire                       m_axil_awvalid,
  input  wire                       m_axil_awready,
  output wire [31:0]                m_axil_wdata,
  output wire [3:0]                 m_axil_wstrb,
  output wire                       m_axil_wvalid,
  input  wire                       m_axil_wready,
  input  wire [1:0]                 m_axil_bresp,
  input  wire                       m_axil_bvalid,
  output wire                       m_axil_bready,
  output wire [19:0]                m_axil_araddr,
  output wire                       m_axil_arvalid,
  input  wire                       m_axil_arready,
  input  wire [31:0]                m_axil_rdata,
  input  wire [1:0]                 m_axil_rresp,
  input  wire                       m_axil_rvalid,
  output wire                       m_axil_rready,

  input  wire [7:0]                 gt_tx_reset_done,
  input  wire [7:0]                 gt_rx_reset_done,
  output wire                       rx_datapath_reset,
  output wire [PORT_MAX-1:0]        rx_datapath_reset_ports,
  output wire                       core_serdes_reset,
  output wire                       tx_datapath_reset,

  input  wire                       bringup_restart_req,
  input  wire                       stats_req,
  input  wire                       rx_force_resync_req,
  input  wire                       rx_datapath_reset_req,
  input  wire                       tx_datapath_reset_req,
  output wire                       rx_force_resync,

  input  wire [16*N_GROUP-1:0]      link_wdt_ms,

  output wire [N_GROUP-1:0]         rx_pcs_aligned,
  output wire                       link_fault,
  output wire                       access_fault,
  output wire                       seq_busy,
  output wire                       bringup_done,
  output wire [31:0]                rx_phy_status,
  output wire [7:0]                 retry_cnt,
  output wire [4:0]                 seq_state,
  output wire [15:0]                seq_pc,
  input  wire [7:0]                 stat_rd_idx,
  output wire [31:0]                stat_rd_data,

  output wire [N_GROUP-1:0]         link_reset_req,
  output wire [N_GROUP-1:0]         link_remote_fault,
  output wire [N_GROUP-1:0]         link_bus_stuck,
  output wire [N_GROUP-1:0]         link_ever_aligned,
  output wire [4*N_GROUP-1:0]       link_fault_nibble,
  output wire [32*N_GROUP-1:0]      link_align_word,
  output wire [32*N_GROUP-1:0]      link_align_sticky,

  output wire [16*N_GROUP-1:0]      sup_esc_count,
  output wire [16*N_GROUP-1:0]      link_sample_count,

  output wire [N_GROUP-1:0]         link_valid,
  output wire [N_GROUP-1:0]         link_window_running,
  output wire [N_GROUP-1:0]         link_last_was_fault,
  output wire [16*N_GROUP-1:0]      link_bus_err_count,
  output wire [40*N_GROUP-1:0]      link_window_remaining,
  output wire [15:0]                exec_tmo_count
);

  localparam int NG    = N_GROUP;
  localparam int N_REQ = 1 + NG;

  wire [19:0] sq_awaddr, sq_araddr;
  wire [31:0] sq_wdata, sq_rdata;
  wire [3:0]  sq_wstrb;
  wire        sq_awvalid, sq_awready, sq_wvalid, sq_wready, sq_bvalid, sq_bready;
  wire        sq_arvalid, sq_arready, sq_rvalid, sq_rready;
  wire [1:0]  sq_bresp, sq_rresp;

  wire [NG-1:0] seq_link_up;
  wire          seq_bringup_done;

  wire [NG-1:0] gt_all_reset_a;
  dcmac_sync2 #(.WIDTH(NG), .STAGES(2), .INIT('0)) u_sync_gt_all (
    .clk  (aclk),
    .din  (fsm_gt_all_reset),
    .dout (gt_all_reset_a));

  localparam int ESC_RESTART_CYC = 50 * CYC_PER_MS;
  localparam int ERW = $clog2(ESC_RESTART_CYC + 1);

  logic              esc_seen_r;
  logic [ERW-1:0]    esc_cnt_r;
  logic              esc_restart_r;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      esc_seen_r    <= 1'b0;
      esc_cnt_r     <= '0;
      esc_restart_r <= 1'b0;
    end else begin
      esc_restart_r <= 1'b0;
      if (!esc_seen_r) begin
        if (|gt_all_reset_a) begin
          esc_seen_r <= 1'b1;
          esc_cnt_r  <= ERW'(ESC_RESTART_CYC);
        end
      end else if (esc_cnt_r != '0) begin
        esc_cnt_r <= esc_cnt_r - 1'b1;
      end else begin
        esc_restart_r <= 1'b1;
        esc_seen_r    <= 1'b0;
      end
    end
  end

  wire          restart_any = bringup_restart_req | esc_restart_r;

  dcmac_ctl_seq #(
    .PORT_MAX       (PORT_MAX),
    .NPORTS         (NPORTS),
    .ANCHOR         (ANCHOR),
    .N_GROUP        (NG),
    .ANCHOR_1       (ANCHOR_1),
    .BASE           (BASE),
    .CYC_PER_MS     (CYC_PER_MS),
    .EN_STATS       (EN_STATS),
    .EN_RR_POLL     (EN_RR_POLL),
    .POLL_TRIES     (POLL_TRIES),
    .DONE_MASK      (DONE_MASK),
    .RATE_CODE      (RATE_CODE),
    .RATE_FIELD     (RATE_FIELD),
    .LINK_CONFIRM_N (LINK_CONFIRM_N_BRINGUP)
  ) u_seq (
    .aclk                    (aclk),
    .aresetn                 (aresetn),
    .m_axil_awaddr           (sq_awaddr),
    .m_axil_awvalid          (sq_awvalid),
    .m_axil_awready          (sq_awready),
    .m_axil_wdata            (sq_wdata),
    .m_axil_wstrb            (sq_wstrb),
    .m_axil_wvalid           (sq_wvalid),
    .m_axil_wready           (sq_wready),
    .m_axil_bresp            (sq_bresp),
    .m_axil_bvalid           (sq_bvalid),
    .m_axil_bready           (sq_bready),
    .m_axil_araddr           (sq_araddr),
    .m_axil_arvalid          (sq_arvalid),
    .m_axil_arready          (sq_arready),
    .m_axil_rdata            (sq_rdata),
    .m_axil_rresp            (sq_rresp),
    .m_axil_rvalid           (sq_rvalid),
    .m_axil_rready           (sq_rready),
    .gt_tx_reset_done        (gt_tx_reset_done),
    .gt_rx_reset_done        (gt_rx_reset_done),
    .rx_datapath_reset       (rx_datapath_reset),
    .rx_datapath_reset_ports (rx_datapath_reset_ports),
    .core_serdes_reset       (core_serdes_reset),
    .tx_datapath_reset       (tx_datapath_reset),
    .bringup_restart_req     (restart_any),
    .stats_req               (stats_req),
    .rx_force_resync_req     (rx_force_resync_req),
    .rx_datapath_reset_req   (rx_datapath_reset_req),
    .tx_datapath_reset_req   (tx_datapath_reset_req),
    .rx_force_resync         (rx_force_resync),
    .link_up                 (seq_link_up),
    .link_live               (),
    .link_fault              (link_fault),
    .access_fault            (access_fault),
    .seq_busy                (seq_busy),
    .bringup_done            (seq_bringup_done),
    .rx_phy_status           (rx_phy_status),
    .retry_cnt               (retry_cnt),
    .seq_state               (seq_state),
    .seq_pc                  (seq_pc),
    .stat_rd_idx             (stat_rd_idx),
    .stat_rd_data            (stat_rd_data)
  );

  assign bringup_done = seq_bringup_done;

  logic seq_bringup_done_q;
  always_ff @(posedge aclk) begin
    if (!aresetn) seq_bringup_done_q <= 1'b0;
    else          seq_bringup_done_q <= seq_bringup_done;
  end

  wire [N_REQ-1:0]      rq_valid, rq_write, rq_gnt, rq_ack;
  wire [N_REQ*20-1:0]   rq_addr;
  wire [N_REQ*32-1:0]   rq_wdata, rq_mask;
  wire [31:0]           ack_rdata;
  wire                  ack_aligned, ack_err;

  dcmac_axil_arb #(.AW(20)) u_shim (
    .clk            (aclk),
    .rstn           (aresetn),
    .s_axil_awaddr  (sq_awaddr),
    .s_axil_awvalid (sq_awvalid),
    .s_axil_awready (sq_awready),
    .s_axil_wdata   (sq_wdata),
    .s_axil_wstrb   (sq_wstrb),
    .s_axil_wvalid  (sq_wvalid),
    .s_axil_wready  (sq_wready),
    .s_axil_bresp   (sq_bresp),
    .s_axil_bvalid  (sq_bvalid),
    .s_axil_bready  (sq_bready),
    .s_axil_araddr  (sq_araddr),
    .s_axil_arvalid (sq_arvalid),
    .s_axil_arready (sq_arready),
    .s_axil_rdata   (sq_rdata),
    .s_axil_rresp   (sq_rresp),
    .s_axil_rvalid  (sq_rvalid),
    .s_axil_rready  (sq_rready),
    .req_valid      (rq_valid[0]),
    .req_write      (rq_write[0]),
    .req_addr       (rq_addr[0*20 +: 20]),
    .req_wdata      (rq_wdata[0*32 +: 32]),
    .req_gnt        (rq_gnt[0]),
    .req_ack        (rq_ack[0]),
    .ack_rdata      (ack_rdata),
    .ack_err        (ack_err)
  );

  assign rq_mask[0*32 +: 32] = 32'h0;

  wire [NG-1:0] sup_aligned;

  wire [32*NG-1:0]   sup_align_word;
  wire [32*NG-1:0]   sup_align_sticky;
  wire [NG-1:0]      sup_valid;
  wire [NG*4-1:0]    sup_fault;
  wire [NG-1:0]      sup_remote_fault;
  wire [NG-1:0]      sup_reset_req;
  wire [NG-1:0]      sup_reset_ack;
  wire [NG-1:0]      sup_bus_stuck;

  wire [40*NG-1:0]   sup_window_remaining;
  wire [NG-1:0]      sup_window_running;
  wire [NG-1:0]      sup_last_was_fault;
  wire [16*NG-1:0]   sup_bus_err_count;
  wire [NG*16-1:0]   sup_sample_count;
  wire [NG-1:0]      sup_ever_aligned;

  logic [NG-1:0] sup_seen_r;
  always_ff @(posedge aclk) begin
    if (!aresetn) sup_seen_r <= '0;
    else begin
      for (int g = 0; g < NG; g++) begin
        if (!seq_bringup_done)      sup_seen_r[g] <= 1'b0;
        else if (rq_ack[1 + g])     sup_seen_r[g] <= 1'b1;
      end
    end
  end

  function automatic int anch_of(input int g);
    return (g == 0) ? ANCHOR : ANCHOR_1;
  endfunction

  generate
    for (genvar g = 0; g < NG; g++) begin : g_sup

      localparam logic [19:0] POLL_ADDR =
          BASE + O_RX_PHY_STATUS + (20'(anch_of(g) + 1) << PORT_SHIFT);

      assign rq_wdata[(1+g)*32 +: 32]   = 32'h0;

      localparam logic [19:0] RT_ALIGN_ADDR =
          BASE + O_RX_PHY_RT_STATUS + (20'(anch_of(g) + 1) << PORT_SHIFT);
      localparam logic [19:0] RT_FAULT_ADDR =
          BASE + O_RX_MAC_RT_STATUS + (20'(anch_of(g) + 1) << PORT_SHIFT);

      dcmac_link_sample #(

        .CYC_PER_US      (((CYC_PER_MS / 1000) < 1) ? 1 : (CYC_PER_MS / 1000)),
        .CYC_PER_MS      (CYC_PER_MS),
        .T_SAMPLE_MS     (T_SAMPLE_MS),

        .T_ERR_MS        (T_ERR_MS),
        .LINK_WDT_MS     (LINK_WDT_MS),
        .LINK_WDT_MS_MIN (LINK_WDT_MS_MIN),
        .LINK_WDT_MS_MAX (LINK_WDT_MS_MAX),
        .N_BUS_ERR       (N_BUS_ERR),
        .AW              (20),

        .A_ALIGN_ADDR    (int'(RT_ALIGN_ADDR)),
        .A_FAULT_ADDR    (int'(RT_FAULT_ADDR)),
        .ALIGN_MASK      (ALIGN_MASK)
      ) u_sample (
        .clk             (aclk),
        .rstn            (aresetn),
        .enable          (seq_bringup_done_q),
        .wdt_ms          (link_wdt_ms[g*16 +: 16]),
        .req_valid       (rq_valid[1 + g]),
        .req_write       (rq_write[1 + g]),
        .req_addr        (rq_addr [(1+g)*20 +: 20]),
        .req_mask        (rq_mask [(1+g)*32 +: 32]),
        .req_gnt         (rq_gnt  [1 + g]),
        .req_ack         (rq_ack  [1 + g]),
        .ack_rdata       (ack_rdata),
        .ack_aligned     (ack_aligned),
        .ack_err         (ack_err),
        .aligned         (sup_aligned[g]),
        .valid           (sup_valid[g]),
        .align_word      (sup_align_word[g*32 +: 32]),
        .align_sticky    (sup_align_sticky[g*32 +: 32]),
        .fault           (sup_fault[g*4 +: 4]),
        .remote_fault    (sup_remote_fault[g]),
        .recv_local_fault(),
        .reset_req       (sup_reset_req[g]),
        .reset_ack       (sup_reset_ack[g]),
        .bus_stuck       (sup_bus_stuck[g]),
        .sample_count    (sup_sample_count[g*16 +: 16]),
        .esc_count       (sup_esc_count[g*16 +: 16]),
        .bus_err_count   (sup_bus_err_count[g*16 +: 16]),
        .ever_aligned    (sup_ever_aligned[g]),
        .window_running  (sup_window_running[g]),
        .last_was_fault  (sup_last_was_fault[g]),
        .window_remaining(sup_window_remaining[g*40 +: 40])
      );

      assign rx_pcs_aligned[g] = sup_aligned[g];
    end
  endgenerate

  localparam int N_EXEC_RST   = 4;
  localparam int EXEC_RST_CYC = 16;

  logic [15:0] exec_rst_cnt_r;
  logic [4:0]  exec_rst_hold_r;
  logic        bus_stuck_d;
  wire         bus_stuck_any = |sup_bus_stuck;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      exec_rst_cnt_r  <= '0;
      exec_rst_hold_r <= '0;
      bus_stuck_d     <= 1'b0;
    end else begin
      bus_stuck_d <= bus_stuck_any;
      if (exec_rst_hold_r != '0) begin
        exec_rst_hold_r <= exec_rst_hold_r - 5'd1;
      end else if (bus_stuck_any && !bus_stuck_d && seq_bringup_done
                   && (exec_rst_cnt_r < 16'(N_EXEC_RST))) begin

        exec_rst_hold_r <= 5'(EXEC_RST_CYC);
        exec_rst_cnt_r  <= exec_rst_cnt_r + 16'd1;
      end
    end
  end

  wire exec_rstn = aresetn && (exec_rst_hold_r == '0);

  dcmac_axil_exec #(
    .N_REQ    (N_REQ),
    .AW       (20),
    .RR_START (1),
    .TMO_CYC  (4096),
    .BAD_MAGIC(AXI_BAD_MAGIC)
  ) u_exec (
    .clk            (aclk),
    .rstn           (exec_rstn),
    .req_valid      (rq_valid),
    .req_write      (rq_write),
    .req_addr       (rq_addr),
    .req_wdata      (rq_wdata),
    .req_mask       (rq_mask),
    .req_gnt        (rq_gnt),
    .req_ack        (rq_ack),
    .ack_rdata      (ack_rdata),
    .ack_aligned    (ack_aligned),
    .ack_err        (ack_err),
    .m_axil_awaddr  (m_axil_awaddr),
    .m_axil_awvalid (m_axil_awvalid),
    .m_axil_awready (m_axil_awready),
    .m_axil_wdata   (m_axil_wdata),
    .m_axil_wstrb   (m_axil_wstrb),
    .m_axil_wvalid  (m_axil_wvalid),
    .m_axil_wready  (m_axil_wready),
    .m_axil_bresp   (m_axil_bresp),
    .m_axil_bvalid  (m_axil_bvalid),
    .m_axil_bready  (m_axil_bready),
    .m_axil_araddr  (m_axil_araddr),
    .m_axil_arvalid (m_axil_arvalid),
    .m_axil_arready (m_axil_arready),
    .m_axil_rdata   (m_axil_rdata),
    .m_axil_rresp   (m_axil_rresp),
    .m_axil_rvalid  (m_axil_rvalid),
    .m_axil_rready  (m_axil_rready),
    .busy           (),
    .cur_req        (),
    .tmo_count      (exec_tmo_count)
  );

  // synthesis translate_off
  initial begin
    if (N_GROUP < 1 || N_GROUP > 4)
      $fatal(1, "dcmac_link_ctl: N_GROUP=%0d outside 1..4", N_GROUP);

    $display("NIA_LINK_CTL NG=%0d N_REQ=%0d LINK_WDT_MS=%0d MIN=%0d MAX=%0d LINK_CONFIRM_N=%0d T_SAMPLE_MS=%0d N_BUS_ERR=%0d",
             N_GROUP, N_REQ, LINK_WDT_MS, LINK_WDT_MS_MIN, LINK_WDT_MS_MAX,
             LINK_CONFIRM_N, T_SAMPLE_MS, N_BUS_ERR);
  end
  // synthesis translate_on

  wire [NG-1:0] fsm_reset_ack_seg;

  generate
    for (genvar g = 0; g < NG; g = g + 1) begin : g_fsm
      localparam int FSM_ANCHOR = (g == 0) ? ANCHOR : ANCHOR_1;

      wire       aligned_a = (ALIGN_EXPORT_MODE != 0) ? sup_aligned[g] : seq_link_up[g];
      wire [3:0] fsm_in_a  = { rx_force_resync_req | rx_force_resync | host_rx_force_resync_req[g],
                               sup_reset_req[g] | host_link_reset_req[g],
                               seq_bringup_done,
                               aligned_a };
      wire [3:0] fsm_in_s;

      dcmac_sync2 #(.WIDTH(4), .STAGES(2), .INIT(4'h0)) u_fsm_in_sync (
        .clk  (seg_clk),
        .din  (fsm_in_a),
        .dout (fsm_in_s)
      );

      wire remote_fault_s;
      dcmac_sync2 #(.WIDTH(1), .STAGES(2), .INIT(1'b0)) u_fsm_fault_sync (
        .clk  (seg_clk),
        .din  (sup_remote_fault[g]),
        .dout (remote_fault_s)
      );

      dcmac_mac_ctl_fsm #(
        .CYC_PER_MS     (SEG_CYC_PER_MS),
        .T_RXDP_MS      (T_RXDP_MS),
        .T_SERDES_MS    (T_SERDES_MS),
        .PORT_MAX       (PORT_MAX),
        .NPORTS         (NPORTS),
        .ANCHOR         (FSM_ANCHOR),
        .LINK_CONFIRM_N (LINK_CONFIRM_N)
      ) u_fsm (
        .seg_clk                 (seg_clk),
        .seg_rstn                (seg_rstn[g]),
        .configured              (fsm_in_s[1]),
        .stat_rx_aligned         (fsm_in_s[0]),
        .stat_remote_fault       (remote_fault_s),
        .reset_req               (fsm_in_s[2]),
        .reset_ack               (fsm_reset_ack_seg[g]),
        .rx_force_resync_req     (fsm_in_s[3]),
        .ctl_rx_enable           (ctl_rx_enable[g]),
        .ctl_rx_force_resync     (ctl_rx_force_resync[g]),
        .ctl_tx_enable           (ctl_tx_enable[g]),
        .ctl_tx_send_idle        (ctl_tx_send_idle[g]),
        .ctl_tx_send_lfi         (ctl_tx_send_lfi[g]),
        .ctl_tx_send_rfi         (ctl_tx_send_rfi[g]),
        .rx_datapath_reset       (fsm_rx_datapath_reset[g]),
        .rx_pll_datapath_reset   (fsm_rx_pll_datapath_reset[g]),
        .gt_all_reset_req        (fsm_gt_all_reset[g]),
        .rx_serdes_reset_req     (fsm_rx_serdes_reset[g]),
        .rx_flush_req            (fsm_rx_flush[g]),
        .gt_rx_done              (fsm_gt_rx_done[g]),
        .rx_datapath_reset_ports (fsm_rx_datapath_reset_ports[g*PORT_MAX +: PORT_MAX]),
        .repair_count            (fsm_repair_count[g*8 +: 8]),
        .repair_tmo_count        (fsm_repair_tmo_count[g*8 +: 8]),
        .tx_rst_seg              (tx_rst_seg[g]),
        .link_up                 (link_up[g]),
        .carrier                 (carrier[g]),
        .fsm_state               (mac_fsm_state[g*3 +: 3])
      );
    end
  endgenerate

  assign link_reset_req    = sup_reset_req;
  assign link_remote_fault = sup_remote_fault;
  assign link_bus_stuck    = sup_bus_stuck;
  assign link_ever_aligned = sup_ever_aligned;
  assign link_fault_nibble = sup_fault;
  assign link_sample_count = sup_sample_count;
  assign link_align_word   = sup_align_word;
  assign link_align_sticky = sup_align_sticky;

  wire [NG-1:0] link_reset_ack_s;
  dcmac_sync2 #(.WIDTH(NG), .STAGES(2), .INIT('0)) u_ack_sync (
    .clk  (aclk),
    .din  (fsm_reset_ack_seg),
    .dout (link_reset_ack_s)
  );
  assign sup_reset_ack     = link_reset_ack_s;
  assign link_valid            = sup_valid;
  assign link_window_running   = sup_window_running;
  assign link_last_was_fault   = sup_last_was_fault;
  assign link_bus_err_count    = sup_bus_err_count;
  assign link_window_remaining = sup_window_remaining;

endmodule

`default_nettype wire
