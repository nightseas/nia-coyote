/**
 * This file is part of the Coyote <https://github.com/fpgasystems/Coyote>
 *
 * MIT Licence
 * Copyright (c) 2025, Systems Group, ETH Zurich
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

localparam integer N_STRM = N_STRM_AXI;
localparam integer CBITS  = (N_STRM > 1) ? $clog2(N_STRM) : 1;

parameter integer START_RD = 0;
parameter integer START_WR = 1;

typedef enum logic [1:0] {ST_IDLE, ST_READ, ST_WRITE} state_t;

AXI4SR axis_in_int  [N_STRM] (.aclk(aclk), .aresetn(aresetn));
AXI4SR axis_out_int [N_STRM] (.aclk(aclk), .aresetn(aresetn));

for (genvar i = 0; i < N_STRM; i++) begin : g_pipe
    axisr_reg inst_reg_in (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis(axis_host_recv[i]), .m_axis(axis_in_int[i])
    );
    axisr_reg inst_reg_out (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis(axis_out_int[i]), .m_axis(axis_host_send[i])
    );
end

logic [N_STRM-1:0][1:0]            bench_ctrl;
logic [N_STRM-1:0][31:0]           bench_n_reps;
logic [N_STRM-1:0][31:0]           bench_sent;
logic [N_STRM-1:0][31:0]           bench_done;
logic [N_STRM-1:0]                 done_req;
logic [N_STRM-1:0]                 done_data;
logic [N_STRM-1:0][63:0]           bench_n_beats;
logic [N_STRM-1:0][63:0]           cnt_data;
logic [N_STRM-1:0][LEN_BITS-1:0]   bench_len;
logic [N_STRM-1:0][VADDR_BITS-1:0] bench_vaddr;
logic [N_STRM-1:0][PID_BITS-1:0]   bench_pid;
logic [N_STRM-1:0][1:0]            state_C;
logic [N_STRM-1:0][63:0]           bench_timer;

logic [N_STRM-1:0] in_tvalid, in_tready;
logic [N_STRM-1:0] out_tvalid, out_tready;

perf_fpga_mq_axi_ctrl_parser #(
    .N_STRM(N_STRM)
) inst_axi_ctrl_parser (
    .aclk(aclk),
    .aresetn(aresetn),
    .axi_ctrl(axi_ctrl),
    .bench_ctrl(bench_ctrl),
    .bench_done(bench_done),
    .bench_timer(bench_timer),
    .bench_vaddr(bench_vaddr),
    .bench_len(bench_len),
    .bench_pid(bench_pid),
    .bench_n_reps(bench_n_reps),
    .bench_n_beats(bench_n_beats)
);

for (genvar i = 0; i < N_STRM; i++) begin : g_dp
    assign in_tvalid[i]            = axis_in_int[i].tvalid;
    assign axis_in_int[i].tready   = (state_C[i] == ST_READ) && ~done_data[i];
    assign in_tready[i]            = axis_in_int[i].tready;

    assign axis_out_int[i].tdata   = cnt_data[i] + 1;
    assign axis_out_int[i].tkeep   = ~0;
    assign axis_out_int[i].tid     = '0;
    assign axis_out_int[i].tlast   = (cnt_data[i] == bench_n_beats[i] - 1);
    assign axis_out_int[i].tvalid  = (state_C[i] == ST_WRITE) && ~done_data[i];
    assign out_tvalid[i]           = axis_out_int[i].tvalid;
    assign out_tready[i]           = axis_out_int[i].tready;
end

logic [N_STRM-1:0]  rd_req_valid;
logic [N_STRM-1:0]  wr_req_valid;

logic [CBITS-1:0]   rr_ptr_rd, rr_ptr_wr;
logic [CBITS-1:0]   gnt_rd, gnt_wr;
logic               gnt_rd_vld, gnt_wr_vld;

always_comb begin
    for (int i = 0; i < N_STRM; i++) begin
        rd_req_valid[i] = (state_C[i] == ST_READ)  && ~done_req[i];
        wr_req_valid[i] = (state_C[i] == ST_WRITE) && ~done_req[i];
    end
end

always_comb begin
    gnt_rd     = rr_ptr_rd;
    gnt_rd_vld = 1'b0;
    for (int k = 0; k < N_STRM; k++) begin
        automatic logic [CBITS-1:0] idx = rr_ptr_rd + k[CBITS-1:0];
        if (!gnt_rd_vld && rd_req_valid[idx]) begin
            gnt_rd     = idx;
            gnt_rd_vld = 1'b1;
        end
    end
end

always_comb begin
    gnt_wr     = rr_ptr_wr;
    gnt_wr_vld = 1'b0;
    for (int k = 0; k < N_STRM; k++) begin
        automatic logic [CBITS-1:0] idx = rr_ptr_wr + k[CBITS-1:0];
        if (!gnt_wr_vld && wr_req_valid[idx]) begin
            gnt_wr     = idx;
            gnt_wr_vld = 1'b1;
        end
    end
end

always_comb begin
    sq_rd.data        = 0;
    sq_rd.data.opcode = LOCAL_READ;
    sq_rd.data.strm   = STRM_HOST;
    sq_rd.data.dest   = gnt_rd;
    sq_rd.data.pid    = bench_pid[gnt_rd];
    sq_rd.data.vaddr  = bench_vaddr[gnt_rd];
    sq_rd.data.len    = bench_len[gnt_rd];
    sq_rd.data.last   = (bench_sent[gnt_rd] == bench_n_reps[gnt_rd] - 1);
    sq_rd.valid       = gnt_rd_vld;
    cq_rd.ready       = 1'b1;

    sq_wr.data        = 0;
    sq_wr.data.opcode = LOCAL_WRITE;
    sq_wr.data.strm   = STRM_HOST;
    sq_wr.data.dest   = gnt_wr;
    sq_wr.data.pid    = bench_pid[gnt_wr];
    sq_wr.data.vaddr  = bench_vaddr[gnt_wr];
    sq_wr.data.len    = bench_len[gnt_wr];
    sq_wr.data.last   = (bench_sent[gnt_wr] == bench_n_reps[gnt_wr] - 1);
    sq_wr.valid       = gnt_wr_vld;
    cq_wr.ready       = 1'b1;
end

always_ff @(posedge aclk) begin
    if (aresetn == 1'b0) begin
        for (int i = 0; i < N_STRM; i++) begin
            state_C[i]     <= ST_IDLE;
            cnt_data[i]    <= 0;
            bench_sent[i]  <= 0;
            done_req[i]    <= 1'b0;
            done_data[i]   <= 1'b0;
            bench_done[i]  <= 0;
            bench_timer[i] <= 'X;
        end
        rr_ptr_rd <= '0;
        rr_ptr_wr <= '0;
    end
    else begin
        for (int i = 0; i < N_STRM; i++) begin
            automatic logic trig   = bench_ctrl[i][START_RD] | bench_ctrl[i][START_WR];
            automatic logic acc_rd = gnt_rd_vld && (gnt_rd == i[CBITS-1:0]) && sq_rd.ready;
            automatic logic acc_wr = gnt_wr_vld && (gnt_wr == i[CBITS-1:0]) && sq_wr.ready;
            automatic logic cmpl   = (cq_rd.valid && (cq_rd.data.dest == i[DEST_BITS-1:0])) ||
                                     (cq_wr.valid && (cq_wr.data.dest == i[DEST_BITS-1:0]));

            case (state_C[i])
                ST_IDLE: begin
                    state_C[i] <= bench_ctrl[i][START_RD] ? ST_READ  :
                                  bench_ctrl[i][START_WR] ? ST_WRITE : ST_IDLE;
                    cnt_data[i]   <= 0;
                    bench_sent[i] <= 0;
                    done_req[i]   <= 1'b0;
                    done_data[i]  <= 1'b0;
                end
                ST_READ: begin
                    bench_sent[i] <= acc_rd ? bench_sent[i] + 1 : bench_sent[i];
                    done_req[i]   <= ((bench_sent[i] == bench_n_reps[i] - 1) && acc_rd) ? 1'b1 : done_req[i];
                    cnt_data[i]   <= (in_tvalid[i] && in_tready[i]) ? cnt_data[i] + 1 : cnt_data[i];
                    done_data[i]  <= ((cnt_data[i] == bench_n_beats[i] - 1) && in_tvalid[i]) ? 1'b1 : done_data[i];
                    state_C[i]    <= (done_req[i] && done_data[i]) ? ST_IDLE : ST_READ;
                end
                ST_WRITE: begin
                    done_req[i]   <= ((bench_sent[i] == bench_n_reps[i] - 1) && acc_wr) ? 1'b1 : done_req[i];
                    bench_sent[i] <= acc_wr ? bench_sent[i] + 1 : bench_sent[i];
                    cnt_data[i]   <= (out_tvalid[i] && out_tready[i]) ? cnt_data[i] + 1 : cnt_data[i];
                    done_data[i]  <= ((cnt_data[i] == bench_n_beats[i] - 1) && out_tready[i]) ? 1'b1 : done_data[i];
                    state_C[i]    <= (done_req[i] && done_data[i]) ? ST_IDLE : ST_WRITE;
                end
                default: state_C[i] <= ST_IDLE;
            endcase

            bench_done[i]  <= trig ? 32'd0 : (cmpl ? 32'd1 : bench_done[i]);

            bench_timer[i] <= trig        ? 64'd0 :
                              bench_done[i] ? bench_timer[i] : bench_timer[i] + 1;
        end

        if (gnt_rd_vld && sq_rd.ready) rr_ptr_rd <= gnt_rd + 1'b1;
        if (gnt_wr_vld && sq_wr.ready) rr_ptr_wr <= gnt_wr + 1'b1;
    end
end

always_comb notify.tie_off_m();

ila_perf_fpga_mq inst_ila_perf_fpga_mq (
    .clk(aclk),
    .probe0(bench_ctrl),
    .probe1(done_req),
    .probe2(done_data),
    .probe3(bench_done[0]),
    .probe4(bench_timer[0]),
    .probe5(cnt_data[0]),
    .probe6(bench_sent[0]),
    .probe7(sq_rd.valid),
    .probe8(sq_rd.ready),
    .probe9(sq_wr.valid),
    .probe10(sq_wr.ready),
    .probe11(cq_rd.valid),
    .probe12(cq_wr.valid),
    .probe13(gnt_rd),
    .probe14(gnt_wr)
);
