// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ns/1ps

module dcmac_ctl_seq
  import dcmac_ctl_pkg::*;
#(

  parameter int          PORT_MAX    = 6,
  parameter int          NPORTS      = 1,
  parameter int          ANCHOR      = 0,

  parameter int          N_GROUP     = 1,
  parameter int          ANCHOR_1    = 1,

  parameter int          RATE_CODE   = RATE_CODE_100G,
  parameter int          RATE_FIELD  = RATE_FIELD_100G,
  parameter logic [7:0]  DONE_MASK   = DONEMASK_100G,
  parameter logic [19:0] BASE        = 20'h0,

  parameter int RX_CYCLES  = (NPORTS > 1) ? 6 : 3,
  parameter int POLL_TRIES = 60,

  parameter int CYC_PER_MS        = 250_000,
  parameter int T_RXDP_MS         = 100,
  parameter int T_SERDES_MS       = 100,
  parameter int T_CHAN_ASSERT_MS  = 5,
  parameter int T_STEP2_MS        = 10,
  parameter int T_PORTCFG_MS      = 2,
  parameter int T_PORT_CHAN_GAP_MS= 50,
  parameter int T_REALIGN_MS      = 200,
  parameter int T_ALIGN_MS        = 200,
  parameter int AXI_TIMEOUT_CYC   = 4096,
  parameter int DONE_TIMEOUT_MS   = 4000,
  parameter bit EN_STATS          = 1'b1,

  parameter bit EN_RR_POLL        = 1'b1,

  parameter int LINK_CONFIRM_N    = 2
)(
  input  logic        aclk,
  input  logic        aresetn,

  output logic [19:0] m_axil_awaddr,
  output logic        m_axil_awvalid,
  input  logic        m_axil_awready,
  output logic [31:0] m_axil_wdata,
  output logic [3:0]  m_axil_wstrb,
  output logic        m_axil_wvalid,
  input  logic        m_axil_wready,
  input  logic [1:0]  m_axil_bresp,
  input  logic        m_axil_bvalid,
  output logic        m_axil_bready,
  output logic [19:0] m_axil_araddr,
  output logic        m_axil_arvalid,
  input  logic        m_axil_arready,
  input  logic [31:0] m_axil_rdata,
  input  logic [1:0]  m_axil_rresp,
  input  logic        m_axil_rvalid,
  output logic        m_axil_rready,

  input  logic [7:0]           gt_tx_reset_done,
  input  logic [7:0]           gt_rx_reset_done,
  output logic                 rx_datapath_reset,
  output logic [PORT_MAX-1:0]  rx_datapath_reset_ports,
  output logic                 core_serdes_reset,

  output logic                 tx_datapath_reset,

  input  logic        bringup_restart_req,
  input  logic        stats_req,
  input  logic        rx_force_resync_req,
  input  logic        rx_datapath_reset_req,
  input  logic        tx_datapath_reset_req,
  output logic        rx_force_resync,

  output logic [N_GROUP-1:0] link_up,

  output logic [N_GROUP-1:0] link_live,

  output logic        link_fault,
  output logic        access_fault,
  output logic        seq_busy,

  output logic        bringup_done,
  output logic [31:0] rx_phy_status,
  output logic [7:0]  retry_cnt,
  output logic [4:0]  seq_state,
  output logic [15:0] seq_pc,

  input  logic [7:0]  stat_rd_idx,
  output logic [31:0] stat_rd_data
);

  localparam logic [4:0] OP_NOP   = 5'd0;
  localparam logic [4:0] OP_WR    = 5'd1;
  localparam logic [4:0] OP_RD    = 5'd2;
  localparam logic [4:0] OP_WAIT  = 5'd3;
  localparam logic [4:0] OP_PIN   = 5'd4;
  localparam logic [4:0] OP_WDONE = 5'd5;

  localparam logic [4:0] OP_JMP   = 5'd11;
  localparam logic [4:0] OP_DONE  = 5'd12;

  localparam int NP        = NPORTS;
  localparam int NG        = N_GROUP;
  localparam int UPN       = (NG > 1) ? 1 : 0;

  localparam int RRN       = (EN_RR_POLL && NG > 1) ? 1 : 0;

  localparam int STATS_PER = 22;
  localparam int N_STAT    = EN_STATS ? (STATS_PER*NP*NG) : 0;

  function automatic int anch(input int g);
    return (g == 0) ? ANCHOR : ANCHOR_1;
  endfunction
  function automatic bit is_anch(input int p);
    return (p == ANCHOR) || ((NG > 1) && (p == ANCHOR_1));
  endfunction

  localparam int P_B3     = 0;
  localparam int P_B4     = P_B3     + 1;
  localparam int P_B5G    = P_B4     + 5;
  localparam int P_B5P    = P_B5G    + 2;
  localparam int P_B5C    = P_B5P    + 12;
  localparam int P_B5W    = P_B5C    + 5*NP*NG;
  localparam int P_B6     = P_B5W    + 1;
  localparam int P_B7A    = P_B6     + 1;
  localparam int P_B7B    = P_B7A    + 12;
  localparam int P_B8     = P_B7B    + 12;
  localparam int P_B9G    = P_B8     + 12;
  localparam int P_B9P    = P_B9G    + 2;
  localparam int P_B9C    = P_B9P    + 12;
  localparam int P_B10    = P_B9C    + 2*NP*NG;
  localparam int P_B11    = P_B10    + 1;

  localparam int P_B17    = P_B11    + 2*NP*NG;
  localparam int P_STATS  = P_B17    + 2*NP*NG;
  localparam int P_DONE   = P_STATS  + N_STAT;

  localparam int ROM_N    = P_DONE   + 1;

  localparam int PCW = (ROM_N > 1) ? $clog2(ROM_N) : 1;

  localparam int REC_W = 5 + 20 + 32 + 32;

  function automatic logic [19:0] pp(input int p, input logic [19:0] off);
    logic [19:0] a;
    a = BASE + off + (20'(p + 1) << PORT_SHIFT);
    return a;
  endfunction

  function automatic logic [19:0] gg(input logic [19:0] off);
    return BASE + off;
  endfunction

  function automatic logic [REC_W-1:0] rom_rec(input int pc);
    logic [4:0]  op;
    logic [19:0] a;
    logic [31:0] d;
    logic [31:0] w;
    int i, p, k, r, f, g, rem, lo;
    logic [19:0] soff;
    begin
      op = OP_NOP; a = '0; d = '0; w = '0;

      if (pc == P_B3) begin op = OP_WDONE; d = 32'd0; w = (32'(DONE_TIMEOUT_MS) * 32'(CYC_PER_MS)); end

      else if (pc >= P_B4 && pc < P_B4 + 5) begin
        case (pc - P_B4)
          0: begin op = OP_PIN;   d = 32'h1; end
          1: begin op = OP_WAIT;  w = (32'(T_RXDP_MS) * 32'(CYC_PER_MS)); end
          2: begin op = OP_PIN;   d = 32'h0; end
          3: begin op = OP_WAIT;  w = (32'(T_SERDES_MS) * 32'(CYC_PER_MS)); end
          4: begin op = OP_WDONE; d = 32'd1; w = (32'(DONE_TIMEOUT_MS) * 32'(CYC_PER_MS)); end
        endcase
      end

      else if (pc == P_B5G + 0) begin op = OP_WR; a = gg(O_PCTL_RX); d = 32'h7; end
      else if (pc == P_B5G + 1) begin op = OP_WR; a = gg(O_PCTL_TX); d = 32'h7; end
      else if (pc >= P_B5P && pc < P_B5P + 12) begin
        p  = (pc - P_B5P) / 2;
        op = OP_WR; d = 32'h3;
        a  = ((pc - P_B5P) % 2 == 0) ? pp(p, O_PCTL_RX) : pp(p, O_PCTL_TX);
      end
      else if (pc >= P_B5C && pc < P_B5C + 5*NP*NG) begin

        g   = (pc - P_B5C) / (5*NP);
        rem = (pc - P_B5C) % (5*NP);
        p   = anch(g) + rem / 5;
        case (rem % 5)
          0: begin op = OP_WR;   a = pp(p, O_CHCTL_RX); d = 32'h1; end
          1: begin op = OP_WR;   a = pp(p, O_CHCTL_TX); d = 32'h1; end
          2: begin op = OP_WAIT; w = (32'(T_CHAN_ASSERT_MS) * 32'(CYC_PER_MS)); end
          3: begin op = OP_WR;   a = pp(p, O_PCTL_RX);  d = 32'h3; end
          4: begin op = OP_WR;   a = pp(p, O_PCTL_TX);  d = 32'h3; end
        endcase
      end

      else if (pc == P_B5W) begin op = OP_WAIT; w = (32'(T_STEP2_MS) * 32'(CYC_PER_MS)); end

      else if (pc == P_B6) begin op = OP_WR; a = gg(O_GLOBAL_MODE); d = W_GLOBAL_MODE; end

      else if (pc >= P_B7A && pc < P_B7A + 12) begin
        i = (pc - P_B7A) / 2;
        if ((pc - P_B7A) % 2 == 0) begin
          op = OP_WR; a = pp(i, O_GLOBAL_MODE); d = W_PORT_MODE;
        end else begin
          op = OP_WAIT; w = (32'(T_PORTCFG_MS) * 32'(CYC_PER_MS));
        end
      end
      else if (pc >= P_B7B && pc < P_B7B + 12) begin
        i = (pc - P_B7B) / 2;
        if ((pc - P_B7B) % 2 == 0) begin
          op = OP_WR; a = pp(i, O_CONFIG_REV); d = W_PORT_REV;
        end else begin
          op = OP_WAIT; w = (32'(T_PORTCFG_MS) * 32'(CYC_PER_MS));
        end
      end

      else if (pc >= P_B8 && pc < P_B8 + 12) begin
        p = (pc - P_B8) / 2;
        r = is_anch(p) ? RATE_CODE  : 0;
        f = is_anch(p) ? RATE_FIELD : RATE_FIELD_NONANCHOR;
        op = OP_WR;
        if ((pc - P_B8) % 2 == 0) begin a = pp(p, O_TX_MODE); d = tx_mode_word(r, f); end
        else                      begin a = pp(p, O_RX_MODE); d = rx_mode_word(r, f); end
      end

      else if (pc == P_B9G + 0) begin op = OP_WR; a = gg(O_PCTL_TX); d = 32'h0; end
      else if (pc == P_B9G + 1) begin op = OP_WR; a = gg(O_PCTL_RX); d = 32'h0; end
      else if (pc >= P_B9P && pc < P_B9P + 12) begin
        p  = (pc - P_B9P) / 2;
        op = OP_WR; d = 32'h0;
        a  = ((pc - P_B9P) % 2 == 0) ? pp(p, O_PCTL_TX) : pp(p, O_PCTL_RX);
      end
      else if (pc >= P_B9C && pc < P_B9C + 2*NP*NG) begin
        g   = (pc - P_B9C) / (2*NP);
        rem = (pc - P_B9C) % (2*NP);
        p   = anch(g) + rem / 2;
        op = OP_WR; d = 32'h0;
        a  = (rem % 2 == 0) ? pp(p, O_PCTL_RX) : pp(p, O_PCTL_TX);
      end

      else if (pc == P_B10) begin op = OP_WAIT; w = (32'(T_PORT_CHAN_GAP_MS) * 32'(CYC_PER_MS)); end

      else if (pc >= P_B11 && pc < P_B11 + 2*NP*NG) begin
        g   = (pc - P_B11) / (2*NP);
        rem = (pc - P_B11) % (2*NP);
        p   = anch(g) + rem / 2;
        op = OP_WR; d = 32'h0;
        a  = (rem % 2 == 0) ? pp(p, O_CHCTL_TX) : pp(p, O_CHCTL_RX);
      end

      else if (EN_STATS && pc >= P_STATS && pc < P_STATS + N_STAT) begin
        g   = (pc - P_STATS) / (STATS_PER*NP);
        rem = (pc - P_STATS) % (STATS_PER*NP);
        p   = anch(g) + rem / STATS_PER;
        k   = rem % STATS_PER;
        case (k)
          0:  soff = O_RX_PHY_RT_STATUS;
          1:  soff = O_RX_PHY_STATUS;
          2:  soff = O_RX_MAC_RT_STATUS;
          3:  soff = O_RX_MODE;
          4:  soff = O_TX_MODE;
          5:  soff = O_PCTL_RX;
          6:  soff = O_PCTL_TX;
          7:  soff = O_CHCTL_RX;
          8:  soff = O_CHCTL_TX;
          9:  soff = O_GLOBAL_MODE;
          10: soff = O_CONFIG_REV;
          11: soff = O_FEC_CW;
          12: soff = O_FEC_CORR;
          13: soff = O_FEC_UNCORR;
          14: soff = O_TICK_RX;
          15: soff = O_TICK_TX;
          16: soff = O_SRX_PKTS;
          17: soff = O_SRX_GPKTS;
          18: soff = O_STX_PKTS;
          19: soff = O_STX_GPKTS;
          20: soff = O_SRX_BYTES;
          21: soff = O_STX_BYTES;
          default: soff = O_RX_PHY_RT_STATUS;
        endcase
        op = OP_RD;
        a  = (k == 9 || k == 10) ? gg(soff) : pp(p, soff);
      end

      else if (pc == P_DONE)   begin op = OP_DONE;  end

      return {op, a, d, w};
    end
  endfunction

  localparam int ROM_DEPTH = 1 << PCW;

  localparam int REC_STRIDE = 1 << $clog2(REC_W);
  localparam int ROM_BITS  = ROM_DEPTH * REC_STRIDE;

  function automatic logic [ROM_BITS-1:0] rom_flat();
    logic [ROM_BITS-1:0] t;

    for (int q = 0; q < ROM_DEPTH; q++) t[q*REC_STRIDE +: REC_W] = rom_rec(q);
    return t;
  endfunction

  localparam logic [ROM_BITS-1:0] ROM_FLAT = rom_flat();

  localparam logic [4:0] S_IDLE      = 5'd0;
  localparam logic [4:0] S_FETCH     = 5'd1;
  localparam logic [4:0] S_WR_ADDR   = 5'd2;
  localparam logic [4:0] S_WR_RESP   = 5'd3;
  localparam logic [4:0] S_RD_ADDR   = 5'd4;
  localparam logic [4:0] S_RD_DATA   = 5'd5;
  localparam logic [4:0] S_WAIT      = 5'd6;
  localparam logic [4:0] S_WDONE     = 5'd7;

  localparam logic [4:0] S_HALT      = 5'd12;

  localparam logic [4:0] S_ADV       = 5'd13;
  localparam logic [4:0] S_FETCH0    = 5'd14;

  logic [4:0]        state, ret_state;
  logic [PCW-1:0]    pc;
  logic [REC_W-1:0]  rec_comb, rec;
  logic [4:0]        op;
  logic [19:0]       rec_addr;
  logic [31:0]       rec_data;
  logic [31:0]       rec_cyc;

  assign rec_comb = ROM_FLAT[int'(pc)*REC_STRIDE +: REC_W];
  assign op       = rec[REC_W-1 -: 5];
  assign rec_addr = rec[64 +: 20];
  assign rec_data = rec[32 +: 32];
  assign rec_cyc  = rec[0  +: 32];

  logic [31:0] dly_cnt;
  logic [15:0] to_cnt;

  logic [NG-1:0] link_up_r;
  logic        link_fault_r, access_fault_r;
  logic        pin_rx_dp, pin_serdes;
  logic [31:0] rx_phy_status_r;
  logic [31:0] rdata_r;
  logic        aw_done, w_done;

  logic restart_q, stats_q_req;
  logic bringup_restart_d, stats_req_d;

  logic [31:0] stat_q [0:(N_STAT > 0 ? N_STAT-1 : 0)];

  function automatic int pc_group(input int p);
    /* verilator lint_off UNUSED */
    int unused_p; unused_p = p;
    /* verilator lint_on UNUSED */
    return 0;
  endfunction

  localparam int GRPW = $clog2(NG+1);
  localparam int GRP_STRIDE = 1 << $clog2(GRPW);

  function automatic logic [ROM_DEPTH*GRP_STRIDE-1:0] grp_flat();
    logic [ROM_DEPTH*GRP_STRIDE-1:0] t;
    for (int q = 0; q < ROM_DEPTH; q++) t[q*GRP_STRIDE +: GRPW] = GRPW'(pc_group(q));
    return t;
  endfunction

  localparam logic [ROM_DEPTH*GRP_STRIDE-1:0] GRP_FLAT = grp_flat();

  wire in_b4 = (int'(pc) >= P_B4) && (int'(pc) < P_B4 + 5);

  wire [GRPW-1:0] cur_grp = GRP_FLAT[int'(pc)*GRP_STRIDE +: GRPW];

  logic [PORT_MAX-1:0] port_group_mask;
  always_comb begin
    port_group_mask = '0;
    for (int gg = 0; gg < NG; gg++) begin
      if (in_b4 || (int'(cur_grp) == gg)) begin
        for (int gp = 0; gp < PORT_MAX; gp++)
          if (gp >= anch(gg) && gp < (anch(gg) + NPORTS)) port_group_mask[gp] = 1'b1;
      end
    end
  end

  wire done_hit = rec_data[0] ? (gt_rx_reset_done == DONE_MASK)
                              : (gt_tx_reset_done == DONE_MASK);

  wire [15:0] to_limit   = 16'(AXI_TIMEOUT_CYC);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state           <= S_IDLE;
      ret_state       <= S_ADV;
      rec             <= '0;
      pc              <= '0;
      dly_cnt         <= '0;
      to_cnt          <= '0;
      link_up_r       <= '0;
      link_fault_r    <= 1'b0;
      access_fault_r  <= 1'b0;
      pin_rx_dp       <= 1'b0;
      pin_serdes      <= 1'b0;
      rx_phy_status_r <= '0;
      rdata_r         <= '0;
      aw_done         <= 1'b0;
      w_done          <= 1'b0;
      m_axil_awvalid  <= 1'b0;
      m_axil_wvalid   <= 1'b0;
      m_axil_bready   <= 1'b0;
      m_axil_arvalid  <= 1'b0;
      m_axil_rready   <= 1'b0;
      m_axil_awaddr   <= '0;
      m_axil_araddr   <= '0;
      m_axil_wdata    <= '0;
      restart_q       <= 1'b0;
      stats_q_req     <= 1'b0;
      bringup_restart_d <= 1'b0;
      stats_req_d       <= 1'b0;
    end else begin

      bringup_restart_d <= bringup_restart_req;
      stats_req_d       <= stats_req;
      if (bringup_restart_req && !bringup_restart_d) restart_q   <= 1'b1;
      if (stats_req         && !stats_req_d)         stats_q_req <= 1'b1;

      if (restart_q) begin

        restart_q       <= 1'b0;
        stats_q_req     <= 1'b0;
        state           <= S_FETCH0;
        pc              <= '0;
        dly_cnt         <= '0;

        link_up_r       <= '0;
        link_fault_r    <= 1'b0;
        access_fault_r  <= 1'b0;
        pin_rx_dp       <= 1'b0;
        pin_serdes      <= 1'b0;
        rx_phy_status_r <= '0;
        m_axil_awvalid  <= 1'b0;
        m_axil_wvalid   <= 1'b0;
        m_axil_bready   <= 1'b0;
        m_axil_arvalid  <= 1'b0;
        m_axil_rready   <= 1'b0;
      end else begin
        case (state)

          S_IDLE: begin
            state <= S_FETCH0;
          end

          S_FETCH0: begin
            rec   <= rec_comb;
            state <= S_FETCH;
          end

          S_FETCH: begin
            to_cnt <= '0;
            case (op)
              OP_WR: begin
                m_axil_awaddr  <= rec_addr;
                m_axil_wdata   <= rec_data;
                m_axil_awvalid <= 1'b1;
                m_axil_wvalid  <= 1'b1;
                aw_done        <= 1'b0;
                w_done         <= 1'b0;
                ret_state      <= S_ADV;
                state          <= S_WR_ADDR;
              end
              OP_RD: begin
                m_axil_araddr  <= rec_addr;
                m_axil_arvalid <= 1'b1;
                ret_state      <= S_ADV;
                state          <= S_RD_ADDR;
              end
              OP_WAIT: begin
                dly_cnt   <= rec_cyc;
                ret_state <= S_ADV;
                state     <= S_WAIT;
              end
              OP_PIN: begin
                pin_rx_dp  <= rec_data[0];
                pin_serdes <= rec_data[1];
                pc         <= pc + 1'b1;
                state      <= S_FETCH0;
              end
              OP_WDONE: begin
                dly_cnt <= rec_cyc;
                state   <= S_WDONE;
              end

              OP_JMP: begin
                pc    <= PCW'(rec_data);
                state <= S_FETCH0;
              end

              OP_DONE: begin
                state <= S_HALT;
              end

              default: begin pc <= pc + 1'b1; state <= S_FETCH0; end
            endcase
          end

          S_ADV: begin
            pc    <= pc + 1'b1;
            state <= S_FETCH0;
          end

          S_WR_ADDR: begin
            to_cnt <= to_cnt + 1'b1;
            if (m_axil_awvalid && m_axil_awready) begin m_axil_awvalid <= 1'b0; aw_done <= 1'b1; end
            if (m_axil_wvalid  && m_axil_wready ) begin m_axil_wvalid  <= 1'b0; w_done  <= 1'b1; end
            if ((aw_done || (m_axil_awvalid && m_axil_awready)) &&
                (w_done  || (m_axil_wvalid  && m_axil_wready ))) begin
              m_axil_bready <= 1'b1;
              state         <= S_WR_RESP;
            end else if (to_cnt >= to_limit) begin
              access_fault_r <= 1'b1;
              m_axil_awvalid <= 1'b0;
              m_axil_wvalid  <= 1'b0;
              state          <= ret_state;
            end
          end
          S_WR_RESP: begin
            to_cnt <= to_cnt + 1'b1;
            if (m_axil_bvalid) begin
              if (m_axil_bresp != 2'b00) access_fault_r <= 1'b1;
              m_axil_bready <= 1'b0;
              state         <= ret_state;
            end else if (to_cnt >= to_limit) begin
              access_fault_r <= 1'b1;
              m_axil_bready  <= 1'b0;
              state          <= ret_state;
            end
          end

          S_RD_ADDR: begin
            to_cnt <= to_cnt + 1'b1;
            if (m_axil_arvalid && m_axil_arready) begin
              m_axil_arvalid <= 1'b0;
              m_axil_rready  <= 1'b1;
              state          <= S_RD_DATA;
            end else if (to_cnt >= to_limit) begin
              access_fault_r <= 1'b1;
              m_axil_arvalid <= 1'b0;
              state          <= ret_state;
            end
          end
          S_RD_DATA: begin
            to_cnt <= to_cnt + 1'b1;
            if (m_axil_rvalid) begin
              rdata_r       <= m_axil_rdata;
              if (m_axil_rresp != 2'b00 || m_axil_rdata == AXI_BAD_MAGIC)
                access_fault_r <= 1'b1;
              m_axil_rready <= 1'b0;
              state         <= ret_state;
            end else if (to_cnt >= to_limit) begin
              access_fault_r <= 1'b1;
              m_axil_rready  <= 1'b0;
              state          <= ret_state;
            end
          end

          S_WAIT: begin
            if (dly_cnt == 0) state <= ret_state;
            else dly_cnt <= dly_cnt - 1'b1;
          end

          S_WDONE: begin
            if (done_hit) begin pc <= pc + 1'b1; state <= S_FETCH0; end
            else if (dly_cnt == 0) begin
              access_fault_r <= 1'b1;
              pc             <= pc + 1'b1;
              state          <= S_FETCH0;
            end else dly_cnt <= dly_cnt - 1'b1;
          end

          S_HALT: begin
            if (stats_q_req && EN_STATS) begin
              stats_q_req <= 1'b0;
              pc          <= PCW'(P_B17);
              state       <= S_FETCH0;
            end
          end
          default: state <= S_IDLE;
        endcase
      end
    end
  end

  generate
    if (N_STAT > 0) begin : g_stat
      always_ff @(posedge aclk) begin
        if (state == S_RD_DATA && m_axil_rvalid && m_axil_rready &&
            int'(pc) >= P_STATS && int'(pc) < P_STATS + N_STAT)
          stat_q[int'(pc) - P_STATS] <= m_axil_rdata;
      end
      assign stat_rd_data = (int'(stat_rd_idx) < N_STAT) ? stat_q[int'(stat_rd_idx)] : 32'h0;
    end else begin : g_nostat
      assign stat_rd_data = 32'h0;
    end
  endgenerate

  assign m_axil_wstrb = 4'hF;

  assign rx_datapath_reset       = pin_rx_dp | rx_datapath_reset_req;
  assign rx_datapath_reset_ports = rx_datapath_reset ? port_group_mask : '0;
  assign core_serdes_reset       = ~aresetn | pin_serdes;

  assign tx_datapath_reset       = tx_datapath_reset_req;

  assign rx_force_resync = rx_force_resync_req;
  assign link_up         = link_up_r;

  assign link_live       = link_up_r;
  assign link_fault      = link_fault_r;
  assign access_fault    = access_fault_r;

  assign seq_busy        = (state != S_HALT) && (state != S_IDLE);

  assign bringup_done    = (state == S_HALT);
  assign rx_phy_status   = rx_phy_status_r;

  assign retry_cnt       = 8'd0;
  assign seq_state       = state;
  assign seq_pc          = 16'(pc);

  // synthesis translate_off
  initial begin
    if (!cursor_legal(TX_MAIN_DEFAULT, TX_PRE_DEFAULT, TX_POST_DEFAULT))
      $fatal(1, "dcmac_ctl_seq: C2 violated - default cursor set is not AM017-legal");
    if (RX_CYCLES < 1 || RX_CYCLES > 10)
      $fatal(1, "dcmac_ctl_seq: B15 violated - RX_CYCLES=%0d outside 1..10", RX_CYCLES);
    if (ANCHOR + NPORTS > PORT_MAX)
      $fatal(1, "dcmac_ctl_seq: port group ANCHOR+NPORTS exceeds PORT_MAX");
    if (T_PORT_CHAN_GAP_MS < 50)
      $fatal(1, "dcmac_ctl_seq: B10 violated - the port->channel gap must be >= 50 ms");

    if (N_GROUP < 1 || N_GROUP > 4)
      $fatal(1, "dcmac_ctl_seq: violated - N_GROUP=%0d outside 1..4 (OP_UP carries the group in data[1:0])", N_GROUP);
    if (N_GROUP > 1) begin
      if (ANCHOR_1 + NPORTS > PORT_MAX)
        $fatal(1, "dcmac_ctl_seq: violated - group 1 (ANCHOR_1=%0d + NPORTS=%0d) exceeds PORT_MAX=%0d",
               ANCHOR_1, NPORTS, PORT_MAX);

      if (!((ANCHOR_1 >= ANCHOR + NPORTS) || (ANCHOR >= ANCHOR_1 + NPORTS)))
        $fatal(1, "dcmac_ctl_seq: violated - port groups overlap (ANCHOR=%0d ANCHOR_1=%0d NPORTS=%0d)",
               ANCHOR, ANCHOR_1, NPORTS);
    end

    if (ROM_N != P_DONE + 1)
      $fatal(1, "dcmac_ctl_seq: violated - ROM_N=%0d != P_DONE+1=%0d; a record survived the truncation",
             ROM_N, P_DONE + 1);

    if (P_B17 != P_B11 + 2*NP*NG)
      $fatal(1, "dcmac_ctl_seq: violated - P_B17=%0d != P_B11+2*NP*NG=%0d; the removal was not a truncation",
             P_B17, P_B11 + 2*NP*NG);

    if (LINK_CONFIRM_N < 1)
      $fatal(1, "dcmac_ctl_seq: violated - LINK_CONFIRM_N=%0d; a confirm count of 0 would make link_up unreachable", LINK_CONFIRM_N);

    if (LINK_CONFIRM_N > 64)
      $fatal(1, "dcmac_ctl_seq: violated - LINK_CONFIRM_N=%0d is an absurd bring-up confirm count", LINK_CONFIRM_N);

    if (LINK_CONFIRM_N > 1 && N_GROUP > 1 && RRN == 0)
      $display("NIA_WARN dcmac_ctl_seq: at N_GROUP=%0d with EN_RR_POLL=0 there is no OP_BRNU, so OP_DONE sets every link_up bit unconditionally and the RISE is NOT confirmed. That combination is a control variant.", N_GROUP);

    $display("NIA_ROM_LAYOUT NG=%0d NP=%0d UPN=%0d REC_W=%0d PCW=%0d P_B11=%0d P_B17=%0d P_STATS=%0d P_DONE=%0d ROM_N=%0d",
             NG, NP, UPN, REC_W, PCW, P_B11, P_B17, P_STATS, P_DONE, ROM_N);

    $display("NIA_LINK_CFG LINK_CONFIRM_N=%0d EN_STATS=%0d STATS_PER=%0d N_STAT=%0d",
             LINK_CONFIRM_N, EN_STATS, STATS_PER, N_STAT);
  end
  // synthesis translate_on

endmodule

`default_nettype wire
