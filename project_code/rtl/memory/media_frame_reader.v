`timescale 1ns/1ps

module media_frame_reader #(
    parameter integer ADDR_WIDTH = 21,
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 8,
    parameter integer BURST_SIZE = 128,
    parameter integer BURST_GAP_CYCLES = 12
) (
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdram_rd_valid,
    input  wire [31:0]           sdram_rd_data,

    input  wire                  pix_clk,
    input  wire                  pix_rst_n,
    input  wire                  frame_start,
    input  wire [1:0]            active_index,
    input  wire                  pixel_consume,
    output wire [23:0]           pixel_rgb,
    output wire                  pixel_valid,
    output reg                   underflow,

    output reg                   reader_busy,
    output reg                   frame_read_done,
    output reg  [1:0]            reader_index,
    output reg  [7:0]            reader_error
);
    localparam [7:0] ERR_NONE          = 8'h00;
    localparam [7:0] ERR_FRAME_OVERRUN = 8'h61;
    localparam [7:0] ERR_FIFO_OVERFLOW = 8'h62;
    localparam [7:0] ERR_UNDERFLOW     = 8'h63;
    localparam [7:0] ERR_SHORT_FRAME   = 8'h64;
    localparam integer FIFO_COUNT_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);

    reg request_pending_pix;
    reg request_toggle_pix;
    reg [1:0] request_index_pix;
    reg frame_armed_pix;
    reg [ADDR_WIDTH:0] consumed_count_pix;

    reg request_sync1_mem;
    reg request_sync2_mem;
    reg request_seen_mem;
    reg [1:0] index_sync1_mem;
    reg [1:0] index_sync2_mem;
    reg reload_pending_mem;
    reg [2:0] fifo_reset_count_mem;
    reg [21:0] reload_wait_count_mem;
    reg [ADDR_WIDTH:0] issued_count_mem;
    reg [ADDR_WIDTH:0] returned_count_mem;
    reg burst_active_mem;
    reg [ADDR_WIDTH:0] burst_issued_mem;
    reg [ADDR_WIDTH:0] burst_target_mem;
    reg [7:0] burst_gap_count_mem;

    reg [1:0] fifo_release_mem;
    reg [1:0] fifo_release_pix;

    wire fifo_reset_request = !mem_rst_n || !pix_rst_n ||
                              (fifo_reset_count_mem != 0);
    // The inherited FIFO already synchronizes reset release independently
    // in clkw/clkr (asy_w_rst0/1 and asy_r_rst0/1). Its common reset must
    // not depend combinationally on a release FF in the opposite domain.
    // Local enables/prefetch are held for the matching two-clock release.
    wire fifo_reset = fifo_reset_request;
    wire fifo_mem_reset = !fifo_release_mem[1];
    wire fifo_pix_reset = !fifo_release_pix[1];

    always @(posedge mem_clk or posedge fifo_reset_request) begin
        if (fifo_reset_request)
            fifo_release_mem <= 2'b00;
        else
            fifo_release_mem <= {fifo_release_mem[0], 1'b1};
    end
    always @(posedge pix_clk or posedge fifo_reset_request) begin
        if (fifo_reset_request)
            fifo_release_pix <= 2'b00;
        else
            fifo_release_pix <= {fifo_release_pix[0], 1'b1};
    end
    wire fifo_full;
    wire fifo_empty;
    wire fifo_almost_full;
    wire [FIFO_COUNT_W-1:0] fifo_wrusedw;
    wire [31:0] fifo_raw_data;
    wire fifo_raw_valid;
    wire fifo_raw_read_en;
    wire prefetch_valid;
    wire [31:0] prefetch_data;
    wire pixel_pop = pixel_consume && prefetch_valid;
    wire [ADDR_WIDTH:0] inflight_words = issued_count_mem - returned_count_mem;
    wire [ADDR_WIDTH+1:0] reserved_words =
        {{(ADDR_WIDTH+2-FIFO_COUNT_W){1'b0}}, fifo_wrusedw} +
        {{1{1'b0}}, inflight_words};
    wire [ADDR_WIDTH:0] remaining_words = IMAGE_WORDS - issued_count_mem;
    wire [ADDR_WIDTH:0] next_burst_words =
        (remaining_words > BURST_SIZE) ? BURST_SIZE : remaining_words;
    wire [ADDR_WIDTH+2:0] reserved_after_burst =
        {{1{1'b0}}, reserved_words} + {{2{1'b0}}, next_burst_words};
    // The inherited controller uses bounded continuous bursts. busy/refresh
    // are not per-word ready signals, but a new burst must wait until the
    // previous batch has returned, the inter-burst gap elapsed, and the
    // controller is idle/not refreshing. Once admitted, do not split a burst.
    wire start_burst = reader_busy && controller_init_done &&
                       !controller_busy && !refresh_active &&
                       !fifo_mem_reset && !burst_active_mem &&
                       burst_gap_count_mem == 0 &&
                       issued_count_mem < IMAGE_WORDS &&
                       issued_count_mem == returned_count_mem &&
                       reserved_after_burst <= (FIFO_DEPTH - FIFO_MARGIN);
    wire issue_allowed = reader_busy && burst_active_mem && !fifo_mem_reset;

    function [ADDR_WIDTH-1:0] bank_base;
        input [1:0] index;
        begin
            case (index)
                2'd0: bank_base = {ADDR_WIDTH{1'b0}};
                2'd1: bank_base = IMAGE_WORDS;
                2'd2: bank_base = IMAGE_WORDS * 2;
                default: bank_base = IMAGE_WORDS * 3;
            endcase
        end
    endfunction

    // Delay the request by one pixel clock so media_player_control can commit
    // active_index on the frame_start edge before this module captures it.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            request_pending_pix <= 1'b0;
            request_toggle_pix <= 1'b0;
            request_index_pix <= 2'd0;
            frame_armed_pix <= 1'b0;
            consumed_count_pix <= 0;
            underflow <= 1'b0;
        end else begin
            if (frame_start) begin
                underflow <= 1'b0;
                if (frame_armed_pix && consumed_count_pix != IMAGE_WORDS) begin
                    underflow <= 1'b1;
                end
                consumed_count_pix <= 0;
                request_pending_pix <= 1'b1;
            end else if (request_pending_pix) begin
                request_index_pix <= active_index;
                request_toggle_pix <= ~request_toggle_pix;
                request_pending_pix <= 1'b0;
                frame_armed_pix <= 1'b1;
            end

            if (pixel_consume) begin
                if (prefetch_valid)
                    consumed_count_pix <= consumed_count_pix + 1'b1;
                else if (frame_armed_pix)
                    underflow <= 1'b1;
            end
        end
    end

    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            request_sync1_mem <= 1'b0;
            request_sync2_mem <= 1'b0;
            request_seen_mem <= 1'b0;
            index_sync1_mem <= 2'd0;
            index_sync2_mem <= 2'd0;
            reload_pending_mem <= 1'b0;
            reload_wait_count_mem <= 22'd0;
            fifo_reset_count_mem <= 3'd0;
            issued_count_mem <= 0;
            returned_count_mem <= 0;
            burst_active_mem <= 1'b0;
            burst_issued_mem <= 0;
            burst_target_mem <= 0;
            burst_gap_count_mem <= 0;
            app_rd_en <= 1'b0;
            app_rd_addr <= 0;
            reader_busy <= 1'b0;
            frame_read_done <= 1'b0;
            reader_index <= 2'd0;
            reader_error <= ERR_NONE;
        end else begin
            request_sync1_mem <= request_toggle_pix;
            request_sync2_mem <= request_sync1_mem;
            index_sync1_mem <= request_index_pix;
            index_sync2_mem <= index_sync1_mem;
            app_rd_en <= 1'b0;
            frame_read_done <= 1'b0;

            if (fifo_reset_count_mem != 0)
                fifo_reset_count_mem <= fifo_reset_count_mem - 1'b1;
            if (burst_gap_count_mem != 0)
                burst_gap_count_mem <= burst_gap_count_mem - 1'b1;

            if (request_sync2_mem != request_seen_mem) begin
                request_seen_mem <= request_sync2_mem;
                reload_pending_mem <= 1'b1;
                if (reader_busy || issued_count_mem != returned_count_mem) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FRAME_OVERRUN;
                end
            end

            // Reload must not latch index_sync2 at detection time: the toggle
            // and the index leave the pixel domain on the same edge through
            // independent synchronizers, so the detection cycle can still see
            // a stale or half-updated index. Reload happens at least one full
            // mem_clk cycle after detection, by which time index_sync2 has
            // settled, and request_index_pix itself is stable for a whole
            // frame period.
            if (reload_pending_mem && issued_count_mem == returned_count_mem) begin
                reload_pending_mem <= 1'b0;
                reader_index <= index_sync2_mem;
                issued_count_mem <= 0;
                returned_count_mem <= 0;
                burst_active_mem <= 1'b0;
                burst_issued_mem <= 0;
                burst_target_mem <= 0;
                burst_gap_count_mem <= 0;
                fifo_reset_count_mem <= 3'd4;
                reader_busy <= 1'b1;
            end

            // If the SDRAM read stream dies while a reload is waiting for the
            // in-flight drain, the wait would otherwise be silent and
            // permanent. Abort to idle with a visible error code instead.
            // Each subsequent frame re-enters the bounded wait (and re-raises
            // the error) until the stream recovers. The drain guard keeps
            // the abort mutually exclusive with the reload above, which must
            // win when both would fire on the same cycle.
            if (reload_pending_mem && issued_count_mem != returned_count_mem)
                reload_wait_count_mem <= reload_wait_count_mem + 1'b1;
            else
                reload_wait_count_mem <= 22'd0;
            if (reload_pending_mem && issued_count_mem != returned_count_mem &&
                reload_wait_count_mem == 22'h3FFFFF) begin
                reload_pending_mem <= 1'b0;
                reader_busy <= 1'b0;
                burst_active_mem <= 1'b0;
                reader_error <= ERR_SHORT_FRAME;
            end

            if (start_burst) begin
                burst_active_mem <= 1'b1;
                burst_issued_mem <= 0;
                burst_target_mem <= next_burst_words;
            end

            if (issue_allowed) begin
                app_rd_en <= 1'b1;
                app_rd_addr <= bank_base(reader_index) + issued_count_mem[ADDR_WIDTH-1:0];
                issued_count_mem <= issued_count_mem + 1'b1;
                burst_issued_mem <= burst_issued_mem + 1'b1;
                if (burst_issued_mem + 1'b1 == burst_target_mem) begin
                    burst_active_mem <= 1'b0;
                    burst_gap_count_mem <= BURST_GAP_CYCLES;
                end
            end

            // returned_count_mem doubles as the in-flight drain indicator
            // for the reload handshake, so the increment itself stays
            // un-gated; only the FIFO write above and the completion side
            // effects here are qualified by reader_busy to reject orphan
            // returns after an abort.
            if (sdram_rd_valid) begin
                returned_count_mem <= returned_count_mem + 1'b1;
                if (reader_busy && fifo_full) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    reader_error <= ERR_FIFO_OVERFLOW;
                end else if (reader_busy &&
                             returned_count_mem + 1'b1 == IMAGE_WORDS) begin
                    reader_busy <= 1'b0;
                    burst_active_mem <= 1'b0;
                    frame_read_done <= 1'b1;
                end
            end
        end
    end

    rfifo_32_32_512 #(
        .DATA_WIDTH_W(32), .DATA_WIDTH_R(32),
        .ADDR_WIDTH_W(FIFO_COUNT_W), .ADDR_WIDTH_R(FIFO_COUNT_W),
        .AL_FULL_NUM(FIFO_DEPTH-FIFO_MARGIN), .AL_EMPTY_NUM(2),
        .SHOW_AHEAD_EN(1'b0), .OUTREG_EN("NOREG")
    ) u_read_fifo (
        .rst(fifo_reset), .clkw(mem_clk), .clkr(pix_clk),
        .we(sdram_rd_valid && reader_busy && !fifo_mem_reset && !fifo_full),
        .di(sdram_rd_data),
        .re(fifo_raw_read_en), .dout(fifo_raw_data), .valid(fifo_raw_valid),
        .full_flag(fifo_full), .empty_flag(fifo_empty),
        .afull(fifo_almost_full), .aempty(),
        .wrusedw(fifo_wrusedw), .rdusedw()
    );

    fifo_prefetch_2 #(.DATA_WIDTH(32)) u_prefetch (
        .clk(pix_clk), .rst(fifo_pix_reset), .raw_empty(fifo_empty),
        .raw_valid(fifo_raw_valid), .raw_data(fifo_raw_data),
        .raw_read_en(fifo_raw_read_en), .consume(pixel_pop),
        .out_valid(prefetch_valid), .out_empty(), .out_data(prefetch_data)
    );

    assign pixel_rgb = prefetch_data[23:0];
    assign pixel_valid = prefetch_valid;

endmodule
