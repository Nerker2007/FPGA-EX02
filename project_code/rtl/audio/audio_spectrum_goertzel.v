`timescale 1ns/1ps

// Audio spectrum analyser: 16 Goertzel bins on the "guzheng strings" of the
// background song (tools/song_jasmine.txt): the pentatonic scale of its key,
// 16 notes up from the lowest melody note. It consumes the PCM tap of the
// HDMI audio bridge (pcm_tap_valid pulses once per transmitted sample) and,
// every SEG_LEN = 8192 samples (~171 ms, long enough to separate the lowest
// two strings), publishes one 7-bit bar height per bin on bar_target (bin k
// at bits 7k+6..7k, range 0..64).
//
// Per sample: x is weighted by a 64-step Hann window (xw = x*hann >>> 19),
// then every bin runs s = xw + (c_k*s1 >>> 16) - s2 with a 30-bit state kept
// in a 32x36 BRAM ({k,0} = s1, {k,1} = s2). The state restarts from zero at
// the first sample of every segment. After the last sample each bin's power
// P = a*a + b*b - (c_k*a >>> 16)*b, with a = s1 >>> 13 and b = s2 >>> 13, is
// turned into a bar: lg = 4*msb(P) + next two bits (~0.75 dB per step),
// bar = clamp(2*(lg - LG_FLOOR), 0, 64).
//
// The arithmetic is bit-exact with tools/gen_spectrum_coeffs.py, which also
// generates the coefficient and window tables below; do not edit the
// GENERATED regions by hand. A sample takes ~83 clocks (+5 per bin at a
// segment end) against ~520 clocks between samples at 48 kHz; an 8-deep FIFO
// absorbs the packetiser's back-to-back bursts. fifo_overflow is sticky and
// only meant for simulation checks.
module audio_spectrum_goertzel (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               pcm_tap_valid,
    input  wire signed [15:0] pcm_tap_left,
    output reg  [111:0]       bar_target,
    output reg                fifo_overflow
);
    localparam integer SEG_LEN = 8192;
    localparam integer BAR_MAX = 64;

    // BEGIN GENERATED spectrum_coef (tools/gen_spectrum_coeffs.py --write)
    localparam integer NUM_BINS = 16;
    localparam integer LG_FLOOR = 24;
    function signed [17:0] coef_of;
        input [3:0] k;
        begin
            case (k)
                4'd0: coef_of = 18'sd131011;  // Bb3   233.08 Hz
                4'd1: coef_of = 18'sd130995;  // C4    261.63 Hz
                4'd2: coef_of = 18'sd130963;  // Eb4   311.13 Hz
                4'd3: coef_of = 18'sd130935;  // F4    349.23 Hz
                4'd4: coef_of = 18'sd130899;  // G4    392.00 Hz
                4'd5: coef_of = 18'sd130828;  // Bb4   466.16 Hz
                4'd6: coef_of = 18'sd130765;  // C5    523.25 Hz
                4'd7: coef_of = 18'sd130637;  // Eb5   622.25 Hz
                4'd8: coef_of = 18'sd130525;  // F5    698.46 Hz
                4'd9: coef_of = 18'sd130382;  // G5    783.99 Hz
                4'd10: coef_of = 18'sd130097;  // Bb5   932.33 Hz
                4'd11: coef_of = 18'sd129844;  // C6   1046.50 Hz
                4'd12: coef_of = 18'sd129337;  // Eb6  1244.51 Hz
                4'd13: coef_of = 18'sd128887;  // F6   1396.91 Hz
                4'd14: coef_of = 18'sd128321;  // G6   1567.98 Hz
                4'd15: coef_of = 18'sd127187;  // Bb6  1864.66 Hz
                default: coef_of = 18'sd0;
            endcase
        end
    endfunction
    // END GENERATED spectrum_coef

    // BEGIN GENERATED spectrum_hann (tools/gen_spectrum_coeffs.py --write)
    function [15:0] hann_of;
        input [4:0] i;
        begin
            case (i)
                5'd0: hann_of = 16'd39;
                5'd1: hann_of = 16'd355;
                5'd2: hann_of = 16'd982;
                5'd3: hann_of = 16'd1915;
                5'd4: hann_of = 16'd3146;
                5'd5: hann_of = 16'd4662;
                5'd6: hann_of = 16'd6448;
                5'd7: hann_of = 16'd8488;
                5'd8: hann_of = 16'd10762;
                5'd9: hann_of = 16'd13248;
                5'd10: hann_of = 16'd15922;
                5'd11: hann_of = 16'd18758;
                5'd12: hann_of = 16'd21728;
                5'd13: hann_of = 16'd24806;
                5'd14: hann_of = 16'd27960;
                5'd15: hann_of = 16'd31160;
                5'd16: hann_of = 16'd34375;
                5'd17: hann_of = 16'd37575;
                5'd18: hann_of = 16'd40729;
                5'd19: hann_of = 16'd43807;
                5'd20: hann_of = 16'd46777;
                5'd21: hann_of = 16'd49613;
                5'd22: hann_of = 16'd52287;
                5'd23: hann_of = 16'd54773;
                5'd24: hann_of = 16'd57047;
                5'd25: hann_of = 16'd59087;
                5'd26: hann_of = 16'd60873;
                5'd27: hann_of = 16'd62389;
                5'd28: hann_of = 16'd63620;
                5'd29: hann_of = 16'd64553;
                5'd30: hann_of = 16'd65180;
                5'd31: hann_of = 16'd65496;
                default: hann_of = 16'd0;
            endcase
        end
    endfunction
    // END GENERATED spectrum_hann

    // ---- input FIFO ----------------------------------------------------
    reg signed [15:0] fifo [0:7];
    reg [2:0] fifo_wp;
    reg [2:0] fifo_rp;
    reg [3:0] fifo_count;
    wire fifo_pop;
    wire fifo_push = pcm_tap_valid && (fifo_count != 4'd8 || fifo_pop);

    always @(posedge clk) begin
        if (fifo_push)
            fifo[fifo_wp] <= pcm_tap_left;
    end

    // ---- Goertzel state RAM: {k,0} = s1, {k,1} = s2 ----------------------
    reg [35:0] state_ram [0:31] /* fehdl force_ram=1, ram_style="bram" */;
    reg [4:0] ram_raddr;
    reg [35:0] ram_rdata;
    reg ram_we;
    reg [4:0] ram_waddr;
    reg signed [29:0] ram_wdata;

    always @(posedge clk) begin
        if (ram_we)
            state_ram[ram_waddr] <= {{6{ram_wdata[29]}}, ram_wdata};
        ram_rdata <= state_ram[ram_raddr];
    end

    // ---- sequencer -------------------------------------------------------
    // Per sample: IDLE (pop) -> WIN (x*hann) -> XW, then per bin
    // B0 (read s1) -> B1 (read s2) -> B2 (c*s1) -> B3 (s, write s2) ->
    // B4 (write s1). On the segment's last sample every bin also runs
    // P0..P4 (power products, lg, bar) right after its B4.
    localparam [3:0] S_IDLE = 4'd0,  S_WIN = 4'd1,  S_XW = 4'd2,
                     S_B0   = 4'd3,  S_B1  = 4'd4,  S_B2 = 4'd5,
                     S_B3   = 4'd6,  S_B4  = 4'd7,
                     S_P0   = 4'd8,  S_P1  = 4'd9,  S_P2 = 4'd10,
                     S_P3   = 4'd11, S_P4  = 4'd12;
    reg [3:0] state;
    reg [12:0] sample_n;
    reg [3:0] bin;
    reg signed [15:0] x_r;
    reg signed [15:0] xw;
    reg signed [29:0] s1_r;
    reg signed [29:0] s2_r;
    reg signed [29:0] s_new;
    reg signed [35:0] m1_p;        // M1: 18 x 18 (window, power products)
    reg signed [47:0] m2_p;        // M2: coef 18 x 30 (recursion, c*a)
    reg signed [17:0] ca_r;
    reg signed [35:0] aa_r;
    reg signed [35:0] bb_r;
    reg signed [35:0] power_r;

    assign fifo_pop = state == S_IDLE && fifo_count != 4'd0;

    wire first_sample = sample_n == 13'd0;
    wire last_sample = sample_n == SEG_LEN - 1;
    wire [4:0] hann_index = sample_n[12] ? ~sample_n[11:7] : sample_n[11:7];
    wire signed [17:0] coef = coef_of(bin);
    wire signed [16:0] pa = s_new >>> 13;     // final s1
    wire signed [16:0] pb = s1_r >>> 13;      // final s2 (= previous s1)

    reg signed [17:0] m1_a;
    reg signed [17:0] m1_b;
    always @(*) begin
        case (state)
            S_WIN:   begin m1_a = x_r;  m1_b = {2'b00, hann_of(hann_index)}; end
            S_P0:    begin m1_a = pa;   m1_b = pa; end
            S_P1:    begin m1_a = pb;   m1_b = pb; end
            default: begin m1_a = ca_r; m1_b = pb; end
        endcase
    end
    wire signed [29:0] m2_b = (state == S_P0) ? {{13{pa[16]}}, pa} : s1_r;

    // lg = 4*msb + the two bits below the msb of the non-negative power.
    reg [7:0] lg;
    integer bit_i;
    always @(*) begin
        lg = 8'd0;
        for (bit_i = 2; bit_i < 35; bit_i = bit_i + 1)
            if (power_r[bit_i])
                lg = {bit_i[5:0], power_r[bit_i-1 -: 2]};
    end
    wire [8:0] lg_excess = {1'b0, lg} - LG_FLOOR;
    wire [6:0] bar_height = (lg <= LG_FLOOR) ? 7'd0 :
                            (lg_excess >= BAR_MAX/2) ? BAR_MAX[6:0] :
                            {lg_excess[5:0], 1'b0};
    wire signed [35:0] power_raw = aa_r + bb_r - m1_p;

    always @(*) begin
        ram_raddr = (state == S_B0) ? {bin, 1'b0} : {bin, 1'b1};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wp <= 3'd0;
            fifo_rp <= 3'd0;
            fifo_count <= 4'd0;
            fifo_overflow <= 1'b0;
            state <= S_IDLE;
            sample_n <= 13'd0;
            bin <= 4'd0;
            x_r <= 16'sd0;
            xw <= 16'sd0;
            s1_r <= 30'sd0;
            s2_r <= 30'sd0;
            s_new <= 30'sd0;
            m1_p <= 36'sd0;
            m2_p <= 48'sd0;
            ca_r <= 18'sd0;
            aa_r <= 36'sd0;
            bb_r <= 36'sd0;
            power_r <= 36'sd0;
            ram_we <= 1'b0;
            ram_waddr <= 5'd0;
            ram_wdata <= 30'sd0;
            bar_target <= 112'd0;
        end else begin
            if (fifo_push)
                fifo_wp <= fifo_wp + 1'b1;
            if (fifo_pop)
                fifo_rp <= fifo_rp + 1'b1;
            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
            if (pcm_tap_valid && !fifo_push)
                fifo_overflow <= 1'b1;

            m1_p <= m1_a * m1_b;
            ram_we <= 1'b0;

            case (state)
                S_IDLE: if (fifo_pop) begin
                    x_r <= fifo[fifo_rp];
                    state <= S_WIN;
                end
                S_WIN: state <= S_XW;              // m1_p <= x * hann
                S_XW: begin
                    xw <= m1_p >>> 19;
                    bin <= 4'd0;
                    state <= S_B0;
                end
                S_B0: state <= S_B1;               // read s1
                S_B1: begin                        // s1 arrives, read s2
                    s1_r <= first_sample ? 30'sd0 : ram_rdata[29:0];
                    state <= S_B2;
                end
                S_B2: begin
                    s2_r <= first_sample ? 30'sd0 : ram_rdata[29:0];
                    m2_p <= coef * m2_b;           // c_k * s1
                    state <= S_B3;
                end
                S_B3: begin
                    s_new <= xw + (m2_p >>> 16) - s2_r;
                    ram_we <= 1'b1;                // s2 <= old s1
                    ram_waddr <= {bin, 1'b1};
                    ram_wdata <= s1_r;
                    state <= S_B4;
                end
                S_B4: begin
                    ram_we <= 1'b1;                // s1 <= new s
                    ram_waddr <= {bin, 1'b0};
                    ram_wdata <= s_new;
                    if (last_sample)
                        state <= S_P0;
                    else if (bin == NUM_BINS - 1) begin
                        sample_n <= sample_n + 1'b1;
                        state <= S_IDLE;
                    end else begin
                        bin <= bin + 1'b1;
                        state <= S_B0;
                    end
                end
                S_P0: begin                        // m1_p <= a*a
                    m2_p <= coef * m2_b;           // c_k * a
                    state <= S_P1;
                end
                S_P1: begin                        // m1_p <= b*b
                    aa_r <= m1_p;
                    ca_r <= m2_p >>> 16;
                    state <= S_P2;
                end
                S_P2: begin                        // m1_p <= ca*b
                    bb_r <= m1_p;
                    state <= S_P3;
                end
                S_P3: begin
                    power_r <= power_raw[35] ? 36'sd0 : power_raw;
                    state <= S_P4;
                end
                S_P4: begin
                    bar_target[bin*7 +: 7] <= bar_height;
                    if (bin == NUM_BINS - 1) begin
                        sample_n <= 13'd0;
                        state <= S_IDLE;
                    end else begin
                        bin <= bin + 1'b1;
                        state <= S_B0;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
