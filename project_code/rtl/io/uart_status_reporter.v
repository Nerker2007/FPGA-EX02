`timescale 1ns/1ps

// Human-readable player status over the board UART transmitter. Reports the
// boot banner, every image switch, parameter menu changes and error codes as
// short CR/LF ASCII lines through one verified uart_tx_byte instance.
// The message bytes are produced combinationally by a character function
// from a latched event snapshot: no byte array exists, which keeps every
// path short enough for the 50 MHz system clock. Dynamic values print in
// hexadecimal to avoid divider logic.
module uart_status_reporter #(
    parameter integer CLKS_PER_BIT = 434,
    // Bytes 18/19 of the boot banner. The defaults reproduce the legacy
    // CR/LF tail byte-for-byte; per-class builds may bake a 2-char tag so a
    // captured UART log identifies the distributed build.
    parameter [7:0] BUILD_TAG_A = 8'h0d,
    parameter [7:0] BUILD_TAG_B = 8'h0a
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    input  wire [31:0] period_ms,
    input  wire        auto_enabled,
    input  wire        switch_event,
    input  wire        menu_event,
    input  wire [1:0]  menu_kind,
    input  wire [7:0]  error_code,
    input  wire        bright_event,
    input  wire [7:0]  bright_value,
    output wire        uart_tx
);
    localparam [7:0] CR = 8'h0d;
    localparam [7:0] LF = 8'h0a;

    localparam [2:0] K_BANNER = 3'd0;
    localparam [2:0] K_PIC    = 3'd1;
    localparam [2:0] K_VOL    = 3'd2;
    localparam [2:0] K_PRD    = 3'd3;
    localparam [2:0] K_ERR    = 3'd4;
    localparam [2:0] K_BRT    = 3'd5;

    reg [2:0] kind_q;
    reg [1:0] pic_id_q;
    reg pic_auto_q;
    reg [7:0] val8_q;
    reg [31:0] val32_q;
    reg [4:0] msg_len;
    reg [4:0] send_index;
    reg tx_start_r;
    reg [1:0] state;
    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SEND = 2'd1;

    reg enable_q;
    reg switch_q;
    reg [1:0] switch_id_q;
    reg switch_auto_q;
    reg error_active_q;
    reg menu_pending;
    reg [1:0] menu_kind_q;
    reg bright_pending;
    reg [7:0] bright_val_q;

    wire tx_busy;
    wire tx_done;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .start(tx_start_r), .data(msg_char(kind_q, send_index)),
        .tx(uart_tx), .busy(tx_busy), .done(tx_done)
    );

    function [7:0] hex_digit;
        input [3:0] nibble;
        begin
            hex_digit = (nibble < 4'ha) ? (8'h30 + {4'b0, nibble})
                                        : (8'h37 + {4'b0, nibble});
        end
    endfunction

    function [7:0] msg_char;
        input [2:0] kind;
        input [4:0] idx;
        begin
            case (kind)
            K_BANNER: case (idx)
                0: msg_char = "M"; 1: msg_char = "E"; 2: msg_char = "D";
                3: msg_char = "I"; 4: msg_char = "A"; 5: msg_char = " ";
                6: msg_char = "P"; 7: msg_char = "L"; 8: msg_char = "A";
                9: msg_char = "Y"; 10: msg_char = "E"; 11: msg_char = "R";
                12: msg_char = " "; 13: msg_char = "R"; 14: msg_char = "E";
                15: msg_char = "A"; 16: msg_char = "D"; 17: msg_char = "Y";
                18: msg_char = BUILD_TAG_A; 19: msg_char = BUILD_TAG_B;
                default: msg_char = 8'h00;
            endcase
            K_PIC: case (idx)
                0: msg_char = "P"; 1: msg_char = "I"; 2: msg_char = "C";
                3: msg_char = " "; 4: msg_char = "1" + {6'b0, pic_id_q};
                5: msg_char = " ";
                6: msg_char = pic_auto_q ? "A" : "M";
                7: msg_char = CR; 8: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_VOL: case (idx)
                0: msg_char = "V"; 1: msg_char = "O"; 2: msg_char = "L";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_PRD: case (idx)
                0: msg_char = "P"; 1: msg_char = "R"; 2: msg_char = "D";
                3: msg_char = " ";
                4: msg_char = hex_digit(val32_q[19:16]);
                5: msg_char = hex_digit(val32_q[15:12]);
                6: msg_char = hex_digit(val32_q[11:8]);
                7: msg_char = hex_digit(val32_q[7:4]);
                8: msg_char = hex_digit(val32_q[3:0]);
                9: msg_char = "m"; 10: msg_char = "s";
                11: msg_char = CR; 12: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_ERR: case (idx)
                0: msg_char = "E"; 1: msg_char = "R"; 2: msg_char = "R";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            K_BRT: case (idx)
                0: msg_char = "B"; 1: msg_char = "R"; 2: msg_char = "T";
                3: msg_char = " ";
                4: msg_char = hex_digit(val8_q[7:4]);
                5: msg_char = hex_digit(val8_q[3:0]);
                6: msg_char = CR; 7: msg_char = LF;
                default: msg_char = 8'h00;
            endcase
            default: msg_char = 8'h00;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            kind_q <= K_BANNER;
            pic_id_q <= 2'd0;
            pic_auto_q <= 1'b0;
            val8_q <= 8'd0;
            val32_q <= 32'd0;
            msg_len <= 5'd0;
            send_index <= 5'd0;
            tx_start_r <= 1'b0;
            enable_q <= 1'b0;
            switch_q <= 1'b0;
            switch_id_q <= 2'd0;
            switch_auto_q <= 1'b0;
            error_active_q <= 1'b0;
            menu_pending <= 1'b0;
            menu_kind_q <= 2'd0;
            bright_pending <= 1'b0;
            bright_val_q <= 8'd0;
        end else begin
            enable_q <= enable;
            switch_q <= switch_event;
            switch_id_q <= media_id;
            switch_auto_q <= auto_enabled;
            if (menu_event) begin
                menu_pending <= 1'b1;
                menu_kind_q <= menu_kind;
            end
            if (bright_event) begin
                bright_pending <= 1'b1;
                bright_val_q <= bright_value;
            end

            case (state)
            ST_IDLE: begin
                tx_start_r <= 1'b0;
                send_index <= 5'd0;
                if (!enable_q && enable) begin
                    kind_q <= K_BANNER;
                    msg_len <= 5'd20;
                    state <= ST_SEND;
                end else if ((error_code != 8'd0) && !error_active_q) begin
                    error_active_q <= 1'b1;
                    kind_q <= K_ERR;
                    val8_q <= error_code;
                    msg_len <= 5'd8;
                    state <= ST_SEND;
                end else if ((error_code == 8'd0) && error_active_q) begin
                    error_active_q <= 1'b0;
                end else if (switch_q) begin
                    kind_q <= K_PIC;
                    pic_id_q <= switch_id_q;
                    pic_auto_q <= switch_auto_q;
                    msg_len <= 5'd9;
                    state <= ST_SEND;
                end else if (menu_pending) begin
                    menu_pending <= 1'b0;
                    if (menu_kind_q == 2'd0) begin
                        kind_q <= K_VOL;
                        val8_q <= volume;
                        msg_len <= 5'd8;
                    end else begin
                        kind_q <= K_PRD;
                        val32_q <= period_ms;
                        msg_len <= 5'd13;
                    end
                    state <= ST_SEND;
                end else if (bright_pending) begin
                    bright_pending <= 1'b0;
                    kind_q <= K_BRT;
                    val8_q <= bright_val_q;
                    msg_len <= 5'd8;
                    state <= ST_SEND;
                end
            end
            ST_SEND: begin
                if (tx_done)
                    send_index <= send_index + 1'b1;
                if (send_index >= msg_len) begin
                    tx_start_r <= 1'b0;
                    send_index <= 5'd0;
                    state <= ST_IDLE;
                end else if (!tx_busy && !tx_start_r && !tx_done) begin
                    tx_start_r <= 1'b1;
                end else begin
                    tx_start_r <= 1'b0;
                end
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
