`timescale 1ns/1ps

// Streams the pixels of a 24-bit uncompressed BMP in file order (storage
// rows, each left to right). Any size from MIN_WIDTH x MIN_HEIGHT up to
// 65535 x 65535 is accepted; bmp_scaler resizes the stream to the display.
// img_width/img_height/top_down are valid from header_accepted until the
// next file_start. row_last marks the final pixel of every storage row.
module bmp24_decoder #(
    parameter integer MIN_WIDTH = 160,
    parameter integer MIN_HEIGHT = 120
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_end,
    input  wire [7:0]  upstream_error,
    output reg         header_accepted,
    output reg  [15:0] img_width,
    output reg  [15:0] img_height,
    output reg         pixel_valid,
    output reg  [23:0] pixel_rgb,
    output reg  [15:0] pixel_x,
    output reg  [15:0] pixel_y,
    output reg         row_last,
    output reg         frame_commit,
    output reg         bmp_done,
    output reg  [7:0]  bmp_error,
    output reg         top_down,
    output reg  [31:0] pixel_offset,
    output reg  [31:0] row_stride
);
    localparam ERR_NONE        = 8'h00;
    localparam ERR_SIGNATURE   = 8'h31;
    localparam ERR_DIMENSIONS  = 8'h32;
    localparam ERR_PLANES      = 8'h33;
    localparam ERR_BPP         = 8'h34;
    localparam ERR_COMPRESSION = 8'h35;
    localparam ERR_OFFSET      = 8'h36;
    localparam ERR_TRUNCATED   = 8'h37;
    localparam ERR_UPSTREAM    = 8'h38;

    reg [7:0] header [0:53];
    reg decode_enabled;
    // Row bytes: at most 65535*3 = 196605 pixel bytes plus padding.
    reg [17:0] width_bytes;
    reg [17:0] byte_in_row;
    reg [15:0] physical_row;
    reg [1:0] channel_phase;
    reg [7:0] blue_hold;
    reg [7:0] green_hold;
    reg [15:0] x_count;

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {header[offset+1], header[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {header[offset+3], header[offset+2], header[offset+1], header[offset]};
        end
    endfunction

    // The truncation check runs at file_end on the row count (rows ==
    // height), so the header needs no offset + stride * height multiply.
    task validate_header;
        reg [31:0] parsed_width;
        reg signed [31:0] parsed_height;
        reg [31:0] absolute_height;
        reg [31:0] parsed_offset;
        reg [17:0] parsed_width_bytes;
        begin
            parsed_width = le32(18);
            parsed_height = le32(22);
            absolute_height = parsed_height[31] ? (~parsed_height + 1'b1) : parsed_height;
            parsed_offset = le32(10);
            parsed_width_bytes = {parsed_width[15:0], 1'b0} + parsed_width[15:0];
            if (header[0] != "B" || header[1] != "M") begin
                bmp_error <= ERR_SIGNATURE;
                decode_enabled <= 1'b0;
            end else if (parsed_width < MIN_WIDTH || parsed_width[31:16] != 0 ||
                         absolute_height < MIN_HEIGHT || absolute_height[31:16] != 0 ||
                         le32(14) < 40) begin
                bmp_error <= ERR_DIMENSIONS;
                decode_enabled <= 1'b0;
            end else if (le16(26) != 1) begin
                bmp_error <= ERR_PLANES;
                decode_enabled <= 1'b0;
            end else if (le16(28) != 24) begin
                bmp_error <= ERR_BPP;
                decode_enabled <= 1'b0;
            end else if (le32(30) != 0) begin
                bmp_error <= ERR_COMPRESSION;
                decode_enabled <= 1'b0;
            end else if (parsed_offset < 54 || parsed_offset >= file_size) begin
                bmp_error <= ERR_OFFSET;
                decode_enabled <= 1'b0;
            end else if (le32(2) > file_size) begin
                bmp_error <= ERR_TRUNCATED;
                decode_enabled <= 1'b0;
            end else begin
                header_accepted <= 1'b1;
                decode_enabled <= 1'b1;
                top_down <= parsed_height[31];
                pixel_offset <= parsed_offset;
                img_width <= parsed_width[15:0];
                img_height <= absolute_height[15:0];
                width_bytes <= parsed_width_bytes;
                row_stride <= {14'd0, (parsed_width_bytes + 2'd3) & ~18'd3};
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            header_accepted <= 1'b0;
            img_width <= 16'd0;
            img_height <= 16'd0;
            pixel_valid <= 1'b0;
            pixel_rgb <= 24'd0;
            pixel_x <= 16'd0;
            pixel_y <= 16'd0;
            row_last <= 1'b0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;
            bmp_error <= ERR_NONE;
            top_down <= 1'b0;
            pixel_offset <= 32'd0;
            row_stride <= 32'd0;
            decode_enabled <= 1'b0;
            width_bytes <= 18'd0;
            byte_in_row <= 18'd0;
            physical_row <= 16'd0;
            channel_phase <= 2'd0;
            blue_hold <= 8'd0;
            green_hold <= 8'd0;
            x_count <= 16'd0;
        end else begin
            pixel_valid <= 1'b0;
            frame_commit <= 1'b0;
            bmp_done <= 1'b0;

            if (file_start) begin
                header_accepted <= 1'b0;
                bmp_error <= ERR_NONE;
                top_down <= 1'b0;
                pixel_offset <= 32'd0;
                row_stride <= 32'd0;
                decode_enabled <= 1'b0;
                byte_in_row <= 18'd0;
                physical_row <= 16'd0;
                channel_phase <= 2'd0;
                x_count <= 16'd0;
            end

            if (file_valid && file_byte_offset < 54)
                header[file_byte_offset] <= file_byte;

            if (file_valid && file_byte_offset == 53)
                validate_header();

            if (file_valid && decode_enabled && file_byte_offset >= pixel_offset &&
                physical_row < img_height) begin
                if (byte_in_row < width_bytes) begin
                    case (channel_phase)
                        2'd0: begin
                            blue_hold <= file_byte;
                            channel_phase <= 2'd1;
                        end
                        2'd1: begin
                            green_hold <= file_byte;
                            channel_phase <= 2'd2;
                        end
                        default: begin
                            pixel_valid <= 1'b1;
                            pixel_rgb <= {file_byte, green_hold, blue_hold};
                            pixel_x <= x_count;
                            pixel_y <= top_down ? physical_row
                                               : img_height - 1'b1 - physical_row;
                            row_last <= byte_in_row == width_bytes - 1'b1;
                            x_count <= x_count + 1'b1;
                            channel_phase <= 2'd0;
                        end
                    endcase
                end

                if (byte_in_row == row_stride[17:0] - 1'b1) begin
                    byte_in_row <= 18'd0;
                    physical_row <= physical_row + 1'b1;
                    channel_phase <= 2'd0;
                    x_count <= 16'd0;
                end else begin
                    byte_in_row <= byte_in_row + 1'b1;
                end
            end

            if (file_end) begin
                bmp_done <= 1'b1;
                decode_enabled <= 1'b0;
                if (upstream_error != 0) begin
                    bmp_error <= ERR_UPSTREAM;
                end else if (bmp_error == ERR_NONE && header_accepted &&
                             physical_row == img_height) begin
                    frame_commit <= 1'b1;
                end else if (bmp_error == ERR_NONE) begin
                    bmp_error <= ERR_TRUNCATED;
                end
            end
        end
    end
endmodule
