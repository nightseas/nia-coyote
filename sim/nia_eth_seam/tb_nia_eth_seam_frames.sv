// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ps / 1ps

module tb_nia_eth_seam_frames;

localparam int STREAM_BITS = 1024;
localparam int STREAM_BYTES = STREAM_BITS / 8;
localparam int SHELL_BITS = 512;
localparam int SHELL_BYTES = SHELL_BITS / 8;
localparam int FRAME_COUNT = 16;
localparam int CORRUPT_FRAME = 2;
localparam int CORRUPT_OFFSET = 10;

int unsigned frame_length [FRAME_COUNT] = '{
    64, 65, 127, 128, 129, 130, 255, 256,
    257, 511, 512, 513, 1500, 1501, 4096, 9000
};

int unsigned shell_period_ps = 2571;
int unsigned stream_period_ps = 2571;
int unsigned mac_beat_gap_cycles = 1;
int unsigned frame_gap_cycles = 1;
int unsigned sink_stall_period = 0;
int unsigned idle_timeout_ns = 20000;
int unsigned negative_control = 0;
int unsigned burst_repeat = 8;
int unsigned tx_stall_period = 0;

logic stream_clk = 1'b0;
logic shell_clk = 1'b0;
logic shell_resetn = 1'b0;

logic [STREAM_BITS-1:0]      mac_rx_tdata = '0;
logic [STREAM_BYTES-1:0]     mac_rx_tkeep = '0;
logic                        mac_rx_tvalid = 1'b0;
logic                        mac_rx_tlast = 1'b0;

int unsigned rx_frames_checked = 0;
int unsigned rx_byte_errors = 0;
int unsigned rx_length_errors = 0;
int unsigned rx_keep_errors = 0;
int unsigned rx_beats_taken = 0;
int unsigned rx_bytes_taken = 0;
int unsigned buffer_refusals = 0;
int unsigned buffered_beats = 0;
int unsigned converted_beats = 0;
int unsigned rx_frame_index = 0;
int unsigned rx_frame_bytes = 0;
int unsigned rx_expected_frames = 0;
bit rx_keep_closed = 1'b0;

int unsigned tx_frames_checked = 0;
int unsigned tx_byte_errors = 0;
int unsigned tx_length_errors = 0;
int unsigned tx_keep_errors = 0;
int unsigned tx_frame_index = 0;
int unsigned tx_frame_bytes = 0;
int unsigned tx_expected_frames = 0;
bit tx_keep_closed = 1'b0;
bit tx_phase_active = 1'b0;

int unsigned sink_phase = 0;

initial begin
    void'($value$plusargs("shell_period_ps=%d", shell_period_ps));
    void'($value$plusargs("stream_period_ps=%d", stream_period_ps));
    void'($value$plusargs("mac_beat_gap_cycles=%d", mac_beat_gap_cycles));
    void'($value$plusargs("frame_gap_cycles=%d", frame_gap_cycles));
    void'($value$plusargs("sink_stall_period=%d", sink_stall_period));
    void'($value$plusargs("idle_timeout_ns=%d", idle_timeout_ns));
    void'($value$plusargs("negative_control=%d", negative_control));
    void'($value$plusargs("burst_repeat=%d", burst_repeat));
    void'($value$plusargs("tx_stall_period=%d", tx_stall_period));
end

initial begin
    #1;
    forever #(stream_period_ps / 2) stream_clk = ~stream_clk;
end

initial begin
    #1;
    forever #(shell_period_ps / 2) shell_clk = ~shell_clk;
end

AXI4S #(.AXI4S_DATA_BITS(SHELL_BITS)) axis_shell_rx (.aclk(shell_clk), .aresetn(shell_resetn));
AXI4S #(.AXI4S_DATA_BITS(SHELL_BITS)) axis_shell_tx (.aclk(shell_clk), .aresetn(shell_resetn));

