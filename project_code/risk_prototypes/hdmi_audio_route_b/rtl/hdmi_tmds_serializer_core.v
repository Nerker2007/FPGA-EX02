`timescale 1ns/1ps

module hdmi_tmds_serializer_core (
    input  wire       clk_5x,
    input  wire       rst_n,
    input  wire       symbol_valid,
    output wire       symbol_ready,
    input  wire [9:0] symbol,
    output wire       ddr_rise_bit,
    output wire       ddr_fall_bit,
    output wire       pair_valid,
    output reg  [2:0] pair_index
);
    reg [9:0] shift_reg;
    reg active;

    assign symbol_ready = !active || pair_index == 3'd4;
    assign ddr_rise_bit = active ? shift_reg[0] : 1'b0;
    assign ddr_fall_bit = active ? shift_reg[1] : 1'b0;
    assign pair_valid = active;

    always @(posedge clk_5x or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 10'd0;
            active <= 1'b0;
            pair_index <= 3'd0;
        end else if (!active) begin
            pair_index <= 3'd0;
            if (symbol_valid) begin
                shift_reg <= symbol;
                active <= 1'b1;
            end
        end else if (pair_index == 3'd4) begin
            pair_index <= 3'd0;
            if (symbol_valid) begin
                shift_reg <= symbol;
                active <= 1'b1;
            end else begin
                shift_reg <= 10'd0;
                active <= 1'b0;
            end
        end else begin
            shift_reg <= {2'b00, shift_reg[9:2]};
            pair_index <= pair_index + 1'b1;
        end
    end
endmodule
