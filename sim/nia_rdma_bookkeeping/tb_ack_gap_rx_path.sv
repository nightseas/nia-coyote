// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views

`timescale 1ps / 1ps

import lynxTypes::*;

module tb_ack_gap_rx_path;

    localparam integer CLK_PERIOD = 2558;
    localparam integer DATA_BITS = AXI_NET_BITS;

    integer fifo_depth = 2048;
    integer resp_beats = 64;
    integer messages = 64;
    integer pattern = 0;
    integer sink_stall_every = 0;
    integer sink_stall_len = 0;

    logic nclk = 1'b0;
    logic nresetn = 1'b0;

    integer failures = 0;

    always #(CLK_PERIOD/2) nclk = ~nclk;

    AXI4S #(.AXI4S_DATA_BITS(DATA_BITS)) fifo_out (.aclk(nclk), .aresetn(nresetn));
    AXI4S #(.AXI4S_DATA_BITS(DATA_BITS)) enf_out (.aclk(nclk), .aresetn(nresetn));

    ack_gap_enforcer dut (
        .nclk(nclk),
        .nresetn(nresetn),
        .input_stream(fifo_out),
        .output_stream(enf_out)
    );

    logic [DATA_BITS-1:0] mem_data [0:8191];
    logic                 mem_last [0:8191];
    integer wr_ptr = 0;
    integer rd_ptr = 0;
    integer occupancy = 0;

    integer beats_offered = 0;
    integer beats_accepted = 0;
    integer beats_dropped = 0;
    integer frames_offered = 0;
    integer frames_dropped = 0;
    integer beats_drained = 0;
    integer gap_cycles = 0;
    integer peak_occupancy = 0;

    logic sink_ready = 1'b1;

    assign fifo_out.tvalid = (occupancy > 0);
    assign fifo_out.tdata  = (occupancy > 0) ? mem_data[rd_ptr] : '0;
    assign fifo_out.tlast  = (occupancy > 0) ? mem_last[rd_ptr] : 1'b0;
    assign fifo_out.tkeep  = '1;
    assign enf_out.tready  = sink_ready;

    always_ff @(posedge nclk) begin
        if (!nresetn) begin
            rd_ptr <= 0;
        end
        else begin
            if (fifo_out.tvalid && fifo_out.tready) begin
                rd_ptr <= (rd_ptr + 1) % 8192;
                occupancy <= occupancy - 1;
                beats_drained <= beats_drained + 1;
            end
            if (dut.gap_counter != 8'h0) gap_cycles <= gap_cycles + 1;
            if (occupancy > peak_occupancy) peak_occupancy <= occupancy;
        end
    end

    task automatic push_beat(input logic [DATA_BITS-1:0] d, input logic l, output bit taken);
        taken = 1'b0;
        beats_offered = beats_offered + 1;
        if (occupancy < fifo_depth) begin
            mem_data[wr_ptr] = d;
            mem_last[wr_ptr] = l;
            wr_ptr = (wr_ptr + 1) % 8192;
            occupancy = occupancy + 1;
            beats_accepted = beats_accepted + 1;
            taken = 1'b1;
        end
        else begin
            beats_dropped = beats_dropped + 1;
        end
    endtask

    task automatic push_ack();
        logic [DATA_BITS-1:0] d;
        bit taken;
        d = '0;
        d[15:0] = 16'h0245;
        d[231:224] = 8'h11;
        frames_offered = frames_offered + 1;
        push_beat(d, 1'b1, taken);
        if (!taken) frames_dropped = frames_dropped + 1;
        @(posedge nclk);
    endtask

    task automatic push_response(input int beats);
        logic [DATA_BITS-1:0] d;
        bit taken;
        bit lost;
        lost = 1'b0;
        frames_offered = frames_offered + 1;
        for (int b = 0; b < beats; b++) begin
            d = '0;
            d[15:0] = 16'h0245;
            d[231:224] = 8'h04;
            d[255:240] = b[15:0];
            push_beat(d, (b == beats-1), taken);
            if (!taken) lost = 1'b1;
            @(posedge nclk);
        end
        if (lost) frames_dropped = frames_dropped + 1;
    endtask

    task automatic report(input string tag);
        $display("GAPRX STATE %s offered_beats=%0d accepted=%0d dropped_beats=%0d frames_offered=%0d frames_dropped=%0d drained=%0d peak_occ=%0d gap_cycles=%0d",
                 tag, beats_offered, beats_accepted, beats_dropped, frames_offered, frames_dropped,
                 beats_drained, peak_occupancy, gap_cycles);
    endtask

    task automatic check(input string name, input integer got, input integer want);
        if (got === want) begin
            $display("GAPRX RESULT PASS %s", name);
        end
        else begin
            $display("GAPRX RESULT FAIL %s got=%0d want=%0d", name, got, want);
            failures = failures + 1;
        end
    endtask

    task automatic clear_counts();
        beats_offered = 0;
        beats_accepted = 0;
        beats_dropped = 0;
        frames_offered = 0;
        frames_dropped = 0;
        beats_drained = 0;
        gap_cycles = 0;
        peak_occupancy = 0;
        @(posedge nclk);
    endtask

    task automatic drain(input int cycles);
        repeat (cycles) @(posedge nclk);
    endtask

    initial begin
        void'($value$plusargs("fifo_depth=%d", fifo_depth));
        void'($value$plusargs("resp_beats=%d", resp_beats));
        void'($value$plusargs("messages=%d", messages));

        nresetn = 1'b0;
        repeat (8) @(posedge nclk);
        nresetn = 1'b1;
        repeat (4) @(posedge nclk);

        $display("GAPRX CONFIG data_bits=%0d fifo_depth=%0d resp_beats=%0d messages=%0d gap_on_ack=%0d",
                 DATA_BITS, fifo_depth, resp_beats, messages, 8'h10);

        $display("GAPRX CASE 1 acknowledgements only, which is the write direction");
        clear_counts();
        for (int m = 0; m < messages; m++) push_ack();
        drain(messages*40);
        report("acks_only");
        check("write_direction_loses_no_frame", frames_dropped, 0);

        $display("GAPRX CASE 2 read responses only, which triggers no gap");
        clear_counts();
        for (int m = 0; m < messages; m++) push_response(resp_beats);
        drain(messages*resp_beats);
        report("responses_only");
        check("read_direction_loses_no_frame", frames_dropped, 0);
        check("read_direction_spends_no_gap_cycle", gap_cycles, 0);

        $display("GAPRX CASE 3 alternating acknowledgement and response at line rate");
        clear_counts();
        for (int m = 0; m < messages; m++) begin
            push_ack();
            push_response(resp_beats);
        end
        drain(messages*resp_beats);
        report("alternating");
        $display("GAPRX NOTE alternating frames dropped: %0d of %0d offered", frames_dropped, frames_offered);

        $display("GAPRX CASE 4 the gap cost measured per acknowledgement");
        clear_counts();
        push_ack();
        drain(64);
        report("one_ack");
        check("one_acknowledgement_costs_sixteen_gap_cycles", gap_cycles, 16);

        $display("GAPRX CASE 5 a burst of acknowledgements with a shallow buffer");
        clear_counts();
        fifo_depth = 8;
        for (int m = 0; m < 64; m++) begin
            push_ack();
        end
        drain(2048);
        report("shallow_burst");
        $display("GAPRX NOTE shallow buffer frames dropped: %0d of %0d offered", frames_dropped, frames_offered);

        if (failures == 0) begin
            $display("GAPRX RESULT PASS all cases");
        end
        else begin
            $display("GAPRX RESULT FAIL %0d cases", failures);
        end
        $finish;
    end

endmodule
