`timescale 1ns/1ps

// Stretches the bmp24_decoder pixel stream (any S_W x S_H, storage order) to
// exactly DST_WIDTH x DST_HEIGHT pixels with bilinear interpolation, in the
// same storage order, so media_frame_loader sees the stream it always did.
//
// Mapping (per axis, S source samples, D outputs): output j samples source
// position (j + 0.5) * S / D - 0.5, clamped to the edge samples; weight
// w = floor(frac * 256); out = (a*(256-w) + b*w + 128) >> 8. Horizontal pass
// first (8-bit result), vertical pass over rows in storage order.
//
// No divider: an error accumulator E (units of 1/(2D) source samples) holds
// the distance of the next output from the previous source sample. E starts
// at S+D, drops by 2D per new source sample and rises by 2S per output;
// whenever E < 2D the output lies between the previous and the current
// sample with weight floor(E*128/D) = (E*K) >> 16. A duplicated sample before
// the first and after the last one gives the edge clamp. Matches
// tools/gen_scale_test_bmp.py (dda_1d) bit for bit.
//
// Structure (all mem_clk):
//   input FIFO (absorbs 512-byte sector bursts, 1 byte/clock)
//   -> horizontal pass, writes DST_WIDTH outputs per source row into one of
//      three line buffers
//   -> vertical pass, blends two line buffers, emits rows while out_ready.
// Source row r may only be written after the vertical pass has finished
// source row r-2 (its buffer is then free). out_ready must leave room for
// the 4 pixels in flight (media_frame_loader.pixel_ready does).
module bmp_scaler #(
    parameter integer DST_WIDTH = 640,
    parameter integer DST_HEIGHT = 480,
    parameter integer IN_FIFO_DEPTH = 512
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [15:0] img_width,
    input  wire [15:0] img_height,
    input  wire        in_valid,
    input  wire [23:0] in_rgb,
    input  wire        in_row_last,
    input  wire        in_commit,
    input  wire        out_ready,
    output reg         out_valid,
    output reg  [23:0] out_rgb,
    output reg         out_commit,
    output reg  [7:0]  scale_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h39;

    localparam integer E_W = 18;
    localparam integer K_SHIFT = 16;
    localparam integer K_W = ((1 << K_SHIFT) * 128 + DST_WIDTH - 1) / DST_WIDTH;
    localparam integer K_H = ((1 << K_SHIFT) * 128 + DST_HEIGHT - 1) / DST_HEIGHT;
    localparam integer COL_W = $clog2(DST_WIDTH + 1);
    localparam integer ROW_W = $clog2(DST_HEIGHT + 1);
    localparam integer FIFO_AW = $clog2(IN_FIFO_DEPTH);
    localparam [E_W-1:0] TWO_DW = 2 * DST_WIDTH;
    localparam [E_W-1:0] TWO_DH = 2 * DST_HEIGHT;

    // Weights are only taken while E < 2D, so the low bits of E suffice.
    localparam integer WE_W = $clog2(2 * DST_WIDTH);
    localparam integer HE_W = $clog2(2 * DST_HEIGHT);

    function [7:0] weight_w;
        input [WE_W-1:0] e;
        reg [WE_W+K_SHIFT-1:0] prod;
        begin
            prod = e * K_W;
            weight_w = prod[K_SHIFT+7:K_SHIFT];
        end
    endfunction

    function [7:0] weight_h;
        input [HE_W-1:0] e;
        reg [HE_W+K_SHIFT-1:0] prod;
        begin
            prod = e * K_H;
            weight_h = prod[K_SHIFT+7:K_SHIFT];
        end
    endfunction

    // (b - a) * w for one channel; signed 9 x unsigned 8.
    function signed [17:0] chan_delta;
        input [7:0] a;
        input [7:0] b;
        input [7:0] w;
        begin
            chan_delta = ($signed({1'b0, b}) - $signed({1'b0, a})) *
                         $signed({1'b0, w});
        end
    endfunction

    // (a*256 + delta + 128) >> 8; the sum is always in 0..65408.
    function [7:0] chan_sum;
        input [7:0] a;
        input signed [17:0] delta;
        reg signed [18:0] sum;
        begin
            sum = $signed({3'b000, a, 8'h80}) + delta;
            chan_sum = sum[15:8];
        end
    endfunction

    // ------------------------------------------------------------------
    // Input FIFO: {row_last, rgb}
    // ------------------------------------------------------------------
    reg [24:0] fifo_mem [0:IN_FIFO_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [FIFO_AW-1:0] fifo_wr_ptr;
    reg [FIFO_AW-1:0] fifo_rd_ptr;
    reg [FIFO_AW:0]   fifo_count;
    reg [24:0]        fifo_q;
    wire              fifo_pop;
    wire              fifo_push = in_valid && fifo_count != IN_FIFO_DEPTH;

    always @(posedge clk) begin
        if (fifo_push)
            fifo_mem[fifo_wr_ptr] <= {in_row_last, in_rgb};
        if (fifo_pop)
            fifo_q <= fifo_mem[fifo_rd_ptr];
    end

    // ------------------------------------------------------------------
    // Line buffers: three DST_WIDTH x 24 RAMs, one write port (horizontal
    // pass) and one read port (vertical pass) each.
    // ------------------------------------------------------------------
    reg [23:0] lb0 [0:DST_WIDTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] lb1 [0:DST_WIDTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] lb2 [0:DST_WIDTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] lb0_q;
    reg [23:0] lb1_q;
    reg [23:0] lb2_q;
    reg              lb_we;
    reg [1:0]        lb_wsel;
    reg [COL_W-1:0]  lb_waddr;
    reg [23:0]       lb_wdata;
    wire [COL_W-1:0] lb_raddr;

    always @(posedge clk) begin
        if (lb_we && lb_wsel == 2'd0) lb0[lb_waddr] <= lb_wdata;
        if (lb_we && lb_wsel == 2'd1) lb1[lb_waddr] <= lb_wdata;
        if (lb_we && lb_wsel == 2'd2) lb2[lb_waddr] <= lb_wdata;
        lb0_q <= lb0[lb_raddr];
        lb1_q <= lb1[lb_raddr];
        lb2_q <= lb2[lb_raddr];
    end

    // ------------------------------------------------------------------
    // Horizontal pass
    // ------------------------------------------------------------------
    localparam [2:0] H_FETCH = 3'd0;
    localparam [2:0] H_LOAD  = 3'd1;
    localparam [2:0] H_EMIT  = 3'd2;
    localparam [2:0] H_DRAIN = 3'd3;

    reg [2:0]       h_state;
    reg [E_W-1:0]   h_e;
    reg [COL_W-1:0] h_j;
    reg             h_first;      // next source pixel starts a row
    reg             h_last;       // current pixel ends its row
    reg             h_virtual;    // stepping past the right edge
    reg [23:0]      h_prev;
    reg [23:0]      h_cur;
    reg [1:0]       h_buf;
    reg [15:0]      rows_filled;  // complete source rows in line buffers
    reg [1:0]       h_drain;
    reg [15:0]      v_done;       // vertical source steps finished

    wire h_emit = h_state == H_EMIT && h_j != DST_WIDTH && h_e < TWO_DW;
    // Row rows_filled goes to buffer rows_filled % 3, last read by the
    // vertical step for source row rows_filled - 2.
    wire h_buf_free = rows_filled <= v_done + 1'b1;
    assign fifo_pop = h_state == H_FETCH && fifo_count != 0 &&
                      (!h_first || h_buf_free);

    // Interpolation pipeline: stage 1 holds the pair and weight, stage 2 the
    // products, stage 3 writes the line buffer.
    reg             h1_valid;
    reg [COL_W-1:0] h1_addr;
    reg [23:0]      h1_a;
    reg [23:0]      h1_b;
    reg [7:0]       h1_w;
    reg             h2_valid;
    reg [COL_W-1:0] h2_addr;
    reg [23:0]      h2_a;
    reg signed [17:0] h2_dr;
    reg signed [17:0] h2_dg;
    reg signed [17:0] h2_db;

    // ------------------------------------------------------------------
    // Vertical pass
    // ------------------------------------------------------------------
    localparam [2:0] V_WAIT   = 3'd0;
    localparam [2:0] V_CHECK  = 3'd1;
    localparam [2:0] V_ROW    = 3'd2;
    localparam [2:0] V_FINISH = 3'd3;
    localparam [2:0] V_DONE   = 3'd4;

    reg [2:0]       v_state;
    reg [E_W-1:0]   v_e;
    reg [ROW_W-1:0] v_j;
    reg [COL_W-1:0] v_col;
    reg [1:0]       v_prev_buf;
    reg [1:0]       v_cur_buf;
    reg             v_virtual;
    reg [7:0]       v_w;
    reg [2:0]       v_drain;
    reg             commit_seen;

    wire v_issue = v_state == V_ROW && out_ready;
    assign lb_raddr = v_col;

    reg             v1_valid;
    reg [1:0]       v1_prev_buf;
    reg [1:0]       v1_cur_buf;
    reg [7:0]       v1_w;
    reg             v2_valid;
    reg [23:0]      v2_a;
    reg signed [17:0] v2_dr;
    reg signed [17:0] v2_dg;
    reg signed [17:0] v2_db;

    wire [23:0] v1_a = v1_prev_buf == 2'd0 ? lb0_q :
                       v1_prev_buf == 2'd1 ? lb1_q : lb2_q;
    wire [23:0] v1_b = v1_cur_buf == 2'd0 ? lb0_q :
                       v1_cur_buf == 2'd1 ? lb1_q : lb2_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= {FIFO_AW{1'b0}};
            fifo_rd_ptr <= {FIFO_AW{1'b0}};
            fifo_count <= {(FIFO_AW+1){1'b0}};
            scale_error <= ERR_NONE;
            h_state <= H_FETCH;
            h_e <= {E_W{1'b0}};
            h_j <= {COL_W{1'b0}};
            h_first <= 1'b1;
            h_last <= 1'b0;
            h_virtual <= 1'b0;
            h_prev <= 24'd0;
            h_cur <= 24'd0;
            h_buf <= 2'd0;
            rows_filled <= 16'd0;
            h_drain <= 2'd0;
            h1_valid <= 1'b0;
            h1_addr <= {COL_W{1'b0}};
            h1_a <= 24'd0;
            h1_b <= 24'd0;
            h1_w <= 8'd0;
            h2_valid <= 1'b0;
            h2_addr <= {COL_W{1'b0}};
            h2_a <= 24'd0;
            h2_dr <= 18'sd0;
            h2_dg <= 18'sd0;
            h2_db <= 18'sd0;
            lb_we <= 1'b0;
            lb_wsel <= 2'd0;
            lb_waddr <= {COL_W{1'b0}};
            lb_wdata <= 24'd0;
            v_state <= V_WAIT;
            v_e <= {E_W{1'b0}};
            v_j <= {ROW_W{1'b0}};
            v_col <= {COL_W{1'b0}};
            v_prev_buf <= 2'd0;
            v_cur_buf <= 2'd0;
            v_virtual <= 1'b0;
            v_w <= 8'd0;
            v_drain <= 3'd0;
            v_done <= 16'd0;
            commit_seen <= 1'b0;
            v1_valid <= 1'b0;
            v1_prev_buf <= 2'd0;
            v1_cur_buf <= 2'd0;
            v1_w <= 8'd0;
            v2_valid <= 1'b0;
            v2_a <= 24'd0;
            v2_dr <= 18'sd0;
            v2_dg <= 18'sd0;
            v2_db <= 18'sd0;
            out_valid <= 1'b0;
            out_rgb <= 24'd0;
            out_commit <= 1'b0;
        end else begin
            out_commit <= 1'b0;

            // ---------------- input FIFO ----------------
            if (fifo_push)
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
            if (in_valid && fifo_count == IN_FIFO_DEPTH && scale_error == ERR_NONE)
                scale_error <= ERR_FIFO_OVERFLOW;

            // ---------------- horizontal pass ----------------
            case (h_state)
                H_FETCH: if (fifo_pop)
                    h_state <= H_LOAD;
                H_LOAD: begin
                    h_cur <= fifo_q[23:0];
                    h_last <= fifo_q[24];
                    if (h_first) begin
                        h_prev <= fifo_q[23:0];
                        h_e <= {2'b00, img_width} + DST_WIDTH;
                        h_first <= 1'b0;
                    end else begin
                        h_e <= h_e - TWO_DW;
                    end
                    h_state <= H_EMIT;
                end
                H_EMIT: begin
                    if (h_emit) begin
                        h_j <= h_j + 1'b1;
                        h_e <= h_e + {img_width, 1'b0};
                    end else if (h_last && !h_virtual) begin
                        // Virtual sample past the right edge = last sample.
                        h_prev <= h_cur;
                        h_e <= h_e - TWO_DW;
                        h_virtual <= 1'b1;
                    end else if (h_virtual) begin
                        h_drain <= 2'd3;
                        h_state <= H_DRAIN;
                    end else begin
                        h_prev <= h_cur;
                        h_state <= H_FETCH;
                    end
                end
                H_DRAIN: begin
                    // Wait for the last outputs to reach the line buffer.
                    if (h_drain != 0) begin
                        h_drain <= h_drain - 1'b1;
                    end else begin
                        rows_filled <= rows_filled + 1'b1;
                        h_buf <= h_buf == 2'd2 ? 2'd0 : h_buf + 1'b1;
                        h_j <= {COL_W{1'b0}};
                        h_first <= 1'b1;
                        h_virtual <= 1'b0;
                        h_state <= H_FETCH;
                    end
                end
                default: h_state <= H_FETCH;
            endcase

            h1_valid <= h_emit;
            h1_addr <= h_j;
            h1_a <= h_prev;
            h1_b <= h_cur;
            h1_w <= weight_w(h_e[WE_W-1:0]);

            h2_valid <= h1_valid;
            h2_addr <= h1_addr;
            h2_a <= h1_a;
            h2_dr <= chan_delta(h1_a[23:16], h1_b[23:16], h1_w);
            h2_dg <= chan_delta(h1_a[15:8], h1_b[15:8], h1_w);
            h2_db <= chan_delta(h1_a[7:0], h1_b[7:0], h1_w);

            lb_we <= h2_valid;
            lb_wsel <= h_buf;
            lb_waddr <= h2_addr;
            lb_wdata <= {chan_sum(h2_a[23:16], h2_dr), chan_sum(h2_a[15:8], h2_dg),
                         chan_sum(h2_a[7:0], h2_db)};

            // ---------------- vertical pass ----------------
            if (in_commit)
                commit_seen <= 1'b1;

            case (v_state)
                V_WAIT: begin
                    if (v_done == img_height && rows_filled == img_height &&
                        img_height != 16'd0) begin
                        // Virtual row past the last one = last row.
                        v_prev_buf <= v_cur_buf;
                        v_e <= v_e - TWO_DH;
                        v_virtual <= 1'b1;
                        v_state <= V_CHECK;
                    end else if (rows_filled > v_done) begin
                        if (v_done == 16'd0) begin
                            v_prev_buf <= 2'd0;
                            v_cur_buf <= 2'd0;
                            v_e <= {2'b00, img_height} + DST_HEIGHT;
                        end else begin
                            v_prev_buf <= v_cur_buf;
                            v_cur_buf <= v_cur_buf == 2'd2 ? 2'd0 : v_cur_buf + 1'b1;
                            v_e <= v_e - TWO_DH;
                        end
                        v_state <= V_CHECK;
                    end
                end
                V_CHECK: begin
                    if (v_j != DST_HEIGHT && v_e < TWO_DH) begin
                        v_w <= weight_h(v_e[HE_W-1:0]);
                        v_col <= {COL_W{1'b0}};
                        v_state <= V_ROW;
                    end else begin
                        v_done <= v_done + 1'b1;
                        v_state <= v_virtual ? V_FINISH : V_WAIT;
                    end
                end
                V_ROW: if (v_issue) begin
                    if (v_col == DST_WIDTH - 1) begin
                        v_j <= v_j + 1'b1;
                        v_e <= v_e + {img_height, 1'b0};
                        v_state <= V_CHECK;
                    end
                    v_col <= v_col + 1'b1;
                end
                V_FINISH: begin
                    // Let the last row leave the pipeline, then commit once
                    // the decoder has confirmed the whole file.
                    if (v_drain != 3'd7) begin
                        v_drain <= v_drain + 1'b1;
                    end else if (commit_seen || in_commit) begin
                        out_commit <= 1'b1;
                        v_state <= V_DONE;
                    end
                end
                default: ;
            endcase

            v1_valid <= v_issue;
            v1_prev_buf <= v_prev_buf;
            v1_cur_buf <= v_cur_buf;
            v1_w <= v_w;

            v2_valid <= v1_valid;
            v2_a <= v1_a;
            v2_dr <= chan_delta(v1_a[23:16], v1_b[23:16], v1_w);
            v2_dg <= chan_delta(v1_a[15:8], v1_b[15:8], v1_w);
            v2_db <= chan_delta(v1_a[7:0], v1_b[7:0], v1_w);

            out_valid <= v2_valid;
            out_rgb <= {chan_sum(v2_a[23:16], v2_dr), chan_sum(v2_a[15:8], v2_dg),
                        chan_sum(v2_a[7:0], v2_db)};

            if (file_start) begin
                fifo_wr_ptr <= {FIFO_AW{1'b0}};
                fifo_rd_ptr <= {FIFO_AW{1'b0}};
                fifo_count <= {(FIFO_AW+1){1'b0}};
                scale_error <= ERR_NONE;
                h_state <= H_FETCH;
                h_j <= {COL_W{1'b0}};
                h_first <= 1'b1;
                h_virtual <= 1'b0;
                h_buf <= 2'd0;
                rows_filled <= 16'd0;
                h1_valid <= 1'b0;
                h2_valid <= 1'b0;
                lb_we <= 1'b0;
                v_state <= V_WAIT;
                v_j <= {ROW_W{1'b0}};
                v_virtual <= 1'b0;
                v_drain <= 3'd0;
                v_done <= 16'd0;
                commit_seen <= 1'b0;
                v1_valid <= 1'b0;
                v2_valid <= 1'b0;
                out_valid <= 1'b0;
            end
        end
    end
endmodule
