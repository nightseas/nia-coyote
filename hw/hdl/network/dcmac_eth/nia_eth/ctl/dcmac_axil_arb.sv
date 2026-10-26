// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`default_nettype none

module dcmac_axil_arb #(
  parameter int AW = 20
) (
  input  wire            clk,
  input  wire            rstn,

  input  wire [AW-1:0]   s_axil_awaddr,
  input  wire            s_axil_awvalid,
  output wire            s_axil_awready,
  input  wire [31:0]     s_axil_wdata,
  input  wire [3:0]      s_axil_wstrb,
  input  wire            s_axil_wvalid,
  output wire            s_axil_wready,
  output wire [1:0]      s_axil_bresp,
  output wire            s_axil_bvalid,
  input  wire            s_axil_bready,
  input  wire [AW-1:0]   s_axil_araddr,
  input  wire            s_axil_arvalid,
  output wire            s_axil_arready,
  output wire [31:0]     s_axil_rdata,
  output wire [1:0]      s_axil_rresp,
  output wire            s_axil_rvalid,
  input  wire            s_axil_rready,

  output wire            req_valid,
  output wire            req_write,
  output wire [AW-1:0]   req_addr,
  output wire [31:0]     req_wdata,
  input  wire            req_gnt,
  input  wire            req_ack,
  input  wire [31:0]     ack_rdata,
  input  wire            ack_err
);

  typedef enum logic [2:0] {
    T_IDLE = 3'd0,
    T_WREQ = 3'd1,
    T_WRSP = 3'd2,
    T_RREQ = 3'd3,
    T_RRSP = 3'd4
  } tst_e;

  tst_e          st;
  logic [AW-1:0] addr_r;
  logic [31:0]   wdata_r;
  logic [31:0]   rdata_r;
  logic          err_r;
  logic          aw_seen, w_seen;
  logic          req_r, wr_r;

  wire have_write = aw_seen && w_seen;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      st      <= T_IDLE;
      addr_r  <= '0;
      wdata_r <= '0;
      rdata_r <= '0;
      err_r   <= 1'b0;
      aw_seen <= 1'b0;
      w_seen  <= 1'b0;
      req_r   <= 1'b0;
      wr_r    <= 1'b0;
    end else begin
      case (st)
        T_IDLE: begin
          if (s_axil_awvalid && !aw_seen) begin addr_r  <= s_axil_awaddr; aw_seen <= 1'b1; end
          if (s_axil_wvalid  && !w_seen ) begin wdata_r <= s_axil_wdata;  w_seen  <= 1'b1; end

          if (have_write || (s_axil_awvalid && s_axil_wvalid)) begin
            addr_r  <= aw_seen ? addr_r  : s_axil_awaddr;
            wdata_r <= w_seen  ? wdata_r : s_axil_wdata;
            wr_r    <= 1'b1;
            req_r   <= 1'b1;
            st      <= T_WREQ;
          end else if (s_axil_arvalid) begin
            addr_r <= s_axil_araddr;
            wr_r   <= 1'b0;
            req_r  <= 1'b1;
            st     <= T_RREQ;
          end
        end
        T_WREQ: begin
          if (req_gnt) req_r <= 1'b0;
          if (req_ack) begin
            req_r   <= 1'b0;
            err_r   <= ack_err;
            aw_seen <= 1'b0;
            w_seen  <= 1'b0;
            st      <= T_WRSP;
          end
        end
        T_WRSP: if (s_axil_bready) st <= T_IDLE;
        T_RREQ: begin
          if (req_gnt) req_r <= 1'b0;
          if (req_ack) begin
            req_r   <= 1'b0;
            rdata_r <= ack_rdata;
            err_r   <= ack_err;
            st      <= T_RRSP;
          end
        end
        T_RRSP: if (s_axil_rready) st <= T_IDLE;
        default: st <= T_IDLE;
      endcase
    end
  end

  assign s_axil_awready = (st == T_IDLE) && !aw_seen;
  assign s_axil_wready  = (st == T_IDLE) && !w_seen;
  assign s_axil_bvalid  = (st == T_WRSP);

  assign s_axil_bresp   = err_r ? 2'b10 : 2'b00;
  assign s_axil_arready = (st == T_IDLE) && !aw_seen && !w_seen && !s_axil_awvalid && !s_axil_wvalid;
  assign s_axil_rvalid  = (st == T_RRSP);
  assign s_axil_rdata   = rdata_r;
  assign s_axil_rresp   = err_r ? 2'b10 : 2'b00;

  assign req_valid = req_r;
  assign req_write = wr_r;
  assign req_addr  = addr_r;
  assign req_wdata = wdata_r;

endmodule

`default_nettype wire
