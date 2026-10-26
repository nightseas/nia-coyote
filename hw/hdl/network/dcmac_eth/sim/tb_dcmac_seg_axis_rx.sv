// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps

module tb_dcmac_seg_axis_rx;

    localparam int N_SEG = 4;
    localparam int SEG_W = 128;
    localparam int SEG_B = SEG_W / 8;
    localparam int BEAT_B = N_SEG * SEG_B;
    localparam bit IN_REG = `TB_IN_REG;

    logic clk = 1'b0;
    logic rstn = 1'b0;

    logic                   rx_seg_valid = 1'b0;
    logic [N_SEG*SEG_W-1:0] rx_seg_dat = '0;
    logic [N_SEG-1:0]       rx_seg_ena = '0;
    logic [N_SEG-1:0]       rx_seg_sop = '0;
    logic [N_SEG-1:0]       rx_seg_eop = '0;
    logic [N_SEG-1:0]       rx_seg_err = '0;
    logic [N_SEG*4-1:0]     rx_seg_mty = '0;

    logic [N_SEG*SEG_W-1:0]   m_axis_tdata;
    logic [N_SEG*SEG_W/8-1:0] m_axis_tkeep;
    logic                     m_axis_tvalid;
    logic                     m_axis_tready = 1'b1;
    logic                     m_axis_tlast;
    logic                     m_axis_tuser;
    logic                     rx_align_drop;
    logic [31:0]              rx_align_stat;

    always #1.28 clk = ~clk;

    dcmac_seg_axis_rx #(
        .N_SEG     (N_SEG),
        .SEG_W     (SEG_W),
        .OUT_DEPTH (16),
        .IN_REG    (IN_REG)
    ) dut (
        .clk           (clk),
        .rstn          (rstn),
        .rx_seg_valid  (rx_seg_valid),
        .rx_seg_dat    (rx_seg_dat),
        .rx_seg_ena    (rx_seg_ena),
        .rx_seg_sop    (rx_seg_sop),
        .rx_seg_eop    (rx_seg_eop),
        .rx_seg_err    (rx_seg_err),
        .rx_seg_mty    (rx_seg_mty),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tkeep  (m_axis_tkeep),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tuser  (m_axis_tuser),
        .rx_align_drop (rx_align_drop),
        .rx_align_stat (rx_align_stat)
    );

    int lengths[$];
    byte unsigned frames[$][$];
    byte unsigned got_frame[$];
    int got_index = 0;
    int mismatches = 0;
    int frames_seen = 0;
    int tests = 0;
    int passes = 0;
    int failures = 0;

    function automatic void build_frame(input int length, input byte unsigned tag);
        byte unsigned f[$];
        int index;
        for (index = 0; index < length; index++) f.push_back(byte'(tag + index));
        frames.push_back(f);
        lengths.push_back(length);
    endfunction

    task automatic drive_frames(input bit pack_tight, input bit throttle);
        int frame_index;
        int byte_index;
        int seg_in_cycle;
        int total_segments;
        int this_segment;
        int remaining;
        byte unsigned current[$];
        logic [N_SEG*SEG_W-1:0] cyc_dat;
        logic [N_SEG-1:0] cyc_ena, cyc_sop, cyc_eop;
        logic [N_SEG*4-1:0] cyc_mty;
        int index;

        seg_in_cycle = 0;
        cyc_dat = '0; cyc_ena = '0; cyc_sop = '0; cyc_eop = '0; cyc_mty = '0;

        for (frame_index = 0; frame_index < frames.size(); frame_index++) begin
            current = frames[frame_index];
            total_segments = (current.size() + SEG_B - 1) / SEG_B;
            for (this_segment = 0; this_segment < total_segments; this_segment++) begin
                remaining = current.size() - this_segment * SEG_B;
                if (remaining > SEG_B) remaining = SEG_B;
                for (index = 0; index < remaining; index++)
                    cyc_dat[seg_in_cycle*SEG_W + index*8 +: 8] = current[this_segment*SEG_B + index];
                cyc_ena[seg_in_cycle] = 1'b1;
                cyc_sop[seg_in_cycle] = (this_segment == 0);
                cyc_eop[seg_in_cycle] = (this_segment == total_segments - 1);
                if (cyc_eop[seg_in_cycle])
                    cyc_mty[seg_in_cycle*4 +: 4] = 4'(SEG_B - remaining);
                seg_in_cycle++;
                if (seg_in_cycle == N_SEG) begin
                    send_cycle(cyc_dat, cyc_ena, cyc_sop, cyc_eop, cyc_mty, throttle);
                    if (throttle) idle_cycles(2);
                    seg_in_cycle = 0;
                    cyc_dat = '0; cyc_ena = '0; cyc_sop = '0; cyc_eop = '0; cyc_mty = '0;
                end
            end
            if (!pack_tight && seg_in_cycle != 0) begin
                send_cycle(cyc_dat, cyc_ena, cyc_sop, cyc_eop, cyc_mty, throttle);
                if (throttle) idle_cycles(2);
                seg_in_cycle = 0;
                cyc_dat = '0; cyc_ena = '0; cyc_sop = '0; cyc_eop = '0; cyc_mty = '0;
            end
        end
        if (seg_in_cycle != 0)
            send_cycle(cyc_dat, cyc_ena, cyc_sop, cyc_eop, cyc_mty, throttle);
        idle_cycles(40);
    endtask

    task automatic send_cycle(input logic [N_SEG*SEG_W-1:0] dat,
                              input logic [N_SEG-1:0] ena,
                              input logic [N_SEG-1:0] sop,
                              input logic [N_SEG-1:0] eop,
                              input logic [N_SEG*4-1:0] mty,
                              input bit throttle);
        @(negedge clk);
        rx_seg_valid = 1'b1;
        rx_seg_dat = dat;
        rx_seg_ena = ena;
        rx_seg_sop = sop;
        rx_seg_eop = eop;
        rx_seg_mty = mty;
        if (throttle) m_axis_tready = ~m_axis_tready;
        else m_axis_tready = 1'b1;
        @(posedge clk);
        #0.1;
    endtask

    bit throttle_hold = 1'b0;

    task automatic idle_cycles(input int count);
        int index;
        for (index = 0; index < count; index++) begin
            @(negedge clk);
            rx_seg_valid = 1'b0;
            rx_seg_ena = '0;
            rx_seg_sop = '0;
            rx_seg_eop = '0;
            if (!throttle_hold) m_axis_tready = 1'b1;
            else m_axis_tready = ~m_axis_tready;
            @(posedge clk);
            #0.1;
        end
    endtask

    always @(posedge clk) begin
        int index;
        byte unsigned expected[$];
        if (rstn && m_axis_tvalid && m_axis_tready) begin
            for (index = 0; index < BEAT_B; index++)
                if (m_axis_tkeep[index]) got_frame.push_back(m_axis_tdata[index*8 +: 8]);
            if (m_axis_tlast) begin
                frames_seen++;
                if (got_index < frames.size()) begin
                    expected = frames[got_index];
                    if (expected.size() != got_frame.size()) begin
                        mismatches++;
                        $display("FRAME %0d size %0d expected %0d", got_index, got_frame.size(),
                                 expected.size());
                    end else begin
                        for (index = 0; index < expected.size(); index++)
                            if (expected[index] !== got_frame[index]) begin
                                mismatches++;
                                $display("FRAME %0d byte %0d got %02x expected %02x", got_index,
                                         index, got_frame[index], expected[index]);
                                break;
                            end
                    end
                end else begin
                    mismatches++;
                    $display("FRAME %0d beyond the driven set", got_index);
                end
                got_index++;
                got_frame.delete();
            end
        end
    end

    task automatic record(input string name, input bit condition, input string detail);
        tests++;
        if (condition) begin
            passes++;
            $display("TEST %-46s PASS  %s", name, detail);
        end else begin
            failures++;
            $display("TEST %-46s FAIL  %s", name, detail);
        end
    endtask

    task automatic reset_dut();
        rstn = 1'b0;
        rx_seg_valid = 1'b0;
        rx_seg_ena = '0; rx_seg_sop = '0; rx_seg_eop = '0; rx_seg_err = '0; rx_seg_mty = '0;
        m_axis_tready = 1'b1;
        frames.delete(); lengths.delete(); got_frame.delete();
        got_index = 0; frames_seen = 0; mismatches = 0;
        repeat (6) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    task automatic run_case(input string name, input bit pack_tight, input bit throttle);
        int expected_frames;
        reset_dut();
        throttle_hold = throttle;
        build_frame(16, 8'h10);
        build_frame(20, 8'h20);
        build_frame(48, 8'h30);
        build_frame(64, 8'h40);
        build_frame(65, 8'h50);
        build_frame(100, 8'h60);
        build_frame(128, 8'h70);
        build_frame(129, 8'h80);
        build_frame(512, 8'h90);
        build_frame(1500, 8'ha0);
        expected_frames = frames.size();
        drive_frames(pack_tight, throttle);
        record(name, mismatches == 0 && frames_seen == expected_frames,
               $sformatf("frames=%0d of %0d mismatches=%0d drop=%0b stat=%08x", frames_seen,
                         expected_frames, mismatches, rx_align_drop, rx_align_stat));
    endtask

    initial begin
        $display("TB_IN_REG=%0d", IN_REG);
        run_case("frames_one_per_cycle_group", 1'b0, 1'b0);
        run_case("frames_packed_into_shared_cycles", 1'b1, 1'b0);
        run_case("frames_with_a_throttled_consumer", 1'b0, 1'b1);
        $display("** TESTS=%0d PASS=%0d FAIL=%0d IN_REG=%0d", tests, passes, failures, IN_REG);
        $finish;
    end

endmodule
