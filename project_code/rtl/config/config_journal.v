`timescale 1ns/1ps

module config_journal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        load_start,
    input  wire        slot0_present,
    input  wire [31:0] slot0_version,
    input  wire [31:0] slot0_period,
    input  wire [7:0]  slot0_volume,
    input  wire [7:0]  slot0_mode,
    input  wire [15:0] slot0_crc,
    input  wire        slot1_present,
    input  wire [31:0] slot1_version,
    input  wire [31:0] slot1_period,
    input  wire [7:0]  slot1_volume,
    input  wire [7:0]  slot1_mode,
    input  wire [15:0] slot1_crc,
    output reg         load_done,
    output reg         config_valid,
    output reg  [31:0] active_version,
    output reg  [31:0] active_period,
    output reg  [7:0]  active_volume,
    output reg  [7:0]  active_mode,
    input  wire        save_start,
    input  wire [31:0] save_period,
    input  wire [7:0]  save_volume,
    input  wire [7:0]  save_mode,
    output reg         record_ready,
    output reg         target_slot,
    output reg  [31:0] record_version,
    output reg  [31:0] record_period,
    output reg  [7:0]  record_volume,
    output reg  [7:0]  record_mode,
    output reg  [15:0] record_crc
);
    function [15:0] crc16_word;
        input [79:0] payload;
        integer i;
        reg [15:0] crc;
        begin
            crc = 16'hffff;
            for (i = 79; i >= 0; i = i - 1) begin
                if (crc[15] ^ payload[i])
                    crc = {crc[14:0],1'b0} ^ 16'h1021;
                else
                    crc = {crc[14:0],1'b0};
            end
            crc16_word = crc;
        end
    endfunction

    function version_newer;
        input [31:0] candidate;
        input [31:0] reference;
        reg [31:0] delta;
        begin
            delta = candidate - reference;
            version_newer = (candidate != reference) && !delta[31];
        end
    endfunction

    wire slot0_good = slot0_present && slot0_crc ==
                      crc16_word({slot0_version,slot0_period,slot0_volume,slot0_mode});
    wire slot1_good = slot1_present && slot1_crc ==
                      crc16_word({slot1_version,slot1_period,slot1_volume,slot1_mode});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_done<=0; config_valid<=0; active_version<=0; active_period<=0;
            active_volume<=0; active_mode<=0; record_ready<=0; target_slot<=0;
            record_version<=0; record_period<=0; record_volume<=0; record_mode<=0;
            record_crc<=0;
        end else begin
            load_done<=0;
            record_ready<=0;
            if(load_start) begin
                load_done<=1;
                if(slot0_good && (!slot1_good || !version_newer(slot1_version,slot0_version))) begin
                    config_valid<=1; active_version<=slot0_version; active_period<=slot0_period;
                    active_volume<=slot0_volume; active_mode<=slot0_mode;
                end else if(slot1_good) begin
                    config_valid<=1; active_version<=slot1_version; active_period<=slot1_period;
                    active_volume<=slot1_volume; active_mode<=slot1_mode;
                end else begin
                    config_valid<=0; active_version<=0; active_period<=0;
                    active_volume<=0; active_mode<=0;
                end
            end
            if(save_start) begin
                target_slot <= slot0_good && (!slot1_good || !version_newer(slot1_version,slot0_version)) ? 1'b1 : 1'b0;
                record_version <= active_version + 1'b1;
                record_period <= save_period;
                record_volume <= save_volume;
                record_mode <= save_mode;
                record_crc <= crc16_word({active_version + 1'b1,save_period,save_volume,save_mode});
                record_ready <= 1'b1;
            end
        end
    end
endmodule
