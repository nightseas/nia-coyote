// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps

module tb_host_networking_prefilter;

    localparam int DATA_BYTES = 64;
    localparam int DATA_BITS = DATA_BYTES * 8;

    logic nclk = 1'b0;
    logic nresetn = 1'b0;

    logic [DATA_BITS-1:0]  rx_tdata = '0;
    logic [DATA_BYTES-1:0] rx_tkeep = '0;
    logic                  rx_tlast = 1'b0;
    logic                  rx_tvalid = 1'b0;
    logic                  rx_tready;

    logic [DATA_BITS-1:0]  host_tdata;
    logic [DATA_BYTES-1:0] host_tkeep;
    logic                  host_tlast;
    logic                  host_tvalid;
    logic                  host_tready = 1'b0;

    logic [DATA_BITS-1:0]  offloaded_tdata;
    logic [DATA_BYTES-1:0] offloaded_tkeep;
    logic                  offloaded_tlast;
    logic                  offloaded_tvalid;
    logic                  offloaded_tready = 1'b0;

    always #2 nclk = ~nclk;

    host_networking_prefilter_flat #(.DATA_BITS(DATA_BITS)) dut (
        .nclk             (nclk),
        .nresetn          (nresetn),
        .rx_tdata         (rx_tdata),
        .rx_tkeep         (rx_tkeep),
        .rx_tlast         (rx_tlast),
        .rx_tvalid        (rx_tvalid),
        .rx_tready        (rx_tready),
        .host_tdata       (host_tdata),
        .host_tkeep       (host_tkeep),
        .host_tlast       (host_tlast),
        .host_tvalid      (host_tvalid),
        .host_tready      (host_tready),
        .offloaded_tdata  (offloaded_tdata),
        .offloaded_tkeep  (offloaded_tkeep),
        .offloaded_tlast  (offloaded_tlast),
        .offloaded_tvalid (offloaded_tvalid),
        .offloaded_tready (offloaded_tready)
    );

    byte unsigned tx_frame[$];
    byte unsigned expect_host[$];
    byte unsigned expect_offloaded[$];
    byte unsigned got_host[$];
    byte unsigned got_offloaded[$];

    logic [DATA_BITS-1:0]  pending_data[$];
    logic [DATA_BYTES-1:0] pending_keep[$];
    logic                  pending_last[$];

    int tests = 0;
    int passes = 0;
    int failures = 0;
    string failed_names = "";

    task automatic build_ethernet(input logic [15:0] ethertype, input int length);
        int index;
        tx_frame.delete();
        for (index = 0; index < length; index++) tx_frame.push_back(8'h00);
        tx_frame[0] = 8'h00; tx_frame[1] = 8'h0a; tx_frame[2] = 8'h35;
        tx_frame[3] = 8'h02; tx_frame[4] = 8'h9d; tx_frame[5] = 8'he5;
        tx_frame[6] = 8'h00; tx_frame[7] = 8'h0a; tx_frame[8] = 8'h35;
        tx_frame[9] = 8'h02; tx_frame[10] = 8'h9d; tx_frame[11] = 8'he6;
        tx_frame[12] = ethertype[15:8];
        tx_frame[13] = ethertype[7:0];
    endtask

    task automatic build_ipv4_udp(input logic [15:0] dest_port, input int length,
                                  input byte unsigned tag);
        int index;
        build_ethernet(16'h0800, length);
        tx_frame[14] = 8'h45;
        tx_frame[23] = 8'h11;
        tx_frame[36] = dest_port[15:8];
        tx_frame[37] = dest_port[7:0];
        for (index = 42; index < length; index++) tx_frame[index] = byte'(tag + index);
    endtask

    task automatic build_ipv4_tcp(input int length, input byte unsigned tag);
        int index;
        build_ethernet(16'h0800, length);
        tx_frame[14] = 8'h45;
        tx_frame[23] = 8'h06;
        for (index = 34; index < length; index++) tx_frame[index] = byte'(tag + index);
    endtask

    task automatic build_arp();
        build_ethernet(16'h0806, 60);
        tx_frame[15] = 8'h01;
        tx_frame[21] = 8'h01;
    endtask

    task automatic queue_frame();
        int offset;
        int count;
        int index;
        logic [DATA_BITS-1:0] data;
        logic [DATA_BYTES-1:0] keep;
        for (offset = 0; offset < tx_frame.size(); offset += DATA_BYTES) begin
            count = tx_frame.size() - offset;
            if (count > DATA_BYTES) count = DATA_BYTES;
            data = '0;
            keep = '0;
            for (index = 0; index < count; index++) begin
                data[index*8 +: 8] = tx_frame[offset + index];
                keep[index] = 1'b1;
            end
            pending_data.push_back(data);
            pending_keep.push_back(keep);
            pending_last.push_back((offset + DATA_BYTES) >= tx_frame.size());
        end
    endtask

    task automatic expect_on_host();
        int index;
        for (index = 0; index < tx_frame.size(); index++) expect_host.push_back(tx_frame[index]);
    endtask

    task automatic expect_on_offloaded();
        int index;
        for (index = 0; index < tx_frame.size(); index++)
            expect_offloaded.push_back(tx_frame[index]);
    endtask

    task automatic reset_bench();
        pending_data.delete(); pending_keep.delete(); pending_last.delete();
        got_host.delete(); got_offloaded.delete();
        expect_host.delete(); expect_offloaded.delete();
        rx_tvalid = 1'b0; rx_tlast = 1'b0; rx_tdata = '0; rx_tkeep = '0;
        host_tready = 1'b0; offloaded_tready = 1'b0;
        nresetn = 1'b0;
        repeat (4) @(posedge nclk);
        nresetn = 1'b1;
        @(posedge nclk);
    endtask

    task automatic cycle(output bit accepted);
        int index;
        @(negedge nclk);
        if (pending_data.size() > 0) begin
            rx_tdata = pending_data[0];
            rx_tkeep = pending_keep[0];
            rx_tlast = pending_last[0];
            rx_tvalid = 1'b1;
        end else begin
            rx_tvalid = 1'b0;
            rx_tlast = 1'b0;
        end
        #1;
        accepted = (pending_data.size() > 0) && (rx_tready === 1'b1);
`ifdef PREFILTER_TRACE
        $display("CYC t=%0t in_v=%0b in_r=%0b h_v=%0b h_r=%0b o_v=%0b o_r=%0b h_taken=%0b o_taken=%0b rh=%0b ro=%0b fur=%0b",
                 $time, rx_tvalid, rx_tready, host_tvalid, host_tready, offloaded_tvalid,
                 offloaded_tready, dut.prefilter.rx_host_chunk_taken,
                 dut.prefilter.rx_offloaded_chunk_taken, dut.prefilter.rx_route_host,
                 dut.prefilter.rx_route_offloaded, dut.prefilter.rx_pkt_further_chunks);
`endif
        if (host_tvalid === 1'b1 && host_tready === 1'b1) begin
            for (index = 0; index < DATA_BYTES; index++)
                if (host_tkeep[index]) got_host.push_back(host_tdata[index*8 +: 8]);
`ifdef PREFILTER_TRACE
            $display("TRACE host t=%0t taken=%0b route=%0b further=%0b in_ready=%0b last=%0b",
                     $time, dut.prefilter.rx_host_chunk_taken, dut.prefilter.rx_route_host,
                     dut.prefilter.rx_pkt_further_chunks, rx_tready, rx_tlast);
`endif
        end
        if (offloaded_tvalid === 1'b1 && offloaded_tready === 1'b1)
            for (index = 0; index < DATA_BYTES; index++)
                if (offloaded_tkeep[index]) got_offloaded.push_back(offloaded_tdata[index*8 +: 8]);
        if (accepted) begin
            void'(pending_data.pop_front());
            void'(pending_keep.pop_front());
            void'(pending_last.pop_front());
        end
        @(posedge nclk);
        #1;
    endtask

    task automatic run_cycles(input int count);
        bit accepted;
        int index;
        for (index = 0; index < count; index++) cycle(accepted);
    endtask

    task automatic drain(input int limit, output bit drained);
        bit accepted;
        int index;
        drained = 1'b0;
        for (index = 0; index < limit; index++) begin
            if (pending_data.size() == 0) begin
                run_cycles(2);
                drained = 1'b1;
                return;
            end
            cycle(accepted);
        end
    endtask

    function automatic int first_mismatch(const ref byte unsigned expected[$],
                                          const ref byte unsigned observed[$]);
        int index;
        if (expected.size() != observed.size()) return -2;
        for (index = 0; index < expected.size(); index++)
            if (expected[index] !== observed[index]) return index;
        return -1;
    endfunction

    task automatic record(input string name, input bit condition, input string detail);
        tests++;
        if (condition) begin
            passes++;
            $display("TEST %-58s PASS", name);
        end else begin
            failures++;
            failed_names = {failed_names, " ", name};
            $display("TEST %-58s FAIL  %s", name, detail);
        end
    endtask

    task automatic check_streams(input string name, input bit drained);
        int host_mismatch;
        int offloaded_mismatch;
        string detail;
        host_mismatch = first_mismatch(expect_host, got_host);
        offloaded_mismatch = first_mismatch(expect_offloaded, got_offloaded);
        detail = $sformatf("drained=%0b beats_left=%0d host_bytes=%0d/%0d host_cmp=%0d offloaded_bytes=%0d/%0d offloaded_cmp=%0d",
                           drained, pending_data.size(), got_host.size(), expect_host.size(),
                           host_mismatch, got_offloaded.size(), expect_offloaded.size(),
                           offloaded_mismatch);
        record(name, drained && host_mismatch == -1 && offloaded_mismatch == -1, detail);
    endtask

    initial begin
        bit drained;

        reset_bench();
        host_tready = 1'b0;
        offloaded_tready = 1'b1;
        build_ipv4_udp(16'h12b7, 160, 8'h10);
        queue_frame();
        expect_on_offloaded();
        drain(200, drained);
        check_streams("offloaded_frame_passes_while_the_host_path_is_stalled", drained);

        reset_bench();
        host_tready = 1'b1;
        offloaded_tready = 1'b0;
        build_ipv4_udp(16'h1f90, 160, 8'h20);
        queue_frame();
        expect_on_host();
        drain(200, drained);
        check_streams("host_frame_passes_while_the_offloaded_path_is_stalled", drained);

        reset_bench();
        host_tready = 1'b1;
        offloaded_tready = 1'b0;
        build_arp();
        queue_frame();
        expect_on_host();
        expect_on_offloaded();
        run_cycles(8);
        record("arp_frame_waits_for_the_offloaded_consumer", pending_data.size() == 1,
               $sformatf("beats_left=%0d expected 1", pending_data.size()));
        offloaded_tready = 1'b1;
        drain(60, drained);
        check_streams("arp_frame_reaches_both_consumers", drained);

        reset_bench();
        host_tready = 1'b1;
        offloaded_tready = 1'b1;
        build_ipv4_udp(16'h1f90, 128, 8'h80);
        tx_frame[DATA_BYTES + 12] = 8'h08;
        tx_frame[DATA_BYTES + 13] = 8'h06;
        queue_frame();
        expect_on_host();
        drain(60, drained);
        check_streams("host_frame_payload_does_not_reach_the_offloaded_path", drained);

        reset_bench();
        host_tready = 1'b1;
        offloaded_tready = 1'b1;
        build_ipv4_udp(16'h1f90, 160, 8'h30);
        queue_frame();
        expect_on_host();
        build_ipv4_udp(16'h12b7, 160, 8'h50);
        queue_frame();
        expect_on_offloaded();
        build_ipv4_udp(16'h1f90, 160, 8'h30);
        queue_frame();
        expect_on_host();
        build_ipv4_udp(16'h12b7, 160, 8'h50);
        queue_frame();
        expect_on_offloaded();
        build_ipv4_tcp(160, 8'h40);
        queue_frame();
        expect_on_host();
        drain(300, drained);
        check_streams("alternating_frames_are_classified_per_frame", drained);

        $display("** TESTS=%0d PASS=%0d FAIL=%0d", tests, passes, failures);
        if (failures != 0) $display("** FAILED:%s", failed_names);
        $finish;
    end

endmodule
