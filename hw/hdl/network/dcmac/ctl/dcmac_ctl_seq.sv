// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module dcmac_ctl_seq
  import dcmac_ctl_pkg::*;
#(
  parameter int          PORT_MAX    = 6,
  parameter int          NPORTS      = 1,
  parameter int          ANCHOR      = 0,
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
  parameter bit EN_STATS          = 1'b1
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

  output logic        link_up,
  output logic        link_fault,
  output logic        access_fault,
  output logic        seq_busy,
  output logic [31:0] rx_phy_status,
  output logic [7:0]  retry_cnt,
  output logic [4:0]  seq_state,
  output logic [15:0] seq_pc,
  input  logic [7:0]  stat_rd_idx,
  output logic [31:0] stat_rd_data
);

  localparam logic [3:0] OP_NOP   = 4'd0;
  localparam logic [3:0] OP_WR    = 4'd1;
  localparam logic [3:0] OP_RD    = 4'd2;
  localparam logic [3:0] OP_WAIT  = 4'd3;
  localparam logic [3:0] OP_PIN   = 4'd4;
  localparam logic [3:0] OP_WDONE = 4'd5;
  localparam logic [3:0] OP_POLL  = 4'd6;
  localparam logic [3:0] OP_BR    = 4'd7;
  localparam logic [3:0] OP_BRZ   = 4'd8;
  localparam logic [3:0] OP_BRX   = 4'd9;
  localparam logic [3:0] OP_INC   = 4'd10;
  localparam logic [3:0] OP_JMP   = 4'd11;
  localparam logic [3:0] OP_DONE  = 4'd12;
  localparam logic [3:0] OP_FAULT = 4'd13;

  localparam int NP        = NPORTS;
  localparam int STATS_PER = 22;
  localparam int N_STAT    = EN_STATS ? (STATS_PER*NP) : 0;

  localparam int P_B3     = 0;
  localparam int P_B4     = P_B3     + 1;
  localparam int P_B5G    = P_B4     + 5;
  localparam int P_B5P    = P_B5G    + 2;
  localparam int P_B5C    = P_B5P    + 12;
  localparam int P_B5W    = P_B5C    + 5*NP;
  localparam int P_B6     = P_B5W    + 1;
  localparam int P_B7A    = P_B6     + 1;
  localparam int P_B7B    = P_B7A    + 12;
  localparam int P_B8     = P_B7B    + 12;
  localparam int P_B9G    = P_B8     + 12;
  localparam int P_B9P    = P_B9G    + 2;
  localparam int P_B9C    = P_B9P    + 12;
  localparam int P_B10    = P_B9C    + 2*NP;
  localparam int P_B11    = P_B10    + 1;
  localparam int P_POLL   = P_B11    + 2*NP;
  localparam int P_BR     = P_POLL   + 1;
  localparam int P_B17    = P_BR     + 1;
  localparam int P_STATS  = P_B17    + 2*NP;
  localparam int P_DONE   = P_STATS  + N_STAT;
  localparam int P_LADDER = P_DONE   + 1;
  localparam int P_LBZ    = P_LADDER + 1;
  localparam int P_RUNG2  = P_LBZ    + 1;
  localparam int P_GRP    = P_RUNG2  + 5;
  localparam int P_GRPW   = P_GRP    + NP;
  localparam int P_GRPR   = P_GRPW   + 1;
  localparam int P_GRPW2  = P_GRPR   + NP;
  localparam int P_INC    = P_GRPW2  + 1;
  localparam int P_JMP    = P_INC    + 1;
  localparam int P_FAULT  = P_JMP    + 1;
  localparam int ROM_N    = P_FAULT  + 1;

  localparam int REC_W = 4 + 20 + 32 + 32;

  function automatic logic [19:0] pp(input int p, input logic [19:0] off);
    logic [19:0] a;
    a = BASE + off + (20'(p + 1) << PORT_SHIFT);
    return a;
  endfunction

  function automatic logic [19:0] gg(input logic [19:0] off);
    return BASE + off;
  endfunction

  function automatic logic [REC_W-1:0] rom_rec(input int pc);
    logic [3:0]  op;
    logic [19:0] a;
    logic [31:0] d;
    logic [31:0] w;
    int i, p, k, r, f;
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
      else if (pc >= P_B5C && pc < P_B5C + 5*NP) begin
        p = ANCHOR + (pc - P_B5C) / 5;
        case ((pc - P_B5C) % 5)
          0: begin op = OP_WR;   a = pp(p, O_CHCTL_RX); d = 32'h1; end
          1: begin op = OP_WR;   a = pp(p, O_CHCTL_TX); d = 32'h1; end
          2: begin op = OP_WAIT; w = (32'(T_CHAN_ASSERT_MS) * 32'(CYC_PER_MS)); end
          3: begin op = OP_WR;   a = pp(p, O_PCTL_RX);  d = 32'h3; end
          4: begin op = OP_WR;   a = pp(p, O_PCTL_TX);  d = 32'h3; end
        endcase
      end
      else if (pc == P_B5W) begin op = OP_WAIT; w = 16'(T_STEP2_MS); end

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
        r = (p == ANCHOR) ? RATE_CODE  : 0;
        f = (p == ANCHOR) ? RATE_FIELD : RATE_FIELD_NONANCHOR;
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
      else if (pc >= P_B9C && pc < P_B9C + 2*NP) begin
        p  = ANCHOR + (pc - P_B9C) / 2;
        op = OP_WR; d = 32'h0;
        a  = ((pc - P_B9C) % 2 == 0) ? pp(p, O_PCTL_RX) : pp(p, O_PCTL_TX);
      end

      else if (pc == P_B10) begin op = OP_WAIT; w = (32'(T_PORT_CHAN_GAP_MS) * 32'(CYC_PER_MS)); end

      else if (pc >= P_B11 && pc < P_B11 + 2*NP) begin
        p  = ANCHOR + (pc - P_B11) / 2;
        op = OP_WR; d = 32'h0;
        a  = ((pc - P_B11) % 2 == 0) ? pp(p, O_CHCTL_TX) : pp(p, O_CHCTL_RX);
      end

      else if (pc == P_POLL) begin
        op = OP_POLL; a = pp(ANCHOR, O_RX_PHY_STATUS); d = ALIGN_ARM; w = (32'(T_ALIGN_MS) * 32'(CYC_PER_MS));
      end
      else if (pc == P_BR) begin op = OP_BR; d = 32'(P_LADDER); end

      else if (pc >= P_B17 && pc < P_B17 + 2*NP) begin
        p  = ANCHOR + (pc - P_B17) / 2;
        op = OP_WR; d = 32'h1;
        a  = ((pc - P_B17) % 2 == 0) ? pp(p, O_TICK_RX) : pp(p, O_TICK_TX);
      end
      else if (EN_STATS && pc >= P_STATS && pc < P_STATS + N_STAT) begin
        p = ANCHOR + (pc - P_STATS) / STATS_PER;
        k = (pc - P_STATS) % STATS_PER;
        case (k / 2)
          0: soff = O_STX_BYTES;  1: soff = O_STX_GBYTES;
          2: soff = O_STX_PKTS;   3: soff = O_STX_GPKTS;
          4: soff = O_SRX_BYTES;  5: soff = O_SRX_GBYTES;
          6: soff = O_SRX_PKTS;   7: soff = O_SRX_GPKTS;
          8: soff = O_FEC_CW;     9: soff = O_FEC_CORR;
          default: soff = O_FEC_UNCORR;
        endcase
        op = OP_RD; a = pp(p, soff + ((k % 2) ? 20'h4 : 20'h0));
      end
      else if (pc == P_DONE)   begin op = OP_DONE;  end

      else if (pc == P_LADDER) begin op = OP_BRX; d = 32'(P_FAULT); end
      else if (pc == P_LBZ)    begin op = OP_BRZ; d = 32'(P_GRP);   end
      else if (pc >= P_RUNG2 && pc < P_RUNG2 + 5) begin
        case (pc - P_RUNG2)
          0: begin op = OP_PIN;   d = 32'h1; end
          1: begin op = OP_WAIT;  w = (32'(T_RXDP_MS) * 32'(CYC_PER_MS)); end
          2: begin op = OP_PIN;   d = 32'h0; end
          3: begin op = OP_WAIT;  w = (32'(T_SERDES_MS) * 32'(CYC_PER_MS)); end
          4: begin op = OP_WDONE; d = 32'd1; w = (32'(DONE_TIMEOUT_MS) * 32'(CYC_PER_MS)); end
        endcase
      end
      else if (pc >= P_GRP  && pc < P_GRP  + NP) begin
        op = OP_WR; a = pp(ANCHOR + (pc - P_GRP),  O_PCTL_RX); d = 32'h2;
      end
      else if (pc == P_GRPW)  begin op = OP_WAIT; w = (32'(T_REALIGN_MS) * 32'(CYC_PER_MS)); end
      else if (pc >= P_GRPR && pc < P_GRPR + NP) begin
        op = OP_WR; a = pp(ANCHOR + (pc - P_GRPR), O_PCTL_RX); d = 32'h0;
      end
      else if (pc == P_GRPW2) begin op = OP_WAIT; w = (32'(T_REALIGN_MS) * 32'(CYC_PER_MS)); end
      else if (pc == P_INC)   begin op = OP_INC; end
      else if (pc == P_JMP)   begin op = OP_JMP;   d = 32'(P_POLL); end
      else if (pc == P_FAULT) begin op = OP_FAULT; end

      return {op, a, d, w};
    end
  endfunction

  localparam logic [4:0] S_IDLE      = 5'd0;
  localparam logic [4:0] S_FETCH     = 5'd1;
  localparam logic [4:0] S_WR_ADDR   = 5'd2;
  localparam logic [4:0] S_WR_RESP   = 5'd3;
  localparam logic [4:0] S_RD_ADDR   = 5'd4;
  localparam logic [4:0] S_RD_DATA   = 5'd5;
  localparam logic [4:0] S_WAIT      = 5'd6;
  localparam logic [4:0] S_WDONE     = 5'd7;
  localparam logic [4:0] S_POLL_ARM  = 5'd8;
  localparam logic [4:0] S_POLL_WAIT = 5'd9;
  localparam logic [4:0] S_POLL_RD   = 5'd10;
  localparam logic [4:0] S_POLL_CHK  = 5'd11;
  localparam logic [4:0] S_HALT      = 5'd12;
  localparam logic [4:0] S_ADV       = 5'd13;
  localparam logic [4:0] S_FETCH0    = 5'd14;

  localparam int PCW = (ROM_N > 1) ? $clog2(ROM_N) : 1;

  logic [4:0]        state, ret_state;
  logic [PCW-1:0]    pc;
  logic [REC_W-1:0]  rec_comb, rec;
  logic [3:0]        op;
  logic [19:0]       rec_addr;
  logic [31:0]       rec_data;
  logic [31:0]       rec_cyc;

  assign rec_comb = rom_rec(int'(pc));
  assign op       = rec[REC_W-1 -: 4];
  assign rec_addr = rec[64 +: 20];
  assign rec_data = rec[32 +: 32];
  assign rec_cyc  = rec[0  +: 32];

  logic [31:0] dly_cnt;
  logic [15:0] to_cnt;
  logic [15:0] poll_try;
  logic [7:0]  retry_cnt_r;
  logic        poll_fail;
  logic        link_up_r, link_fault_r, access_fault_r;
  logic        pin_rx_dp, pin_serdes;
  logic [31:0] rx_phy_status_r;
  logic [31:0] rdata_r;
  logic        aw_done, w_done;

  logic restart_q, stats_q_req;
  logic bringup_restart_d, stats_req_d;

  logic [31:0] stat_q [0:(N_STAT > 0 ? N_STAT-1 : 0)];

  logic [PORT_MAX-1:0] port_group_mask;
  always_comb begin
    port_group_mask = '0;
    for (int gp = 0; gp < PORT_MAX; gp++)
      if (gp >= ANCHOR && gp < (ANCHOR + NPORTS)) port_group_mask[gp] = 1'b1;
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
      poll_try        <= '0;
      retry_cnt_r     <= '0;
      poll_fail       <= 1'b0;
      link_up_r       <= 1'b0;
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
        poll_try        <= '0;
        retry_cnt_r     <= '0;
        poll_fail       <= 1'b0;
        link_up_r       <= 1'b0;
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
              OP_POLL: begin
                poll_try  <= '0;
                poll_fail <= 1'b0;
                state     <= S_POLL_ARM;
              end
              OP_BR:  begin pc <= poll_fail ? PCW'(rec_data) : (pc + 1'b1); state <= S_FETCH0; end
              OP_BRZ: begin pc <= (retry_cnt_r == 8'd0) ? PCW'(rec_data) : (pc + 1'b1); state <= S_FETCH0; end
              OP_BRX: begin pc <= (retry_cnt_r >= 8'(RX_CYCLES)) ? PCW'(rec_data) : (pc + 1'b1); state <= S_FETCH0; end
              OP_INC: begin retry_cnt_r <= retry_cnt_r + 1'b1; pc <= pc + 1'b1; state <= S_FETCH0; end
              OP_JMP: begin pc <= PCW'(rec_data); state <= S_FETCH0; end
              OP_DONE: begin
                link_up_r <= 1'b1;
                state     <= S_HALT;
              end
              OP_FAULT: begin
                link_fault_r <= 1'b1;
                state        <= S_HALT;
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

          S_POLL_ARM: begin
            m_axil_awaddr  <= rec_addr;
            m_axil_wdata   <= rec_data;
            m_axil_awvalid <= 1'b1;
            m_axil_wvalid  <= 1'b1;
            aw_done        <= 1'b0;
            w_done         <= 1'b0;
            to_cnt         <= '0;
            ret_state      <= S_POLL_WAIT;
            state          <= S_WR_ADDR;
          end
          S_POLL_WAIT: begin
            dly_cnt <= rec_cyc;
            state   <= S_POLL_RD;
          end
          S_POLL_RD: begin
            if (dly_cnt == 0) begin
              m_axil_araddr  <= rec_addr;
              m_axil_arvalid <= 1'b1;
              to_cnt         <= '0;
              ret_state      <= S_POLL_CHK;
              state          <= S_RD_ADDR;
            end else dly_cnt <= dly_cnt - 1'b1;
          end
          S_POLL_CHK: begin
            rx_phy_status_r <= rdata_r;
            if (rdata_r != AXI_BAD_MAGIC && ((rdata_r & ALIGN_MASK) == ALIGN_MASK)) begin
              poll_fail <= 1'b0;
              pc        <= pc + 1'b1;
              state     <= S_FETCH0;
            end else if (poll_try + 16'd1 >= 16'(POLL_TRIES)) begin
              poll_fail <= 1'b1;
              pc        <= pc + 1'b1;
              state     <= S_FETCH0;
            end else begin
              poll_try <= poll_try + 1'b1;
              state    <= S_POLL_ARM;
            end
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
  assign link_fault      = link_fault_r;
  assign access_fault    = access_fault_r;
  assign seq_busy        = (state != S_HALT) && (state != S_IDLE);
  assign rx_phy_status   = rx_phy_status_r;
  assign retry_cnt       = retry_cnt_r;
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
  end
  // synthesis translate_on

endmodule

`default_nettype wire
