`timescale 1ns/1ps

module media_ingest_pipeline #(
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output reg                   done,
    output reg  [7:0]            ingest_error,
    output reg  [7:0]            ingest_detail_error,
    output reg  [1:0]            current_image,
    output wire [159:0]          image_res_bcd,
    output wire [3:0]            resource_valid,
    output wire [3:0]            image_complete,

    output wire                  sector_req,
    output wire [31:0]           sector_lba,
    input  wire                  sector_busy,
    input  wire                  sector_valid,
    input  wire [7:0]            sector_byte,
    input  wire [8:0]            sector_byte_index,
    input  wire                  sector_done,
    input  wire [7:0]            sector_error,

    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    localparam integer IMAGE_WORDS = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam ERR_NONE   = 8'h00;
    localparam ERR_SCAN   = 8'h80;
    localparam ERR_FILE   = 8'h82;
    localparam ERR_BMP    = 8'h83;
    localparam ERR_MEMORY = 8'h84;
    localparam integer MIN_WIDTH = 160;
    localparam integer MIN_HEIGHT = 120;

    localparam ST_IDLE      = 3'd0;
    localparam ST_SCAN      = 3'd1;
    localparam ST_FILE_START= 3'd2;
    localparam ST_FILE      = 3'd3;
    localparam ST_FAIL_WAIT = 3'd4;

    reg [2:0] state;
    reg scan_start;
    reg file_start;
    reg load_start;

    wire scan_busy;
    wire scan_done;
    wire [7:0] scan_error;
    wire [7:0] sectors_per_cluster;
    wire [31:0] fat_start_lba;
    wire [31:0] data_start_lba;
    wire [31:0] max_cluster;
    wire [31:0] resource0_cluster, resource1_cluster;
    wire [31:0] resource2_cluster, resource3_cluster;
    wire [31:0] resource0_size, resource1_size;
    wire [31:0] resource2_size, resource3_size;
    wire scan_sector_req;
    wire [31:0] scan_sector_lba;

    wire file_busy;
    wire file_done;
    wire file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0] file_error;
    wire file_sector_req;
    wire [31:0] file_sector_lba;
    wire [31:0] selected_cluster;
    wire [31:0] selected_size;

    wire pixel_valid;
    wire [23:0] pixel_rgb;
    wire pixel_row_last;
    wire frame_commit;
    wire bmp_done;
    wire [7:0] decoder_error;
    wire [7:0] scale_error;
    wire [7:0] bmp_error;
    wire [15:0] img_width;
    wire [15:0] img_height;
    wire scaled_valid;
    wire [23:0] scaled_rgb;
    wire scaled_commit;
    wire loader_ready;
    wire load_busy;
    wire load_done;
    wire [7:0] memory_error;

    assign busy = state != ST_IDLE;
    assign sector_req = scan_sector_req | file_sector_req;
    assign sector_lba = scan_sector_req ? scan_sector_lba : file_sector_lba;

    assign selected_cluster = current_image == 2'd0 ? resource0_cluster :
                              current_image == 2'd1 ? resource1_cluster :
                              current_image == 2'd2 ? resource2_cluster : resource3_cluster;
    assign selected_size = current_image == 2'd0 ? resource0_size :
                           current_image == 2'd1 ? resource1_size :
                           current_image == 2'd2 ? resource2_size : resource3_size;

    fat32_volume_scanner u_volume_scanner (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy),
        .scan_done(scan_done), .fs_error(scan_error), .partition_lba(),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    fat32_file_streamer u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(file_start),
        .first_cluster(selected_cluster), .file_size(selected_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset), .fs_error(file_error),
        .sector_req(file_sector_req), .sector_lba(file_sector_lba),
        .sector_busy(sector_busy), .sector_valid(sector_valid), .sector_byte(sector_byte),
        .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(sector_error)
    );

    wire top_down_w;
    wire header_accepted;
    bmp24_decoder #(
        .MIN_WIDTH(MIN_WIDTH), .MIN_HEIGHT(MIN_HEIGHT)
    ) u_bmp_decoder (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .file_size(selected_size),
        .file_valid(file_valid), .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_end(file_done), .upstream_error(file_error),
        .header_accepted(header_accepted),
        .img_width(img_width), .img_height(img_height),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .pixel_x(), .pixel_y(),
        .row_last(pixel_row_last),
        .frame_commit(frame_commit), .bmp_done(bmp_done), .bmp_error(decoder_error),
        .top_down(top_down_w), .pixel_offset(), .row_stride()
    );

    // Any source size is stretched to IMAGE_WIDTH x IMAGE_HEIGHT here, so the
    // frame loader and the whole display side keep their fixed 640x480 view.
    bmp_scaler #(
        .DST_WIDTH(IMAGE_WIDTH), .DST_HEIGHT(IMAGE_HEIGHT)
    ) u_bmp_scaler (
        .clk(clk), .rst_n(rst_n), .file_start(file_start),
        .img_width(img_width), .img_height(img_height),
        .in_valid(pixel_valid), .in_rgb(pixel_rgb), .in_row_last(pixel_row_last),
        .in_commit(frame_commit), .out_ready(loader_ready),
        .out_valid(scaled_valid), .out_rgb(scaled_rgb), .out_commit(scaled_commit),
        .scale_error(scale_error)
    );
    // Scaler faults (input FIFO overflow 0x39) report through the BMP channel.
    assign bmp_error = decoder_error != 8'h00 ? decoder_error : scale_error;

    // Header sizes of the four pictures, for the status bar (mem_clk domain).
    media_ingest_res_record u_res_record (
        .clk(clk), .rst_n(rst_n), .start(start),
        .header_accepted(header_accepted),
        .img_width(img_width), .img_height(img_height),
        .image_index(current_image), .image_res_bcd(image_res_bcd)
    );

    media_frame_loader #(
        .ADDR_WIDTH(ADDR_WIDTH), .IMAGE_WORDS(IMAGE_WORDS),
        .IMAGE_WIDTH(IMAGE_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH), .STALL_TIMEOUT(STALL_TIMEOUT)
    ) u_frame_loader (
        .clk(clk), .rst_n(rst_n), .load_start(load_start), .image_index(current_image),
        .pixel_valid(scaled_valid), .pixel_rgb(scaled_rgb),
        .top_down(top_down_w), .frame_commit(scaled_commit),
        .decode_error(bmp_error), .pixel_ready(loader_ready),
        .load_busy(load_busy), .load_done(load_done),
        .image_complete(image_complete), .memory_error(memory_error),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;
            ingest_error <= ERR_NONE;
            ingest_detail_error <= ERR_NONE;
            current_image <= 2'd0;
        end else begin
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;

            case (state)
                ST_IDLE: if (start) begin
                    ingest_error <= ERR_NONE;
                    ingest_detail_error <= ERR_NONE;
                    current_image <= 2'd0;
                    scan_start <= 1'b1;
                    state <= ST_SCAN;
                end
                ST_SCAN: if (scan_done) begin
                    if (scan_error != 0) begin
                        ingest_error <= ERR_SCAN;
                        ingest_detail_error <= scan_error;
                        state <= ST_FAIL_WAIT;
                    end else begin
                        current_image <= 2'd0;
                        state <= ST_FILE_START;
                    end
                end
                ST_FILE_START: begin
                    file_start <= 1'b1;
                    load_start <= 1'b1;
                    state <= ST_FILE;
                end
                ST_FILE: if (load_done) begin
                    if (file_error != 0) begin
                        ingest_error <= ERR_FILE;
                        ingest_detail_error <= file_error;
                        state <= ST_FAIL_WAIT;
                    end else if (bmp_error != 0) begin
                        ingest_error <= ERR_BMP;
                        ingest_detail_error <= bmp_error;
                        state <= ST_FAIL_WAIT;
                    end else if (memory_error != 0) begin
                        ingest_error <= ERR_MEMORY;
                        ingest_detail_error <= memory_error;
                        state <= ST_FAIL_WAIT;
                    end else if (current_image == 2'd3) begin
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        current_image <= current_image + 1'b1;
                        state <= ST_FILE_START;
                    end
                end
                ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
