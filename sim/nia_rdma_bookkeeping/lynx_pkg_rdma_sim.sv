// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

package lynxTypes;

    localparam integer AXIL_DATA_BITS = 64;
    localparam integer AXI_DATA_BITS = 512;
    localparam integer AXI_ADDR_BITS = 64;
    localparam integer AXI_NET_BITS = 512;
    localparam integer AXI_ID_BITS = 6;
    localparam INPUT_TIMING = 1step;
    localparam OUTPUT_TIMING = 1step;

    localparam integer ADDR_BITS = 64;
    localparam integer PADDR_BITS = 44;
    localparam integer VADDR_BITS = 48;
    localparam integer LEN_BITS = 28;
    localparam integer DEST_BITS = 4;
    localparam integer PID_BITS = 6;
    localparam integer HPID_BITS = 32;
    localparam integer USER_BITS = 4;
    localparam integer NOTIFY_BITS = 32;
    localparam integer BEAT_LOG_BITS = $clog2(AXI_DATA_BITS/8);
    localparam integer BLEN_BITS = LEN_BITS - BEAT_LOG_BITS;
    localparam integer OFFS_BITS = 6;
    localparam integer OPCODE_BITS = 5;
    localparam integer STRM_BITS = 2;
    localparam integer TLB_DATA_BITS = 104;

    localparam integer STRM_CARD = 0;
    localparam integer STRM_HOST = 1;
    localparam integer STRM_RDMA = 2;
    localparam integer STRM_TCP = 3;

    localparam integer QUEUE_DEPTH = 8;

    localparam integer N_REGIONS = 1;
    localparam integer N_REGIONS_BITS = 1;
    localparam integer N_OUTSTANDING = 8;
    localparam integer RDMA_N_WR_OUTSTANDING = 16;
    localparam integer RDMA_N_RD_OUTSTANDING = 8;

    localparam integer RC_SEND_FIRST = 5'h0;
    localparam integer RC_SEND_MIDDLE = 5'h1;
    localparam integer RC_SEND_LAST = 5'h2;
    localparam integer RC_SEND_ONLY = 5'h4;
    localparam integer RC_RDMA_WRITE_FIRST = 5'h6;
    localparam integer RC_RDMA_WRITE_MIDDLE = 5'h7;
    localparam integer RC_RDMA_WRITE_LAST = 5'h8;
    localparam integer RC_RDMA_WRITE_ONLY = 5'hA;
    localparam integer RC_RDMA_READ_REQUEST = 5'hC;
    localparam integer RC_RDMA_READ_RESP_FIRST = 5'hD;
    localparam integer RC_RDMA_READ_RESP_MIDDLE = 5'hE;
    localparam integer RC_RDMA_READ_RESP_LAST = 5'hF;
    localparam integer RC_RDMA_READ_RESP_ONLY = 5'h10;
    localparam integer RC_ACK = 5'h11;

    localparam integer RDMA_ACK_BITS = 64;
    localparam integer RDMA_BASE_REQ_BITS = 144;
    localparam integer RDMA_VADDR_BITS = 64;
    localparam integer RDMA_LEN_BITS = 32;
    localparam integer RDMA_REQ_BITS = 248;
    localparam integer RDMA_QPN_BITS = 16;
    localparam integer RDMA_IMM_BITS = 32;
    localparam integer RDMA_OPCODE_BITS = 5;
    localparam integer PMTU_BYTES = 4096;

    typedef struct packed {
        logic [OPCODE_BITS-1:0] opcode;
        logic [STRM_BITS-1:0] strm;
        logic mode;
        logic rdma;
        logic remote;
        logic [DEST_BITS-1:0] vfid;
        logic [PID_BITS-1:0] pid;
        logic [DEST_BITS-1:0] dest;
        logic last;
        logic [VADDR_BITS-1:0] vaddr;
        logic [LEN_BITS-1:0] len;
        logic actv;
        logic host;
        logic [OFFS_BITS-1:0] offs;
        logic [128-OFFS_BITS-2-VADDR_BITS-LEN_BITS-1-2*DEST_BITS-PID_BITS-3-STRM_BITS-OPCODE_BITS-1:0] rsrvd;
    } req_t;

    typedef struct packed {
        req_t req_1;
        req_t req_2;
    } dreq_t;

    typedef struct packed {
        logic [OPCODE_BITS-1:0] opcode;
        logic [STRM_BITS-1:0] strm;
        logic remote;
        logic host;
        logic [DEST_BITS-1:0] dest;
        logic [PID_BITS-1:0] pid;
        logic [DEST_BITS-1:0] vfid;
        logic [32-OPCODE_BITS-STRM_BITS-2-DEST_BITS-PID_BITS-DEST_BITS-1:0] rsrvd;
    } ack_t;

    typedef struct packed {
        ack_t ack;
        logic last;
    } dack_t;

    function logic is_opcode_rd_req;
    input [OPCODE_BITS-1:0] opcode;
    begin
        if (opcode == RC_RDMA_READ_REQUEST) begin
            is_opcode_rd_req = 1'b1;
        end
        else begin
            is_opcode_rd_req = 1'b0;
        end
    end
    endfunction

    function logic is_opcode_rd_resp;
    input [OPCODE_BITS-1:0] opcode;
    begin
        if (opcode == RC_RDMA_READ_RESP_FIRST ||
            opcode == RC_RDMA_READ_RESP_MIDDLE ||
            opcode == RC_RDMA_READ_RESP_LAST ||
            opcode == RC_RDMA_READ_RESP_ONLY) begin
            is_opcode_rd_resp = 1'b1;
        end
        else begin
            is_opcode_rd_resp = 1'b0;
        end
    end
    endfunction

    function logic is_opcode_ack;
    input [OPCODE_BITS-1:0] opcode;
    begin
        if (opcode == RC_ACK) begin
            is_opcode_ack = 1'b1;
        end
        else begin
            is_opcode_ack = 1'b0;
        end
    end
    endfunction

    function logic is_strm_local;
    input [STRM_BITS-1:0] strm;
    begin
        if (strm == STRM_HOST || strm == STRM_CARD) begin
            is_strm_local = 1'b1;
        end
        else begin
            is_strm_local = 1'b0;
        end
    end
    endfunction

endpackage
