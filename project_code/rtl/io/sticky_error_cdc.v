`timescale 1ns/1ps

// One immutable error snapshot per source-reset epoch. This is NOT a
// general-purpose synchronizer for a changing multi-bit bus: src_code is
// captured on the first src_error and held until src_rst_n is asserted.
// Every bit and the valid level cross two FFs; two further destination
// guard cycles precede the atomic publication of code + valid. Downstream
// logic never consumes the unsynchronized source bus or partial snapshot.
module sticky_error_cdc (
    input  wire       src_clk,
    input  wire       src_rst_n,
    input  wire       src_error,
    input  wire [7:0] src_code,
    output reg        src_latched,
    input  wire       dst_clk,
    input  wire       dst_rst_n,
    output reg        dst_valid,
    output reg  [7:0] dst_code
);
    reg [7:0] source_code;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_latched <= 1'b0;
            source_code <= 8'd0;
        end else if (src_error && !src_latched) begin
            source_code <= (src_code != 0) ? src_code : 8'hfe;
            src_latched <= 1'b1;
        end
    end

    wire valid_sync;
    wire [7:0] code_sync;
    sync_2ff u_valid_sync (
        .clk(dst_clk), .rst_n(dst_rst_n),
        .async_in(src_latched), .sync_out(valid_sync)
    );
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin : g_code
            sync_2ff u_sync (
                .clk(dst_clk), .rst_n(dst_rst_n),
                .async_in(source_code[bit_index]), .sync_out(code_sync[bit_index])
            );
        end
    endgenerate

    reg valid_guard1;
    reg valid_guard2;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            valid_guard1 <= 1'b0;
            valid_guard2 <= 1'b0;
            dst_valid <= 1'b0;
            dst_code <= 8'd0;
        end else if (!valid_sync) begin
            valid_guard1 <= 1'b0;
            valid_guard2 <= 1'b0;
            dst_valid <= 1'b0;
            dst_code <= 8'd0;
        end else begin
            valid_guard1 <= 1'b1;
            valid_guard2 <= valid_guard1;
            if (valid_guard2 && !dst_valid) begin
                dst_code <= code_sync;
                dst_valid <= 1'b1;
            end
        end
    end
endmodule
