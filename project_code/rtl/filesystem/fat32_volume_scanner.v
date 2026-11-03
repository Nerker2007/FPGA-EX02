`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [3:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    reg [3:0] state;
    reg [7:0] sector_buffer [0:511];
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [6:0] root_sector_index;

    assign scan_busy = (state != ST_IDLE);

    function [15:0] le16;
        input integer offset;
        begin
            le16 = {sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function [31:0] le32;
        input integer offset;
        begin
            le32 = {sector_buffer[offset+3], sector_buffer[offset+2],
                    sector_buffer[offset+1], sector_buffer[offset]};
        end
    endfunction

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    function [1:0] matching_resource;
        input integer base;
        begin
            if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                sector_buffer[base+2] == "C" && sector_buffer[base+3] == "1" &&
                sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                sector_buffer[base+10] == "P")
                matching_resource = 2'd0;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "2" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 2'd1;
            else if (sector_buffer[base+0] == "P" && sector_buffer[base+1] == "I" &&
                     sector_buffer[base+2] == "C" && sector_buffer[base+3] == "3" &&
                     sector_buffer[base+8] == "B" && sector_buffer[base+9] == "M" &&
                     sector_buffer[base+10] == "P")
                matching_resource = 2'd2;
            else
                matching_resource = 2'd3;
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task accept_directory_entry;
        input integer base;
        reg [1:0] resource_index;
        reg [31:0] first_cluster;
        reg [31:0] file_size;
        begin
            resource_index = matching_resource(base);
            first_cluster = {sector_buffer[base+21], sector_buffer[base+20],
                             sector_buffer[base+27], sector_buffer[base+26]};
            file_size = le32(base+28);
            case (resource_index)
                2'd0: begin
                    resource0_cluster <= first_cluster;
                    resource0_size <= file_size;
                    resource_valid[0] <= 1'b1;
                end
                2'd1: begin
                    resource1_cluster <= first_cluster;
                    resource1_size <= file_size;
                    resource_valid[1] <= 1'b1;
                end
                2'd2: begin
                    resource2_cluster <= first_cluster;
                    resource2_size <= file_size;
                    resource_valid[2] <= 1'b1;
                end
                default: begin
                    resource3_cluster <= first_cluster;
                    resource3_size <= file_size;
                    resource_valid[3] <= 1'b1;
                end
            endcase
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            root_sector_index <= 7'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid)
                sector_buffer[sector_byte_index] <= sector_byte;

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sector_buffer[0] == 8'heb || sector_buffer[0] == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sector_buffer[450] == 8'h0b || sector_buffer[450] == 8'h0c) begin
                        partition_lba <= le32(454);
                        sector_lba <= le32(454);
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sector_buffer[510] != 8'h55 || sector_buffer[511] != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16(11) != 16'd512 || !valid_spc(sector_buffer[13]) ||
                        le16(14) == 0 || (sector_buffer[16] != 1 && sector_buffer[16] != 2) ||
                        le16(17) != 0 || le16(22) != 0 || le32(32) == 0 ||
                        le32(36) == 0 || le32(44) < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sector_buffer[13];
                        reserved_sectors <= le16(14);
                        fat_count <= sector_buffer[16];
                        total_sectors <= le32(32);
                        fat_sectors <= le32(36);
                        root_cluster <= le32(44);
                        sectors_per_cluster_shift <= spc_shift(sector_buffer[13]);
                        fat_span <= sector_buffer[16] == 2 ? (le32(36) << 1) : le32(36);
                        fat_start_lba <= partition_lba + le16(14);
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    root_sector_index <= 7'd0;
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    if (sector_buffer[directory_entry_index * 32] == 8'h00) begin
                        if (resource_valid == 4'hf)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end else begin
                        if (sector_buffer[directory_entry_index * 32] != 8'he5 &&
                            sector_buffer[directory_entry_index * 32 + 11] == 8'h20 &&
                            sector_buffer[directory_entry_index * 32] == "P" &&
                            sector_buffer[directory_entry_index * 32 + 1] == "I" &&
                            sector_buffer[directory_entry_index * 32 + 2] == "C" &&
                            sector_buffer[directory_entry_index * 32 + 3] >= "1" &&
                            sector_buffer[directory_entry_index * 32 + 3] <= "4" &&
                            sector_buffer[directory_entry_index * 32 + 4] == " " &&
                            sector_buffer[directory_entry_index * 32 + 5] == " " &&
                            sector_buffer[directory_entry_index * 32 + 6] == " " &&
                            sector_buffer[directory_entry_index * 32 + 7] == " " &&
                            sector_buffer[directory_entry_index * 32 + 8] == "B" &&
                            sector_buffer[directory_entry_index * 32 + 9] == "M" &&
                            sector_buffer[directory_entry_index * 32 + 10] == "P")
                            accept_directory_entry(directory_entry_index * 32);

                        if (directory_entry_index == 5'd15) begin
                            if (resource_valid == 4'hf)
                                state <= ST_FINISH;
                            else if (sector_buffer[15 * 32] != 8'h00 &&
                                     ({1'b0, root_sector_index} + 1'b1) <
                                     (8'd1 << sectors_per_cluster_shift)) begin
                                // Entries may continue in the next sector of
                                // the root cluster; keep scanning before
                                // declaring the resources missing.
                                root_sector_index <= root_sector_index + 1'b1;
                                sector_lba <= root_lba +
                                              {25'd0, root_sector_index} + 1'b1;
                                state <= ST_ROOT_REQ;
                            end else
                                finish_with_error(ERR_RESOURCE_MISSING);
                        end else begin
                            directory_entry_index <= directory_entry_index + 1'b1;
                        end
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
