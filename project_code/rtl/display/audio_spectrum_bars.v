`timescale 1ns/1ps

// Audio spectrum bar overlay: 16 solid bars (the song's "guzheng strings")
// in a 512 x BAR_H box whose bottom edge sits right above the subtitle band.
// Bar k is drawn in a 32-pixel cell starting at BAR_X + 32k (BAR_W wide, the
// rest of the cell is a gap showing the picture) and grows upwards from the
// box's bottom row.
//
// bar_target (bin k at bits 7k+6..7k, 0..64) comes from
// audio_spectrum_goertzel. Once per frame, during vertical blanking, the
// shown height of each bar rises straight to its target or falls by one
// pixel towards it (fast attack, slow decay), one bar per clock.
// Bars take hues 3 steps apart on a 48-step colour wheel (16 bars span one
// turn); the whole wheel
// advances one step every 8 frames (one turn in 384 frames, ~6.4 s).
// enable is latched at frame start so a bar box never appears or vanishes
// mid-frame. The overlay is combinational like the waveform it replaces: the
// timing bundle passes through untouched and stays aligned downstream.
module audio_spectrum_bars #(
    parameter integer BAR_X = 64,
    parameter integer BAR_Y = 368,
    parameter integer BAR_H = 64,
    parameter integer BAR_W = 24
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,
    input  wire [111:0] bar_target,
    output wire [23:0] rgb_out,
    output wire        bars_active
);
    localparam integer BAR_BOTTOM = BAR_Y + BAR_H - 1;
    localparam [7:0] LEVEL_LO = 8'd32;
    localparam [7:0] LEVEL_HI = 8'd240;

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    reg show;
    reg [6:0] disp [0:15];
    reg [4:0] update_k;            // 16 = idle, 0..15 = bar being updated
    reg [2:0] hue_div;
    reg [5:0] hue_offset;

    wire [6:0] upd_target = bar_target[update_k[3:0]*7 +: 7];
    wire [6:0] upd_disp = disp[update_k[3:0]];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            show <= 1'b0;
            update_k <= 5'd16;
            hue_div <= 3'd0;
            hue_offset <= 6'd0;
            for (i = 0; i < 16; i = i + 1)
                disp[i] <= 7'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                show <= enable;
                update_k <= 5'd0;
                hue_div <= hue_div + 1'b1;
                if (hue_div == 3'd7)
                    hue_offset <= (hue_offset == 6'd47) ? 6'd0 : hue_offset + 1'b1;
            end else if (!update_k[4]) begin
                if (upd_target > upd_disp)
                    disp[update_k[3:0]] <= upd_target;
                else if (upd_disp > upd_target)
                    disp[update_k[3:0]] <= upd_disp - 1'b1;
                update_k <= update_k + 1'b1;
            end
        end
    end

    // Pixel path: which bar cell, inside the bar column, below its height.
    wire [9:0] rel_x = pixel_x - BAR_X[9:0];
    wire [3:0] bar = rel_x[8:5];
    wire [11:0] from_bottom = BAR_BOTTOM - line_y;
    wire in_box = show && de &&
                  pixel_x >= BAR_X && pixel_x < BAR_X + 512 &&
                  line_y >= BAR_Y && line_y <= BAR_BOTTOM;
    wire bar_pixel = in_box && rel_x[4:0] < BAR_W &&
                     from_bottom < {5'd0, disp[bar]};

    // Colour wheel: 6 segments x 8 steps between LEVEL_LO and LEVEL_HI.
    wire [6:0] hue_sum = {1'b0, bar} * 3 + hue_offset;         // 3*bar + offset
    wire [5:0] hue = (hue_sum >= 7'd48) ? hue_sum - 7'd48 : hue_sum[5:0];
    wire [7:0] ramp = {hue[2:0], 4'd0} + {hue[2:0], 3'd0} + {hue[2:0], 1'b0};  // 26*r
    wire [7:0] up = LEVEL_LO + ramp;
    wire [7:0] dn = LEVEL_HI - ramp;
    reg [23:0] bar_rgb;
    always @(*) begin
        case (hue[5:3])
            3'd0:    bar_rgb = {LEVEL_HI, up, LEVEL_LO};
            3'd1:    bar_rgb = {dn, LEVEL_HI, LEVEL_LO};
            3'd2:    bar_rgb = {LEVEL_LO, LEVEL_HI, up};
            3'd3:    bar_rgb = {LEVEL_LO, dn, LEVEL_HI};
            3'd4:    bar_rgb = {up, LEVEL_LO, LEVEL_HI};
            default: bar_rgb = {LEVEL_HI, LEVEL_LO, dn};
        endcase
    end

    assign bars_active = bar_pixel;
    assign rgb_out = bar_pixel ? bar_rgb : rgb_in;
endmodule
