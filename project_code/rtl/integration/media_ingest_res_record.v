`timescale 1ns/1ps

// Remembers the BMP header size of the four pictures for the status bar, in
// the mem_clk domain. bmp24_decoder raises header_accepted together with the
// parsed img_width / img_height and keeps them until the next file_start;
// media_ingest_pipeline loads pictures 0..3 in turn and says which one via
// image_index. On every rising edge of header_accepted the width and height
// are latched and converted to five packed BCD digits each by a double-dabble
// shifter (one binary bit per clock, 16 clocks; the next header is millions
// of clocks later). The result is stored at the picture's own index:
//   image_res_bcd[40n+39:40n] = {height BCD, width BCD} of picture n
// A width of 0 means that picture was never parsed, so the bar draws nothing.
// start (a new ingest run) clears the whole table.
//
// The conversion is done here, in the slow domain, rather than next to the
// bar: dividing by ten in the pixel domain would cost far more logic.
module media_ingest_res_record (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire         header_accepted,
    input  wire [15:0]  img_width,
    input  wire [15:0]  img_height,
    input  wire [1:0]   image_index,
    output wire [159:0] image_res_bcd
);
    reg [159:0] res_table;
    reg hdr_q;
    reg busy;
    reg [3:0] step;          // 0..15: one binary bit shifted in per clock
    reg [1:0] cap_index;
    reg [15:0] bin_w, bin_h;
    reg [19:0] bcd_w, bcd_h;

    wire hdr_rise = header_accepted && !hdr_q;

    // Double dabble: a digit of 5..9 gets 3 added before it is doubled, so
    // the doubled nibble stays a valid decimal digit and the carry it
    // generates moves into the next digit. Each correction is at most 9+3,
    // which still fits its nibble, so the nibbles never carry into each
    // other and the five adds can be summed in one expression.
    function [19:0] dbl_dab;
        input [19:0] v;
        reg [19:0] c;
        begin
            c = v;
            if (v[3:0] >= 4'd5)   c = c + 20'h00003;
            if (v[7:4] >= 4'd5)   c = c + 20'h00030;
            if (v[11:8] >= 4'd5)  c = c + 20'h00300;
            if (v[15:12] >= 4'd5) c = c + 20'h03000;
            if (v[19:16] >= 4'd5) c = c + 20'h30000;
            dbl_dab = c;
        end
    endfunction

    wire [19:0] dbl_w = dbl_dab(bcd_w);
    wire [19:0] dbl_h = dbl_dab(bcd_h);
    wire [19:0] bcd_w_next = {dbl_w[18:0], bin_w[15]};
    wire [19:0] bcd_h_next = {dbl_h[18:0], bin_h[15]};
    wire [15:0] bin_w_next = {bin_w[14:0], 1'b0};
    wire [15:0] bin_h_next = {bin_h[14:0], 1'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_table <= 160'd0;
            hdr_q <= 1'b0;
            busy <= 1'b0;
            step <= 4'd0;
            cap_index <= 2'd0;
            bin_w <= 16'd0;
            bin_h <= 16'd0;
            bcd_w <= 20'd0;
            bcd_h <= 20'd0;
        end else begin
            hdr_q <= header_accepted;

            if (start) begin
                res_table <= 160'd0;
                busy <= 1'b0;
            end else if (hdr_rise && !busy) begin
                bin_w <= img_width;
                bin_h <= img_height;
                bcd_w <= 20'd0;
                bcd_h <= 20'd0;
                cap_index <= image_index;
                busy <= 1'b1;
                step <= 4'd0;
            end else if (busy) begin
                if (step == 4'd15) begin
                    case (cap_index)
                        2'd0: res_table[39:0] <= {bcd_h_next, bcd_w_next};
                        2'd1: res_table[79:40] <= {bcd_h_next, bcd_w_next};
                        2'd2: res_table[119:80] <= {bcd_h_next, bcd_w_next};
                        default: res_table[159:120] <= {bcd_h_next, bcd_w_next};
                    endcase
                    busy <= 1'b0;
                end else begin
                    bcd_w <= bcd_w_next;
                    bcd_h <= bcd_h_next;
                    bin_w <= bin_w_next;
                    bin_h <= bin_h_next;
                    step <= step + 1'b1;
                end
            end
        end
    end

    assign image_res_bcd = res_table;
endmodule
