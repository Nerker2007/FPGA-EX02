`timescale 1ns/1ps

module sd_sector_replay_buffer (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output reg         sector_valid,
    output reg  [7:0]  sector_byte,
    output reg  [8:0]  sector_byte_index,
    output reg         sector_done,
    output reg  [7:0]  sector_error,

    output reg         reader_req,
    output reg  [31:0] reader_lba,
    input  wire        reader_busy,
    input  wire        reader_valid,
    input  wire [7:0]  reader_byte,
    input  wire [8:0]  reader_byte_index,
    input  wire        reader_done,
    input  wire [7:0]  reader_error
);
    localparam ERR_CAPTURE_ORDER = 8'he1;
    localparam ST_IDLE    = 3'd0;
    localparam ST_ISSUE   = 3'd1;
    localparam ST_CAPTURE = 3'd2;
    localparam ST_REPLAY  = 3'd3;
    localparam ST_DONE    = 3'd4;

    reg [2:0] state;
    reg [7:0] sector_mem [0:511];
    reg [9:0] captured_count;
    reg [8:0] replay_index;
    reg capture_fault;
    wire current_byte_in_order;
    wire [10:0] captured_count_after;

    assign sector_busy = state != ST_IDLE;
    assign current_byte_in_order = reader_byte_index == captured_count[8:0] &&
                                   captured_count < 10'd512;
    assign captured_count_after = captured_count + (reader_valid ? 1'b1 : 1'b0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            sector_valid <= 1'b0;
            sector_byte <= 8'd0;
            sector_byte_index <= 9'd0;
            sector_done <= 1'b0;
            sector_error <= 8'd0;
            reader_req <= 1'b0;
            reader_lba <= 32'd0;
            captured_count <= 10'd0;
            replay_index <= 9'd0;
            capture_fault <= 1'b0;
        end else begin
            sector_valid <= 1'b0;
            sector_done <= 1'b0;
            reader_req <= 1'b0;

            case (state)
                ST_IDLE: if (sector_req) begin
                    reader_lba <= sector_lba;
                    sector_error <= 8'd0;
                    captured_count <= 10'd0;
                    replay_index <= 9'd0;
                    capture_fault <= 1'b0;
                    state <= ST_ISSUE;
                end
                ST_ISSUE: if (!reader_busy) begin
                    reader_req <= 1'b1;
                    state <= ST_CAPTURE;
                end
                ST_CAPTURE: begin
                    if (reader_valid) begin
                        if (current_byte_in_order)
                            sector_mem[reader_byte_index] <= reader_byte;
                        else
                            capture_fault <= 1'b1;
                        if (captured_count < 10'd513)
                            captured_count <= captured_count + 1'b1;
                    end

                    if (reader_done) begin
                        if (reader_error != 0) begin
                            sector_error <= reader_error;
                            state <= ST_DONE;
                        end else if (capture_fault ||
                                     (reader_valid && !current_byte_in_order) ||
                                     captured_count_after != 11'd512) begin
                            sector_error <= ERR_CAPTURE_ORDER;
                            state <= ST_DONE;
                        end else begin
                            replay_index <= 9'd0;
                            state <= ST_REPLAY;
                        end
                    end
                end
                ST_REPLAY: begin
                    sector_valid <= 1'b1;
                    sector_byte <= sector_mem[replay_index];
                    sector_byte_index <= replay_index;
                    if (replay_index == 9'd511)
                        state <= ST_DONE;
                    else
                        replay_index <= replay_index + 1'b1;
                end
                ST_DONE: begin
                    sector_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
