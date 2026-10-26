// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ps / 1ps

module tb_nia_eth_rx_frame_buffer;

localparam int DATA_BITS = 1024;
localparam int DATA_BYTES = DATA_BITS / 8;
localparam int FRAME_COUNT = 8;
localparam int ADDRESS_BITS = 11;

int unsigned frame_length [FRAME_COUNT] = '{64, 128, 129, 512, 1500, 4096, 9000, 65};

int unsigned clock_period_ps = 2571;

logic clk = 1'b0;
logic rstn = 1'b0;

logic [DATA_BITS-1:0]  source_tdata = '0;
logic [DATA_BYTES-1:0] source_tkeep = '0;
logic                  source_tvalid = 1'b0;
logic                  source_tlast = 1'b0;
logic                  source_tready;

logic [DATA_BITS-1:0]  sink_tdata;
logic [DATA_BYTES-1:0] sink_tkeep;
logic                  sink_tvalid;
logic                  sink_tready = 1'b1;
logic                  sink_tlast;
logic [31:0]           drop_frames;
logic                  overflow;

int unsigned frames_seen = 0;
int unsigned byte_errors = 0;
int unsigned length_errors = 0;
int unsigned frame_index = 0;
int unsigned frame_bytes = 0;
bit keep_closed = 1'b0;

initial void'($value$plusargs("clock_period_ps=%d", clock_period_ps));

initial begin
    #1;
    forever #(clock_period_ps / 2) clk = ~clk;
end

dcmac_axis_frame_fifo #(
    .DATA_W(DATA_BITS),
    .KEEP_W(DATA_BYTES),
    .USER_W(1),
    .ADDR_W(ADDRESS_BITS),
    .DROP_BAD_FRAME(1'b0),
    .FLAG_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1),
    .MAX_FRAME_BEATS(0),
    .MEM_STYLE("block")
) dut (
    .clk(clk),
    .rstn(rstn),
    .abort(1'b0),
    .s_axis_tdata(source_tdata),
    .s_axis_tkeep(source_tkeep),
    .s_axis_tvalid(source_tvalid),
    .s_axis_tready(source_tready),
    .s_axis_tlast(source_tlast),
    .s_axis_tuser(1'b0),
    .m_axis_tdata(sink_tdata),
    .m_axis_tkeep(sink_tkeep),
    .m_axis_tvalid(sink_tvalid),
    .m_axis_tready(sink_tready),
    .m_axis_tlast(sink_tlast),
    .m_axis_tuser(),
    .drop_frames(drop_frames),
    .overflow(overflow)
);

function automatic logic [7:0] frame_byte(int unsigned index, int unsigned offset);
    if (offset == 0) return 8'(index);
    if (offset == 1) return 8'(index >> 8);
    return 8'((index * 31) + (offset * 7) + 5);
endfunction

task automatic drive_frame(int unsigned index, int unsigned length);
    int unsigned beats;
    int unsigned offset;
    beats = (length + DATA_BYTES - 1) / DATA_BYTES;
    for (int unsigned b = 0; b < beats; b++) begin
        @(negedge clk);
        for (int unsigned j = 0; j < DATA_BYTES; j++) begin
            offset = (b * DATA_BYTES) + j;
            if (offset < length) begin
                source_tdata[8*j +: 8] = frame_byte(index, offset);
                source_tkeep[j] = 1'b1;
            end else begin
                source_tdata[8*j +: 8] = 8'h00;
                source_tkeep[j] = 1'b0;
            end
        end
        source_tlast = (b == (beats - 1));
        source_tvalid = 1'b1;
        @(negedge clk);
        source_tvalid = 1'b0;
        source_tlast = 1'b0;
        source_tkeep = '0;
    end
endtask

always @(posedge clk) begin
    if (rstn && sink_tvalid && sink_tready) begin
        keep_closed = 1'b0;
        if (frame_bytes == 0) frame_index = {sink_tdata[15:8], sink_tdata[7:0]};
        for (int unsigned j = 0; j < DATA_BYTES; j++) begin
            if (sink_tkeep[j]) begin
                if (keep_closed) byte_errors++;
                if (sink_tdata[8*j +: 8] !== frame_byte(frame_index, frame_bytes)) begin
                    if (byte_errors < 4)
                        $display("FRAMEBUF BYTE MISMATCH frame=%0d offset=%0d got=%02x want=%02x",
                                 frame_index, frame_bytes, sink_tdata[8*j +: 8],
                                 frame_byte(frame_index, frame_bytes));
                    byte_errors++;
                end
                frame_bytes++;
            end else begin
                keep_closed = 1'b1;
            end
        end
        if (sink_tlast) begin
            if (frame_bytes != frame_length[frame_index % FRAME_COUNT]) begin
                $display("FRAMEBUF LENGTH MISMATCH frame=%0d got=%0d want=%0d", frame_index,
                         frame_bytes, frame_length[frame_index % FRAME_COUNT]);
                length_errors++;
            end
            frames_seen++;
            frame_bytes = 0;
        end
    end
end

initial begin
    rstn = 1'b0;
    repeat (32) @(posedge clk);
    rstn = 1'b1;
    repeat (32) @(posedge clk);

    $display("FRAMEBUF CONFIG data_bits=%0d address_bits=%0d memory_style=block clock_period_ps=%0d",
             DATA_BITS, ADDRESS_BITS, clock_period_ps);

    for (int unsigned i = 0; i < FRAME_COUNT; i++) drive_frame(i, frame_length[i]);

    repeat (2000) @(posedge clk);

    $display("FRAMEBUF STATE source_ready=%0b drop_frames=%0d overflow=%0b wr_cur=%0d wr_commit=%0d rd_ptr=%0d",
             source_tready, drop_frames, overflow, dut.wr_cur, dut.wr_commit, dut.rd_ptr);

    if (frames_seen == FRAME_COUNT && byte_errors == 0 && length_errors == 0)
        $display("FRAMEBUF RESULT PASS frames=%0d", frames_seen);
    else
        $display("FRAMEBUF RESULT FAIL frames=%0d of %0d byte_errors=%0d length_errors=%0d",
                 frames_seen, FRAME_COUNT, byte_errors, length_errors);
    $finish;
end

endmodule
