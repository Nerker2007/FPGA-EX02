`timescale 1ns/1ps

// Session brightness, applied once to the whole final picture.
//
// The picture (SDRAM frame), the spectrum bars, the subtitle text and the
// status bar are all drawn at full brightness by the stages above; this stage
// sits at the very end of the overlay chain, so every displayed pixel goes
// through the same scale factor. Scaling earlier (inside the video pipeline)
// only dimmed the picture and left the hard-coded overlay colours at full
// brightness.
//
// Factor: (brightness + 1) / 256, i.e. 256 / 193 / 129 / 65 for the four KEY3
// steps. The +1 keeps the brightest step bit-exact (256/256 = 1.0), so the
// full-brightness picture is unchanged from before this stage existed.
// Per channel: out = (in * (brightness + 1)) >> 8.
//
// brightness crosses into this clock domain bit by bit through per-bit
// synchronizers, so the sampled word can briefly hold a code that is not one
// of the four steps (different synchronizer flops resolving on either side of
// a clock edge). It is therefore latched into bright_f only at frame start
// AND only when it equals its value one clock earlier. That keeps one whole
// frame on one factor and never shows an intermediate code.
//
// Residual case: if a metastable event happens to coincide exactly with a
// frame start, one frame can take a mixed code. The condition re-evaluates
// every frame, so the following frame is already back on a real step.
//
// The pixel path itself is purely combinational (no extra pixel delay); only
// the factor register is clocked.
module video_brightness_scale #(
    parameter [7:0] DEFAULT_BRIGHTNESS = 8'd255
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire [7:0]  brightness,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    reg vs_q;
    reg [7:0] bright_q;
    reg [7:0] bright_f;

    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b1;
            bright_q <= DEFAULT_BRIGHTNESS;
            bright_f <= DEFAULT_BRIGHTNESS;
        end else begin
            vs_q <= vsync;
            bright_q <= brightness;
            if (frame_start && (brightness == bright_q))
                bright_f <= brightness;
        end
    end

    wire [8:0] eff = {1'b0, bright_f} + 9'd1;
    wire [16:0] mul_r = {9'd0, rgb_in[23:16]} * eff;
    wire [16:0] mul_g = {9'd0, rgb_in[15:8]}  * eff;
    wire [16:0] mul_b = {9'd0, rgb_in[7:0]}   * eff;

    assign rgb_out = {mul_r[15:8], mul_g[15:8], mul_b[15:8]};
endmodule
