`timescale 1ns/1ps

module hdmi_tmds_eg4_phy (
    input  wire       pixel_clk,
    input  wire       pixel_rst_n,
    input  wire       clk_5x,
    input  wire       clk_5x_rst_n,
    input  wire [9:0] channel0_symbol,
    input  wire [9:0] channel1_symbol,
    input  wire [9:0] channel2_symbol,
    output wire       tmds_clock_p,
    output wire       tmds_data0_p,
    output wire       tmds_data1_p,
    output wire       tmds_data2_p,
    output reg        phase_error
);
    reg [39:0] pixel_symbols;
    reg pixel_toggle;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            pixel_symbols <= {10'b0000011111, 30'd0};
            pixel_toggle <= 1'b0;
        end else begin
            pixel_symbols <= {10'b0000011111, channel2_symbol,
                              channel1_symbol, channel0_symbol};
            pixel_toggle <= !pixel_toggle;
        end
    end

    reg [39:0] symbols_sync1;
    reg [39:0] symbols_sync2;
    reg toggle_sync1;
    reg toggle_sync2;
    reg toggle_sync3;
    wire symbol_load = toggle_sync2 ^ toggle_sync3;
    always @(posedge clk_5x or negedge clk_5x_rst_n) begin
        if (!clk_5x_rst_n) begin
            symbols_sync1 <= 40'd0;
            symbols_sync2 <= 40'd0;
            toggle_sync1 <= 1'b0;
            toggle_sync2 <= 1'b0;
            toggle_sync3 <= 1'b0;
        end else begin
            symbols_sync1 <= pixel_symbols;
            symbols_sync2 <= symbols_sync1;
            toggle_sync1 <= pixel_toggle;
            toggle_sync2 <= toggle_sync1;
            toggle_sync3 <= toggle_sync2;
        end
    end

    wire ready0, ready1, ready2, ready_clock;
    wire pair_valid0, pair_valid1, pair_valid2, pair_valid_clock;
    wire [2:0] pair_index0, pair_index1, pair_index2, pair_index_clock;
    wire unused_n0, unused_n1, unused_n2, unused_n_clock;

    hdmi_tmds_eg4_serializer u_data0 (
        .clk_5x(clk_5x), .rst_n(clk_5x_rst_n),
        .symbol_valid(symbol_load), .symbol_ready(ready0),
        .symbol(symbols_sync2[9:0]), .serial_p(tmds_data0_p),
        .serial_n(unused_n0), .pair_valid(pair_valid0),
        .pair_index(pair_index0)
    );
    hdmi_tmds_eg4_serializer u_data1 (
        .clk_5x(clk_5x), .rst_n(clk_5x_rst_n),
        .symbol_valid(symbol_load), .symbol_ready(ready1),
        .symbol(symbols_sync2[19:10]), .serial_p(tmds_data1_p),
        .serial_n(unused_n1), .pair_valid(pair_valid1),
        .pair_index(pair_index1)
    );
    hdmi_tmds_eg4_serializer u_data2 (
        .clk_5x(clk_5x), .rst_n(clk_5x_rst_n),
        .symbol_valid(symbol_load), .symbol_ready(ready2),
        .symbol(symbols_sync2[29:20]), .serial_p(tmds_data2_p),
        .serial_n(unused_n2), .pair_valid(pair_valid2),
        .pair_index(pair_index2)
    );
    hdmi_tmds_eg4_serializer u_clock (
        .clk_5x(clk_5x), .rst_n(clk_5x_rst_n),
        .symbol_valid(symbol_load), .symbol_ready(ready_clock),
        .symbol(symbols_sync2[39:30]), .serial_p(tmds_clock_p),
        .serial_n(unused_n_clock), .pair_valid(pair_valid_clock),
        .pair_index(pair_index_clock)
    );

    always @(posedge clk_5x or negedge clk_5x_rst_n) begin
        if (!clk_5x_rst_n)
            phase_error <= 1'b0;
        else if (symbol_load &&
                 !(ready0 && ready1 && ready2 && ready_clock))
            phase_error <= 1'b1;
        else if ((pair_valid0 != pair_valid1) ||
                 (pair_valid0 != pair_valid2) ||
                 (pair_valid0 != pair_valid_clock) ||
                 (pair_index0 != pair_index1) ||
                 (pair_index0 != pair_index2) ||
                 (pair_index0 != pair_index_clock))
            phase_error <= 1'b1;
    end
endmodule
