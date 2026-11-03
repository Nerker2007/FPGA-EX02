`timescale 1ns/1ps

module media_player_control #(
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // Playback-mode banks: normal mode only cycles NORMAL_MASK; the bus-stop
    // and emergency switches pin ARRIVE_INDEX / EMERG_INDEX. HOME_INDEX is the
    // fallback when the resume bank is outside the current mode and MUST be
    // a member of NORMAL_MASK.
    parameter [1:0]  ARRIVE_INDEX = 2'd2,
    parameter [1:0]  EMERG_INDEX = 2'd3,
    parameter [1:0]  HOME_INDEX = 2'd0,
    parameter [3:0]  NORMAL_MASK = 4'b0011
) (
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    // Debounced slide-switch levels in the sys_clk domain (1 = on).
    input  wire        demo_mode,
    input  wire        arrive_sw,
    input  wire        emerg_sw,
    input  wire        next_event,
    input  wire        toggle_auto_event,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [3:0]  image_complete,
    output reg         auto_enabled,
    output reg  [31:0] active_period_cycles,
    output reg  [1:0]  pending_index,
    output reg  [7:0]  control_error,
    output wire        request_busy,
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        frame_start,
    output reg  [1:0]  active_index,
    output reg         index_commit,
    // High alongside index_commit when the committed request came from a
    // pinned-bank jump (bus-stop / emergency / restore) rather than KEY2 or
    // the slideshow timer; video_fade_transition uses it to pick the effect.
    output reg         commit_jump
);
    localparam ERR_NONE = 8'h00;
    localparam ERR_PERIOD_RANGE = 8'h51;
    localparam ERR_REQUEST_BUSY = 8'h52;
    localparam ERR_NO_RESOURCE = 8'h53;

    reg [31:0] auto_counter;
    reg [1:0] sys_current_index;
    reg request_toggle;
    reg ack_toggle_pix;
    reg ack_sync1, ack_sync2;
    reg [1:0] index_sync1, index_sync2;
    reg pending_jump;
    reg jump_sync1, jump_sync2;
    reg req_sync1, req_sync2;
    reg req_seen_pix;
    reg commit_pending_pix;

    assign request_busy = request_toggle != ack_sync2;

    // Mode / override levels. Keep `override` in sync with key2_lock in
    // media_player_excellence_top: KEY2 is gated there before the fade so a
    // pinned bank never flashes black.
    reg override_q;
    reg resume_pending;
    reg [1:0] resume_index;
    wire [3:0] allowed_mask = demo_mode ? 4'b1111 : NORMAL_MASK;
    wire [3:0] play_mask = image_complete & allowed_mask;
    wire override = emerg_sw | (arrive_sw & ~demo_mode);
    wire [1:0] override_index = emerg_sw ? EMERG_INDEX : ARRIVE_INDEX;
    // After an override (or a demo->normal flip) return to the bank shown
    // before it, or HOME_INDEX when that bank left the current mode.
    wire [1:0] restore_index = (resume_pending && allowed_mask[resume_index]) ?
                               resume_index : HOME_INDEX;
    wire restore_jump = (resume_pending || !allowed_mask[pending_index]) &&
                        pending_index != restore_index;

    function [2:0] next_available;
        input [1:0] current;
        input [3:0] complete;
        integer step;
        reg [1:0] candidate;
        begin
            next_available = {1'b0, current};
            for (step = 1; step <= 4; step = step + 1) begin
                candidate = current + step[1:0];
                if (!next_available[2] && complete[candidate])
                    next_available = {1'b1, candidate};
            end
        end
    endfunction

    task issue_next_request;
        reg [2:0] selected;
        begin
            selected = next_available(sys_current_index, play_mask);
            if (request_busy) begin
                control_error <= ERR_REQUEST_BUSY;
            end else if (!selected[2]) begin
                control_error <= ERR_NO_RESOURCE;
            end else begin
                pending_index <= selected[1:0];
                pending_jump <= 1'b0;
                request_toggle <= ~request_toggle;
                auto_counter <= 32'd0;
                // A successful issue retires any earlier sticky fault
                // (REQUEST_BUSY / NO_RESOURCE from boot-time presses), so the
                // OSD/UART error code reflects the latest outcome instead of
                // latching forever.
                control_error <= ERR_NONE;
            end
        end
    endtask

    // Direct jump to a fixed bank; callers guarantee !request_busy.
    task issue_jump;
        input [1:0] index;
        begin
            pending_index <= index;
            pending_jump <= 1'b1;
            request_toggle <= ~request_toggle;
            auto_counter <= 32'd0;
            control_error <= ERR_NONE;
        end
    endtask

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            auto_enabled <= 1'b0;
            active_period_cycles <= DEFAULT_PERIOD_CYCLES;
            pending_index <= 2'd0;
            pending_jump <= 1'b0;
            control_error <= ERR_NONE;
            auto_counter <= 32'd0;
            sys_current_index <= 2'd0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
            override_q <= 1'b0;
            resume_pending <= 1'b0;
            resume_index <= 2'd0;
        end else begin
            override_q <= override;
            // Latch the resume bank only on the first override entry, so a
            // bus-stop -> emergency nesting (or a quick re-toggle before the
            // restore lands) keeps the bank the user saw before any override.
            if (override && !override_q && !resume_pending) begin
                resume_index <= pending_index;
                resume_pending <= 1'b1;
            end

            ack_sync1 <= ack_toggle_pix;
            ack_sync2 <= ack_sync1;
            if (!request_busy)
                sys_current_index <= pending_index;

            if (period_cfg_valid) begin
                if (period_cfg_cycles < MIN_PERIOD_CYCLES ||
                    period_cfg_cycles > MAX_PERIOD_CYCLES) begin
                    control_error <= ERR_PERIOD_RANGE;
                end else begin
                    active_period_cycles <= period_cfg_cycles;
                    auto_counter <= 32'd0;
                end
            end

            if (auto_cfg_valid) begin
                auto_enabled <= auto_cfg_enabled;
                auto_counter <= 32'd0;
            end

            if (toggle_auto_event) begin
                auto_enabled <= ~auto_enabled;
                auto_counter <= 32'd0;
            end

            if (override) begin
                // Pinned bank: re-align whenever idle and off-target. A
                // next_event here is a KEY2 fade that started before the
                // switch flipped; the fade sits at black until a commit, so
                // re-issue the target even when it is already shown.
                auto_counter <= 32'd0;
                if (!request_busy && image_complete[override_index] &&
                    (next_event || pending_index != override_index))
                    issue_jump(override_index);
            end else if (restore_jump) begin
                // Dropping a next_event here is safe: either a request is in
                // flight or this jump commits, and both release the fade.
                auto_counter <= 32'd0;
                if (!request_busy && image_complete[restore_index]) begin
                    issue_jump(restore_index);
                    resume_pending <= 1'b0;
                end
            end else begin
                if (next_event) begin
                    issue_next_request();
                end else if (auto_enabled) begin
                    if (request_busy)
                        auto_counter <= 32'd0;
                    else if (auto_counter >= active_period_cycles - 1'b1)
                        issue_next_request();
                    else
                        auto_counter <= auto_counter + 1'b1;
                end else begin
                    auto_counter <= 32'd0;
                end
                // Resume bank already on screen: restart the slideshow
                // period from here.
                if (resume_pending) begin
                    resume_pending <= 1'b0;
                    if (!next_event)
                        auto_counter <= 32'd0;
                end
            end
        end
    end

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            index_sync1 <= 2'd0;
            index_sync2 <= 2'd0;
            jump_sync1 <= 1'b0;
            jump_sync2 <= 1'b0;
            req_sync1 <= 1'b0;
            req_sync2 <= 1'b0;
            req_seen_pix <= 1'b0;
            commit_pending_pix <= 1'b0;
            active_index <= 2'd0;
            index_commit <= 1'b0;
            commit_jump <= 1'b0;
            ack_toggle_pix <= 1'b0;
        end else begin
            index_sync1 <= pending_index;
            index_sync2 <= index_sync1;
            // pending_jump launches with pending_index and is held by the
            // same request_busy interlock, so the frame_start sample below
            // is just as settled as index_sync2.
            jump_sync1 <= pending_jump;
            jump_sync2 <= jump_sync1;
            req_sync1 <= request_toggle;
            req_sync2 <= req_sync1;
            index_commit <= 1'b0;
            commit_jump <= 1'b0;

            // Sample the bank index at the frame_start commit, not when the
            // request toggle is detected. pending_index and request_toggle
            // launch on the same sys_clk edge through independent 2FF chains,
            // so index_sync2 can lag the toggle at detection time. By
            // frame_start the value has settled for a whole frame period and
            // cannot change again: issue_next_request is blocked by
            // request_busy until the ack sent at this very commit.
            if (req_sync2 != req_seen_pix && !commit_pending_pix) begin
                req_seen_pix <= req_sync2;
                commit_pending_pix <= 1'b1;
            end

            if (frame_start && commit_pending_pix) begin
                active_index <= index_sync2;
                index_commit <= 1'b1;
                commit_jump <= jump_sync2;
                commit_pending_pix <= 1'b0;
                ack_toggle_pix <= req_seen_pix;
            end
        end
    end
endmodule