network_module_nia_eth_200g dut (
    .aclk(shell_clk),
    .aresetn(shell_resetn),
    .gt_refclk_p(stream_clk),
    .gt_refclk_n(~stream_clk),
    .gt_rxp_in(4'b0),
    .gt_rxn_in(4'b0),
    .gt_txp_out(),
    .gt_txn_out(),
    .m_axis_net_rx(axis_shell_rx),
    .s_axis_net_tx(axis_shell_tx)
);

logic mac_tx_tready = 1'b1;
int unsigned tx_stall_phase = 0;

always @(posedge stream_clk) begin
    tx_stall_phase <= tx_stall_phase + 1;
    if (tx_stall_period == 0) mac_tx_tready <= 1'b1;
    else mac_tx_tready <= ((tx_stall_phase % tx_stall_period) != (tx_stall_period - 1));
end

initial begin
    force dut.nia_eth_stream_reset = 1'b1;
    force dut.nia_eth_rx_tdata = mac_rx_tdata;
    force dut.nia_eth_rx_tkeep = mac_rx_tkeep;
    force dut.nia_eth_rx_tvalid = mac_rx_tvalid;
    force dut.nia_eth_rx_tlast = mac_rx_tlast;
    force dut.nia_eth_rx_tuser = 1'b0;
    force dut.nia_eth_tx_tready = mac_tx_tready;
    repeat (64) @(posedge stream_clk);
    force dut.nia_eth_stream_reset = 1'b0;
end

function automatic logic [7:0] frame_byte(int unsigned frame_index, int unsigned byte_index);
    if (byte_index == 0) return 8'(frame_index);
    if (byte_index == 1) return 8'(frame_index >> 8);
    return 8'((frame_index * 31) + (byte_index * 7) + 5);
endfunction

function automatic logic [7:0] driven_byte(int unsigned frame_index, int unsigned byte_index);
    if ((negative_control == 1) && (frame_index == CORRUPT_FRAME) && (byte_index == CORRUPT_OFFSET))
        return frame_byte(frame_index, byte_index) ^ 8'h01;
    return frame_byte(frame_index, byte_index);
endfunction

function automatic int unsigned beat_count(int unsigned length, int unsigned width_bytes);
    return (length + width_bytes - 1) / width_bytes;
endfunction

task automatic drive_mac_rx_frame(int unsigned frame_index, int unsigned length);
    int unsigned beats;
    int unsigned byte_index;
    beats = beat_count(length, STREAM_BYTES);
    for (int unsigned b = 0; b < beats; b++) begin
        @(negedge stream_clk);
        for (int unsigned j = 0; j < STREAM_BYTES; j++) begin
            byte_index = (b * STREAM_BYTES) + j;
            if (byte_index < length) begin
                mac_rx_tdata[8*j +: 8] = driven_byte(frame_index, byte_index);
                mac_rx_tkeep[j] = 1'b1;
            end else begin
                mac_rx_tdata[8*j +: 8] = 8'h00;
                mac_rx_tkeep[j] = 1'b0;
            end
        end
        mac_rx_tlast = (b == (beats - 1));
        mac_rx_tvalid = 1'b1;
        if (mac_beat_gap_cycles > 0) begin
            @(negedge stream_clk);
            mac_rx_tvalid = 1'b0;
            mac_rx_tlast = 1'b0;
            mac_rx_tkeep = '0;
            for (int unsigned g = 1; g < mac_beat_gap_cycles; g++) @(negedge stream_clk);
        end
    end
    if (mac_beat_gap_cycles == 0) begin
        @(negedge stream_clk);
        mac_rx_tvalid = 1'b0;
        mac_rx_tlast = 1'b0;
        mac_rx_tkeep = '0;
    end
    for (int unsigned g = 0; g < frame_gap_cycles; g++) @(negedge stream_clk);
endtask

task automatic drive_shell_tx_frame(int unsigned frame_index, int unsigned length);
    int unsigned beats;
    int unsigned byte_index;
    beats = beat_count(length, SHELL_BYTES);
    for (int unsigned b = 0; b < beats; b++) begin
        @(negedge shell_clk);
        for (int unsigned j = 0; j < SHELL_BYTES; j++) begin
            byte_index = (b * SHELL_BYTES) + j;
            if (byte_index < length) begin
                axis_shell_tx.tdata[8*j +: 8] = driven_byte(frame_index, byte_index);
                axis_shell_tx.tkeep[j] = 1'b1;
            end else begin
                axis_shell_tx.tdata[8*j +: 8] = 8'h00;
                axis_shell_tx.tkeep[j] = 1'b0;
            end
        end
        axis_shell_tx.tlast = (b == (beats - 1));
        axis_shell_tx.tvalid = 1'b1;
        do @(posedge shell_clk); while (!axis_shell_tx.tready);
        @(negedge shell_clk);
        axis_shell_tx.tvalid = 1'b0;
        axis_shell_tx.tlast = 1'b0;
        axis_shell_tx.tkeep = '0;
    end
endtask

always @(posedge stream_clk) begin
    if (mac_rx_tvalid && !dut.nia_eth_rx_buffer_tready) buffer_refusals <= buffer_refusals + 1;
    if (dut.nia_eth_rx_buffered_tvalid && dut.nia_eth_rx_buffered_tready)
        buffered_beats <= buffered_beats + 1;
    if (dut.axis_net_rx_stream_clk.tvalid && dut.axis_net_rx_stream_clk.tready)
        converted_beats <= converted_beats + 1;
end

always @(posedge shell_clk) begin
    if (!shell_resetn) sink_phase <= 0;
    else sink_phase <= sink_phase + 1;
end

always @(posedge shell_clk) begin
    if (!shell_resetn) axis_shell_rx.tready <= 1'b0;
    else if (sink_stall_period == 0) axis_shell_rx.tready <= 1'b1;
    else axis_shell_rx.tready <= ((sink_phase % sink_stall_period) != (sink_stall_period - 1));
end

always @(posedge shell_clk) begin
    if (shell_resetn && axis_shell_rx.tvalid && axis_shell_rx.tready) begin
        rx_keep_closed = 1'b0;
        rx_beats_taken++;
        if (rx_frame_bytes == 0)
            rx_frame_index = {axis_shell_rx.tdata[15:8], axis_shell_rx.tdata[7:0]};
        for (int unsigned j = 0; j < SHELL_BYTES; j++) begin
            if (axis_shell_rx.tkeep[j]) begin
                if (rx_keep_closed) rx_keep_errors++;
                if (axis_shell_rx.tdata[8*j +: 8] !== frame_byte(rx_frame_index, rx_frame_bytes)) begin
                    if (rx_byte_errors < 8)
                        $display("SEAMSIM RX BYTE MISMATCH frame=%0d offset=%0d got=%02x want=%02x",
                                 rx_frame_index, rx_frame_bytes, axis_shell_rx.tdata[8*j +: 8],
                                 frame_byte(rx_frame_index, rx_frame_bytes));
                    rx_byte_errors++;
                end
                rx_frame_bytes++;
                rx_bytes_taken++;
            end else begin
                rx_keep_closed = 1'b1;
            end
        end
        if (axis_shell_rx.tlast) begin
            if (rx_frame_bytes != frame_length[rx_frame_index % FRAME_COUNT]) begin
                $display("SEAMSIM RX LENGTH MISMATCH frame=%0d got=%0d want=%0d", rx_frame_index,
                         rx_frame_bytes, frame_length[rx_frame_index % FRAME_COUNT]);
                rx_length_errors++;
            end
            rx_frames_checked++;
            rx_frame_bytes = 0;
        end
    end
end

always @(posedge stream_clk) begin
    if (tx_phase_active && dut.nia_eth_tx_tvalid && mac_tx_tready) begin
        tx_keep_closed = 1'b0;
        if (tx_frame_bytes == 0)
            tx_frame_index = {dut.nia_eth_tx_tdata[15:8], dut.nia_eth_tx_tdata[7:0]};
        for (int unsigned j = 0; j < STREAM_BYTES; j++) begin
            if (dut.nia_eth_tx_tkeep[j]) begin
                if (tx_keep_closed) tx_keep_errors++;
                if (dut.nia_eth_tx_tdata[8*j +: 8] !== frame_byte(tx_frame_index, tx_frame_bytes)) begin
                    if (tx_byte_errors < 8)
                        $display("SEAMSIM TX BYTE MISMATCH frame=%0d offset=%0d got=%02x want=%02x",
                                 tx_frame_index, tx_frame_bytes, dut.nia_eth_tx_tdata[8*j +: 8],
                                 frame_byte(tx_frame_index, tx_frame_bytes));
                    tx_byte_errors++;
                end
                tx_frame_bytes++;
            end else begin
                tx_keep_closed = 1'b1;
            end
        end
        if (dut.nia_eth_tx_tlast) begin
            if (tx_frame_bytes != frame_length[tx_frame_index % FRAME_COUNT]) begin
                $display("SEAMSIM TX LENGTH MISMATCH frame=%0d got=%0d want=%0d", tx_frame_index,
                         tx_frame_bytes, frame_length[tx_frame_index % FRAME_COUNT]);
                tx_length_errors++;
            end
            tx_frames_checked++;
            tx_frame_bytes = 0;
        end
    end
end

task automatic wait_for_rx_frames(int unsigned target);
    int unsigned idle_ns = 0;
    int unsigned last = rx_frames_checked;
    while (rx_frames_checked < target && idle_ns < idle_timeout_ns) begin
        #1000;
        idle_ns++;
        if (rx_frames_checked != last) begin
            last = rx_frames_checked;
            idle_ns = 0;
        end
    end
    if (rx_frames_checked < target)
        $display("SEAMSIM RX TIMEOUT frames=%0d of %0d", rx_frames_checked, target);
endtask

task automatic wait_for_tx_frames(int unsigned target);
    int unsigned idle_ns = 0;
    int unsigned last = tx_frames_checked;
    while (tx_frames_checked < target && idle_ns < idle_timeout_ns) begin
        #1000;
        idle_ns++;
        if (tx_frames_checked != last) begin
            last = tx_frames_checked;
            idle_ns = 0;
        end
    end
    if (tx_frames_checked < target)
        $display("SEAMSIM TX TIMEOUT frames=%0d of %0d", tx_frames_checked, target);
endtask

initial begin
    axis_shell_tx.tvalid = 1'b0;
    axis_shell_tx.tlast = 1'b0;
    axis_shell_tx.tdata = '0;
    axis_shell_tx.tkeep = '0;
    shell_resetn = 1'b0;
    repeat (64) @(posedge shell_clk);
    shell_resetn = 1'b1;
    repeat (64) @(posedge shell_clk);
    wait (dut.nia_eth_stream_resetn === 1'b1);
    repeat (64) @(posedge stream_clk);

    $display("SEAMSIM CONFIG stream_period_ps=%0d shell_period_ps=%0d mac_beat_gap_cycles=%0d sink_stall_period=%0d negative_control=%0d",
             stream_period_ps, shell_period_ps, mac_beat_gap_cycles, sink_stall_period, negative_control);

    rx_expected_frames = FRAME_COUNT;
    for (int unsigned i = 0; i < FRAME_COUNT; i++) drive_mac_rx_frame(i, frame_length[i]);
    wait_for_rx_frames(rx_expected_frames);
    $display("SEAMSIM RX SWEEP frames=%0d of %0d bytes=%0d byte_errors=%0d length_errors=%0d keep_errors=%0d refusals=%0d buffered=%0d converted=%0d",
             rx_frames_checked, rx_expected_frames, rx_bytes_taken, rx_byte_errors,
             rx_length_errors, rx_keep_errors, buffer_refusals, buffered_beats, converted_beats);

    $display("SEAMSIM RX STATE stream_resetn=%0b buffer_tready=%0b buffered_tvalid=%0b buffered_tready=%0b converter_tvalid=%0b converter_tready=%0b shell_tvalid=%0b",
             dut.nia_eth_stream_resetn, dut.nia_eth_rx_buffer_tready,
             dut.nia_eth_rx_buffered_tvalid, dut.nia_eth_rx_buffered_tready,
             dut.axis_net_rx_stream_clk.tvalid, dut.axis_net_rx_stream_clk.tready,
             axis_shell_rx.tvalid);

    rx_expected_frames = FRAME_COUNT + (FRAME_COUNT * burst_repeat);
    for (int unsigned r = 0; r < burst_repeat; r++)
        for (int unsigned i = 0; i < FRAME_COUNT; i++)
            drive_mac_rx_frame(FRAME_COUNT + (r * FRAME_COUNT) + i, frame_length[i]);
    wait_for_rx_frames(rx_expected_frames);
    $display("SEAMSIM RX BURST frames=%0d of %0d bytes=%0d byte_errors=%0d length_errors=%0d keep_errors=%0d refusals=%0d",
             rx_frames_checked, rx_expected_frames, rx_bytes_taken, rx_byte_errors,
             rx_length_errors, rx_keep_errors, buffer_refusals);

    tx_phase_active = 1'b1;
    tx_expected_frames = FRAME_COUNT;
    for (int unsigned i = 0; i < FRAME_COUNT; i++) drive_shell_tx_frame(i, frame_length[i]);
    wait_for_tx_frames(tx_expected_frames);
    $display("SEAMSIM TX SWEEP frames=%0d of %0d byte_errors=%0d length_errors=%0d keep_errors=%0d",
             tx_frames_checked, tx_expected_frames, tx_byte_errors, tx_length_errors, tx_keep_errors);
    tx_phase_active = 1'b0;

    if (rx_frames_checked == rx_expected_frames && tx_frames_checked == tx_expected_frames &&
        rx_byte_errors == 0 && rx_length_errors == 0 && rx_keep_errors == 0 &&
        tx_byte_errors == 0 && tx_length_errors == 0 && tx_keep_errors == 0)
        $display("SEAMSIM RESULT PASS refusals=%0d rx_bytes=%0d", buffer_refusals, rx_bytes_taken);
    else
        $display("SEAMSIM RESULT FAIL rx=%0d/%0d tx=%0d/%0d rx_byte=%0d rx_len=%0d rx_keep=%0d tx_byte=%0d tx_len=%0d tx_keep=%0d refusals=%0d",
                 rx_frames_checked, rx_expected_frames, tx_frames_checked, tx_expected_frames,
                 rx_byte_errors, rx_length_errors, rx_keep_errors, tx_byte_errors,
                 tx_length_errors, tx_keep_errors, buffer_refusals);
    $finish;
end

endmodule
