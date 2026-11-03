`timescale 1ns/1ps

// One-clock registered watermark stage for:
//   米醋电子工作室忧郁
//
// The 12-bit row ROM is forced into block RAM. RGB and every video timing
// signal consumed by the HDMI bridge are delayed by the same single clock,
// so DE/X/sync alignment is preserved while the large font mux is removed
// from the pixel critical path.
module brand_watermark_24 #(
    parameter integer WM_X = 488,
    parameter integer WM_Y = 460,
    // Forensic build tag. 8'h00 keeps the pixel output bit-identical to the
    // legacy behaviour. A non-zero tag modulates the blue-channel LSB of the
    // non-glyph pixels inside the watermark box (bit k of the tag lands on
    // box column k mod 8), which is invisible on a display but decodable
    // from any screenshot row inside the box.
    parameter [7:0] BUILD_ID = 8'h00
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    input  wire        overlay_active_in,
    output reg         hsync_out,
    output reg         vsync_out,
    output reg         de_out,
    output reg  [9:0]  pixel_x_out,
    output wire [23:0] rgb_out,
    output wire        overlay_active_out
);
    localparam integer GLYPH_W = 12;
    localparam integer GLYPH_H = 12;
    localparam integer GLYPH_STRIDE = 16;
    localparam integer GLYPH_COUNT = 9;
    localparam integer WM_W = GLYPH_STRIDE * GLYPH_COUNT;
    localparam [9:0] WM_X_R = WM_X;

    reg [11:0] glyph_rom [0:143] /* fehdl force_ram=1, ram_style="bram" */;
    integer init_index;
    initial begin
        for (init_index = 0; init_index < 144; init_index = init_index + 1)
            glyph_rom[init_index] = 12'h000;

        // 米 U+7C73
        glyph_rom[0]=12'h060; glyph_rom[1]=12'h224;
        glyph_rom[2]=12'h128; glyph_rom[3]=12'h128;
        glyph_rom[4]=12'h020; glyph_rom[5]=12'h7FE;
        glyph_rom[6]=12'h0B0; glyph_rom[7]=12'h1A8;
        glyph_rom[8]=12'h326; glyph_rom[9]=12'h622;
        glyph_rom[10]=12'h020;

        // 醋 U+918B
        glyph_rom[12]=12'h014; glyph_rom[13]=12'hFD4;
        glyph_rom[14]=12'h31E; glyph_rom[15]=12'h7D4;
        glyph_rom[16]=12'h77F; glyph_rom[17]=12'h740;
        glyph_rom[18]=12'h7DE; glyph_rom[19]=12'h462;
        glyph_rom[20]=12'h7DE; glyph_rom[21]=12'h462;
        glyph_rom[22]=12'h7FE;

        // 电 U+7535
        glyph_rom[24]=12'h040; glyph_rom[25]=12'h040;
        glyph_rom[26]=12'h7FC; glyph_rom[27]=12'h444;
        glyph_rom[28]=12'h444; glyph_rom[29]=12'h7FC;
        glyph_rom[30]=12'h444; glyph_rom[31]=12'h7FC;
        glyph_rom[32]=12'h440; glyph_rom[33]=12'h042;
        glyph_rom[34]=12'h07E;

        // 子 U+5B50
        glyph_rom[36]=12'h3FC; glyph_rom[37]=12'h018;
        glyph_rom[38]=12'h060; glyph_rom[39]=12'h040;
        glyph_rom[40]=12'h7FE; glyph_rom[41]=12'h040;
        glyph_rom[42]=12'h040; glyph_rom[43]=12'h040;
        glyph_rom[44]=12'h040; glyph_rom[45]=12'h0C0;

        // 工 U+5DE5
        glyph_rom[48]=12'h7FC; glyph_rom[49]=12'h040;
        glyph_rom[50]=12'h040; glyph_rom[51]=12'h040;
        glyph_rom[52]=12'h040; glyph_rom[53]=12'h040;
        glyph_rom[54]=12'h040; glyph_rom[55]=12'h040;
        glyph_rom[56]=12'h7FE;

        // 作 U+4F5C
        glyph_rom[60]=12'h130; glyph_rom[61]=12'h120;
        glyph_rom[62]=12'h27E; glyph_rom[63]=12'h250;
        glyph_rom[64]=12'h690; glyph_rom[65]=12'hE1E;
        glyph_rom[66]=12'h210; glyph_rom[67]=12'h210;
        glyph_rom[68]=12'h21E; glyph_rom[69]=12'h210;
        glyph_rom[70]=12'h210;

        // 室 U+5BA4
        glyph_rom[72]=12'h040; glyph_rom[73]=12'h060;
        glyph_rom[74]=12'h7FE; glyph_rom[75]=12'h402;
        glyph_rom[76]=12'h3FC; glyph_rom[77]=12'h088;
        glyph_rom[78]=12'h3FC; glyph_rom[79]=12'h040;
        glyph_rom[80]=12'h3FC; glyph_rom[81]=12'h040;
        glyph_rom[82]=12'h7FE;

        // 忧 U+5FE7
        glyph_rom[84]=12'h200; glyph_rom[85]=12'h214;
        glyph_rom[86]=12'h214; glyph_rom[87]=12'h6D2;
        glyph_rom[88]=12'h63C; glyph_rom[89]=12'h628;
        glyph_rom[90]=12'h228; glyph_rom[91]=12'h228;
        glyph_rom[92]=12'h228; glyph_rom[93]=12'h24A;
        glyph_rom[94]=12'h28E;

        // 郁 U+90C1
        glyph_rom[96]=12'h100; glyph_rom[97]=12'h11E;
        glyph_rom[98]=12'h7D2; glyph_rom[99]=12'h214;
        glyph_rom[100]=12'h7D4; glyph_rom[101]=12'hE54;
        glyph_rom[102]=12'h3D2; glyph_rom[103]=12'h3D2;
        glyph_rom[104]=12'h252; glyph_rom[105]=12'h254;
        glyph_rom[106]=12'h2D0;
    end

    wire watermark_bounds = de &&
        pixel_x >= WM_X && pixel_x < WM_X + WM_W &&
        pixel_y >= WM_Y && pixel_y < WM_Y + GLYPH_H;
    wire [3:0] glyph_index = (pixel_x - WM_X) >> 4;
    wire [3:0] glyph_col = (pixel_x - WM_X) & 4'hf;
    wire [3:0] glyph_row_index = pixel_y - WM_Y;
    wire [7:0] glyph_base = ({4'b0, glyph_index} << 3) +
                            ({4'b0, glyph_index} << 2);
    wire [7:0] glyph_address = glyph_base + glyph_row_index;

    reg [23:0] rgb_q;
    reg [11:0] glyph_row_q;
    reg [3:0] glyph_col_q;
    reg watermark_bounds_q;
    reg overlay_active_q;
    reg [9:0] box_col_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hsync_out <= 1'b1;
            vsync_out <= 1'b1;
            de_out <= 1'b0;
            pixel_x_out <= 10'd0;
            rgb_q <= 24'd0;
            glyph_row_q <= 12'd0;
            glyph_col_q <= 4'd0;
            watermark_bounds_q <= 1'b0;
            overlay_active_q <= 1'b0;
            box_col_q <= 10'd0;
        end else begin
            hsync_out <= hsync;
            vsync_out <= vsync;
            de_out <= de;
            pixel_x_out <= pixel_x;
            rgb_q <= rgb_in;
            glyph_col_q <= glyph_col;
            watermark_bounds_q <= watermark_bounds && glyph_col < GLYPH_W;
            overlay_active_q <= overlay_active_in;
            box_col_q <= pixel_x - WM_X_R;
            if (watermark_bounds && glyph_col < GLYPH_W)
                glyph_row_q <= glyph_rom[glyph_address];
            else
                glyph_row_q <= 12'd0;
        end
    end

    wire watermark_hit = watermark_bounds_q &&
                         glyph_row_q[11 - glyph_col_q];
    wire id_patch_en = (BUILD_ID != 8'h00) && watermark_bounds_q &&
                       !watermark_hit;
    wire id_bit = BUILD_ID[box_col_q[2:0]];
    assign rgb_out = watermark_hit ? 24'hE8F4FF :
                     (id_patch_en ? {rgb_q[23:8], rgb_q[7:1], id_bit} :
                                    rgb_q);
    assign overlay_active_out = overlay_active_q || watermark_hit;
endmodule
