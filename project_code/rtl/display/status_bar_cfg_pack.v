`timescale 1ns/1ps

// sys_clk side of the status bar: reduces the slow control state to a
// registered 6-bit word {bright_lvl, mode, period_lvl} that crosses into the
// pixel domain through per-bit sync_2ff (status_bar_24 only latches it when
// stable). Mode priority follows openspec info-overlay-display:
// SW3 emergency > SW1 demo > SW2 arrival > operating. The period thresholds
// match param_menu_controller.period_level so a period loaded from Flash
// shows the same step the menu would.
module status_bar_cfg_pack (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        demo_mode,
    input  wire        arrive_sw,
    input  wire        emerg_sw,
    input  wire [1:0]  bright_lvl,
    input  wire [31:0] period_ms,
    output reg  [5:0]  cfg          // {bright_lvl, mode, period_lvl}
);
    localparam [1:0] MODE_RUN = 2'd0;
    localparam [1:0] MODE_ARRIVE = 2'd1;
    localparam [1:0] MODE_EMERG = 2'd2;
    localparam [1:0] MODE_DEMO = 2'd3;

    wire [1:0] mode = emerg_sw ? MODE_EMERG :
                      demo_mode ? MODE_DEMO :
                      arrive_sw ? MODE_ARRIVE : MODE_RUN;
    wire [1:0] period_lvl = (period_ms < 32'd3500) ? 2'd0 :
                            (period_ms < 32'd7500) ? 2'd1 :
                            (period_ms < 32'd20000) ? 2'd2 : 2'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cfg <= 6'd0;
        else
            cfg <= {bright_lvl, mode, period_lvl};
    end
endmodule
