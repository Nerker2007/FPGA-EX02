`timescale 1ns/1ps

// Pixel mask for the geometric reveal effects started by
// video_fade_transition. Every effect goes from black to the new frame (the
// single SDRAM read port never shows two frames at once), so each pixel is
// either alpha_rgb - the full-brightness new frame pixel, identical to the
// steady display - or black. The session brightness is applied once at the
// end of the overlay chain (video_brightness_scale), not here.
// reveal_style:
//   1 left-to-right wipe: x <  ramp * H_ACT/FADE_FRAMES
//   2 top-to-bottom wipe: y <  ramp * V_ACT/FADE_FRAMES
//   3 diagonal shatter:   (x[7:4] + y[7:4]) mod 16 < level, 16x16 tiles;
//     the 4-bit wrap breaks the diagonal into several shard bands
//     (after the checker-phase wipe in the hx4s20 reference video_osd_overlay)
//   0 fade-in, and any frame with wipe_active=0: alpha_rgb passes through.
// level spreads ramp 0..FADE_FRAMES-1 over 0..15, so it equals ramp at
// FADE_FRAMES=16. Purely combinational; x/y must be aligned with alpha_rgb.
module video_transition_mask #(
    parameter integer FADE_FRAMES = 16,
    parameter integer H_ACT = 640,
    parameter integer V_ACT = 480
) (
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire [4:0]  ramp,
    input  wire        wipe_active,
    input  wire [1:0]  reveal_style,
    input  wire [23:0] alpha_rgb,
    output wire [23:0] rgb_out
);
    localparam integer H_STEP = H_ACT / FADE_FRAMES;
    localparam integer V_STEP = V_ACT / FADE_FRAMES;
    localparam integer LEVEL_STEP = 256 / FADE_FRAMES;

    wire [15:0] h_boundary = ramp * H_STEP;
    wire [15:0] v_boundary = ramp * V_STEP;
    wire [12:0] level_full = ramp * LEVEL_STEP;
    wire [3:0] shatter_level = level_full[7:4];
    wire [3:0] shatter_phase = x[7:4] + y[7:4];

    reg visible;
    always @(*) begin
        case (reveal_style)
            2'd1:    visible = {6'd0, x} < h_boundary;
            2'd2:    visible = {6'd0, y} < v_boundary;
            2'd3:    visible = shatter_phase < shatter_level;
            default: visible = 1'b1;
        endcase
    end

    assign rgb_out = (!wipe_active || visible) ? alpha_rgb : 24'h000000;
endmodule
