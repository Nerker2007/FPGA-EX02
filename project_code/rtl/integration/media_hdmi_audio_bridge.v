`timescale 1ns/1ps

// Player-owned boundary between the registered video bundle and the verified
// Route B HDMI packet/symbol chain. The EG4 DDR PHY remains in the board Top so
// this bridge can be exercised in ordinary RTL simulation without vendor pads.
// media_id drives the per-image tone selection and volume scales the output,
// turning the tone source into the audio half of the AV-linked feature.
// song_mode (already in the pixel_clk domain) switches the source to the
// looping background song in the normal-mode operating state; arrive_audio
// / emerg_audio (also pixel_clk domain) select the arrival chime and the
// emergency siren, which win over the song.
module media_hdmi_audio_bridge (
    input  wire        pixel_clk,
    input  wire        pixel_rst_n,
    input  wire        video_hsync,
    input  wire        video_vsync,
    input  wire        video_de,
    input  wire [9:0]  video_x,
    input  wire [23:0] video_rgb,
    input  wire [1:0]  media_id,
    input  wire [7:0]  volume,
    input  wire        song_mode,
    input  wire        arrive_audio,
    input  wire        emerg_audio,
    output wire [9:0]  channel0_symbol,
    output wire [9:0]  channel1_symbol,
    output wire [9:0]  channel2_symbol,
    output wire        sequence_error,
    output wire        tone_overflow,
    output wire        pcm_contract_error,
    output wire        blip_active,
    // PCM tap of the samples actually handed to the packet chain: valid pulses
    // for one clock per accepted sample (valid && ready), so the spectrum
    // analyser counts each transmitted sample exactly once.
    output wire        pcm_tap_valid,
    output wire signed [15:0] pcm_tap_left
);
    wire source_valid;
    wire source_ready;
    wire signed [15:0] source_left;
    wire signed [15:0] source_right;
    wire sample_valid;
    wire sample_ready;
    wire signed [15:0] sample_left;
    wire signed [15:0] sample_right;
    assign pcm_tap_valid = sample_valid && sample_ready;
    assign pcm_tap_left = sample_left;

    pcm_media_tone u_tone (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .media_id(media_id), .volume(volume), .song_mode(song_mode),
        .arrive(arrive_audio), .emerg(emerg_audio),
        .sample_valid(source_valid), .sample_ready(source_ready),
        .sample_left(source_left), .sample_right(source_right),
        .overflow(tone_overflow), .blip_active(blip_active)
    );

    m06_pcm_contract_adapter u_m06_pcm_contract (
        .clk(pixel_clk), .rst_n(pixel_rst_n),
        .source_valid(source_valid), .source_ready(source_ready),
        .source_left(source_left), .source_right(source_right),
        .pcm_valid(sample_valid), .pcm_ready(sample_ready),
        .pcm_left(sample_left), .pcm_right(sample_right),
        .contract_error(pcm_contract_error)
    );

    hdmi_audio_symbol_core u_symbol_core (
        .pixel_clk(pixel_clk), .rst_n(pixel_rst_n),
        .video_hsync(video_hsync), .video_vsync(video_vsync),
        .video_de(video_de), .video_x(video_x), .video_rgb(video_rgb),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .sample_left(sample_left), .sample_right(sample_right),
        .channel0_symbol(channel0_symbol),
        .channel1_symbol(channel1_symbol),
        .channel2_symbol(channel2_symbol),
        .sequence_error(sequence_error)
    );
endmodule
