// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module dcmac_axil_exec #(
  parameter int N_REQ        = 3,
  parameter int AW           = 20,
  parameter int RR_START     = 1,

  parameter int TMO_CYC      = 4096,

  parameter logic [31:0] BAD_MAGIC = 32'hDEAD_C0DE
) (
  input  wire                     clk,
  input  wire                     rstn,

  input  wire [N_REQ-1:0]         req_valid,
  input  wire [N_REQ-1:0]         req_write,
  input  wire [N_REQ*AW-1:0]      req_addr,
  input  wire [N_REQ*32-1:0]      req_wdata,
  input  wire [N_REQ*32-1:0]      req_mask,
  output wire [N_REQ-1:0]         req_gnt,
  output wire [N_REQ-1:0]         req_ack,
  output wire [31:0]              ack_rdata,
  output wire                     ack_aligned,
  output wire                     ack_err,

  output wire [AW-1:0]            m_axil_awaddr,
  output wire                     m_axil_awvalid,
  input  wire                     m_axil_awready,
  output wire [31:0]              m_axil_wdata,
  output wire [3:0]               m_axil_wstrb,
  output wire                     m_axil_wvalid,
  input  wire                     m_axil_wready,
  input  wire [1:0]               m_axil_bresp,
  input  wire                     m_axil_bvalid,
  output wire                     m_axil_bready,
  output wire [AW-1:0]            m_axil_araddr,
  output wire                     m_axil_arvalid,
  input  wire                     m_axil_arready,
  input  wire [31:0]              m_axil_rdata,
  input  wire [1:0]               m_axil_rresp,
  input  wire                     m_axil_rvalid,
  output wire                     m_axil_rready,

  output wire                     busy,
  output wire [$clog2(N_REQ+1)-1:0] cur_req,
  output wire [15:0]              tmo_count
);

  initial begin
    if (N_REQ < 1)
      $fatal(1, "dcmac_axil_exec: N_REQ must be >= 1");
    if (RR_START < 0 || RR_START > N_REQ)
      $fatal(1, "dcmac_axil_exec: RR_START must be 0..N_REQ (got %0d)", RR_START);
  end

  localparam int IW = (N_REQ < 2) ? 1 : $clog2(N_REQ);

  typedef enum logic [2:0] {
    S_IDLE  = 3'd0,
    S_AW    = 3'd1,
    S_W     = 3'd2,
    S_B     = 3'd3,
    S_AR    = 3'd4,
    S_R     = 3'd5,
    S_DONE  = 3'd6
  } st_e;

  st_e            st;
  logic [IW-1:0]  sel;
  logic [IW-1:0]  rr;
  logic [AW-1:0]  addr_r;
  logic [31:0]    wdata_r, mask_r;
  logic           write_r;
  logic [31:0]    rdata_r;
  logic           err_r, aligned_r;
  logic           awdone, wdone;
  logic [31:0]    tmr;
  logic [15:0]    tmoc;
  logic [N_REQ-1:0] gnt_r, ack_r;

  function automatic logic [AW-1:0] a_of(input logic [IW-1:0] i);
    return req_addr[i*AW +: AW];
  endfunction
  function automatic logic [31:0] d_of(input logic [IW-1:0] i);
    return req_wdata[i*32 +: 32];
  endfunction
  function automatic logic [31:0] m_of(input logic [IW-1:0] i);
    return req_mask[i*32 +: 32];
  endfunction

  localparam int RRN = (N_REQ > RR_START) ? (N_REQ - RR_START) : 1;

  logic           pick_v;
  logic [IW-1:0]  pick_i;

  always_comb begin
    pick_v = 1'b0;
    pick_i = '0;

    for (int i = 0; i < RR_START; i++) begin
      if (!pick_v && req_valid[i]) begin
        pick_v = 1'b1;
        pick_i = IW'(i);
      end
    end

    if (N_REQ > RR_START) begin
      for (int k = 1; k <= RRN; k++) begin
        if (!pick_v && req_valid[RR_START + ((int'(rr) - RR_START + k) % RRN)]) begin
          pick_v = 1'b1;
          pick_i = IW'(RR_START + ((int'(rr) - RR_START + k) % RRN));
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st        <= S_IDLE;
      sel       <= '0;
      rr        <= IW'(RR_START);
      addr_r    <= '0;
      wdata_r   <= '0;
      mask_r    <= '0;
      write_r   <= 1'b0;
      rdata_r   <= '0;
      err_r     <= 1'b0;
      aligned_r <= 1'b0;
      awdone    <= 1'b0;
      wdone     <= 1'b0;
      tmr       <= '0;
      tmoc      <= '0;
      gnt_r     <= '0;
      ack_r     <= '0;
    end else begin
      gnt_r <= '0;
      ack_r <= '0;

      if (st != S_IDLE && st != S_DONE && TMO_CYC > 0) begin
        if (tmr >= 32'(TMO_CYC)) begin

          err_r     <= 1'b1;
          aligned_r <= 1'b0;
          tmoc      <= (tmoc == 16'hFFFF) ? tmoc : tmoc + 16'd1;
          st        <= S_DONE;
        end else begin
          tmr <= tmr + 1'b1;
        end
      end

      unique case (st)
        S_IDLE: begin
          if (pick_v) begin
            sel     <= pick_i;
            addr_r  <= a_of(pick_i);
            wdata_r <= d_of(pick_i);
            mask_r  <= m_of(pick_i);
            write_r <= req_write[pick_i];
            gnt_r[pick_i] <= 1'b1;
            if (int'(pick_i) >= RR_START) rr <= pick_i;
            err_r     <= 1'b0;
            aligned_r <= 1'b0;
            awdone    <= 1'b0;
            wdone     <= 1'b0;
            tmr       <= '0;
            st        <= req_write[pick_i] ? S_AW : S_AR;
          end
        end

        S_AW, S_W: begin
          if (m_axil_awvalid && m_axil_awready) awdone <= 1'b1;
          if (m_axil_wvalid  && m_axil_wready)  wdone  <= 1'b1;
          if ((awdone || (m_axil_awvalid && m_axil_awready))
              && (wdone || (m_axil_wvalid && m_axil_wready)))
            st <= S_B;
        end
        S_B: begin
          if (m_axil_bvalid) begin
            err_r     <= (m_axil_bresp != 2'b00);
            aligned_r <= 1'b0;
            st        <= S_DONE;
          end
        end

        S_AR: begin
          if (m_axil_arvalid && m_axil_arready) st <= S_R;
        end
        S_R: begin
          if (m_axil_rvalid) begin
            rdata_r <= m_axil_rdata;
            if ((m_axil_rresp != 2'b00) || (m_axil_rdata == BAD_MAGIC)) begin

              err_r     <= 1'b1;
              aligned_r <= 1'b0;
            end else begin
              err_r     <= 1'b0;
              aligned_r <= ((m_axil_rdata & mask_r) == mask_r);
            end
            st <= S_DONE;
          end
        end

        S_DONE: begin
          ack_r[sel] <= 1'b1;
          st         <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  assign m_axil_awaddr  = addr_r;
  assign m_axil_awvalid = (st == S_AW || st == S_W) && write_r && !awdone;
  assign m_axil_wdata   = wdata_r;
  assign m_axil_wstrb   = 4'hF;
  assign m_axil_wvalid  = (st == S_AW || st == S_W) && write_r && !wdone;
  assign m_axil_bready  = (st == S_B);
  assign m_axil_araddr  = addr_r;
  assign m_axil_arvalid = (st == S_AR);
  assign m_axil_rready  = (st == S_R);

  assign req_gnt     = gnt_r;
  assign req_ack     = ack_r;
  assign ack_rdata   = rdata_r;
  assign ack_aligned = aligned_r;
  assign ack_err     = err_r;
  assign busy        = (st != S_IDLE);
  assign cur_req     = ($clog2(N_REQ+1))'(sel);
  assign tmo_count   = tmoc;

endmodule

`default_nettype wire
