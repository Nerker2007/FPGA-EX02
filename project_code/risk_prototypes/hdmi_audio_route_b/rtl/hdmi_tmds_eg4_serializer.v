`timescale 1ns/1ps

module hdmi_tmds_eg4_serializer (
    input  wire       clk_5x,
    input  wire       rst_n,
    input  wire       symbol_valid,
    output wire       symbol_ready,
    input  wire [9:0] symbol,
    output wire       serial_p,
    output wire       serial_n,
    output wire       pair_valid,
    output wire [2:0] pair_index
);
    wire rise_bit;
    wire fall_bit;

    hdmi_tmds_serializer_core u_core (
        .clk_5x(clk_5x), .rst_n(rst_n),
        .symbol_valid(symbol_valid), .symbol_ready(symbol_ready),
        .symbol(symbol), .ddr_rise_bit(rise_bit),
        .ddr_fall_bit(fall_bit), .pair_valid(pair_valid),
        .pair_index(pair_index)
    );

    EG_LOGIC_ODDR #(
        .ASYNCRST("ENABLE")
    ) u_oddr (
        .q(serial_p),
        .clk(clk_5x),
        .d1(fall_bit),
        .d0(rise_bit),
        .rst(!rst_n)
    );

    assign serial_n = !serial_p;
endmodule
