`timescale 1ns/1ps

// Excellence top: everything in the final competition candidate plus the
// KEY4 parameter menu (short press = volume ladder, one-second hold =
// slideshow period ladder) and the UART status reporter (boot banner, per
// switch lines, parameter changes, error codes) on the board USB-UART.
module media_player_excellence_top (
    input  wire       sys_clk,
    input  wire       sys_rst_n,
    input  wire       key2_n,
    input  wire       key3_n,
    input  wire       key4_n,
    // Slide switches, flipped down = 1 = on: SW1 demo mode, SW2 bus stop,
    // SW3 emergency.
    input  wire       sw1,
    input  wire       sw2,
    input  wire       sw3,
    output wire       uart_tx_o,
    output wire       sd_cs_n,
    output wire       sd_sclk,
    output wire       sd_mosi,
    input  wire       sd_miso,
    input  wire       flash_miso,
    output wire       flash_cs_n,
    output wire       flash_sclk,
    output wire       flash_mosi,
    output wire       flash_wp_n,
    output wire       flash_hold_n,
    output wire       HDMI_CLK_P,
    output wire       HDMI_D2_P,
    output wire       HDMI_D1_P,
    output wire       HDMI_D0_P,
    output wire [3:0] led
);
    wire mem_feedback_clk;
    wire mem_clk;
    wire mem_clk_shift;
    wire mem_locked;
    sys_pll u_mem_pll (
        .refclk(sys_clk), .reset(~sys_rst_n),
        .clk0_out(mem_feedback_clk), .clk1_out(mem_clk),
        .clk2_out(mem_clk_shift), .locked(mem_locked)
    );

    wire pixel_clk_5x;
    wire pixel_clk;
    wire video_locked;
    clk_wize u_video_pll (
        .refclk(sys_clk), .reset(~sys_rst_n),
        .clk0_out(pixel_clk_5x), .clk1_out(pixel_clk),
        .locked(video_locked)
    );

    wire mem_rst_n;
    wire pix_rst_n;
    wire pix_5x_rst_n;
    wire ctrl_rst_n;
    reset_sync u_mem_reset (
        .clk(mem_clk), .ext_rst_n(sys_rst_n & mem_locked),
        .rst_n_sync(mem_rst_n)
    );
    reset_sync u_pix_reset (
        .clk(pixel_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_rst_n)
    );
    reset_sync u_pix_5x_reset (
        .clk(pixel_clk_5x), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(pix_5x_rst_n)
    );
    reset_sync u_ctrl_reset (
        .clk(sys_clk), .ext_rst_n(sys_rst_n & video_locked),
        .rst_n_sync(ctrl_rst_n)
    );

    wire sdram_init_done;
    wire sdram_refresh_active;
    wire sdram_busy;
    wire ingest_app_wr_en;
    wire [20:0] ingest_app_wr_addr;
    wire [3:0] ingest_app_wr_mask;
    wire [31:0] ingest_app_wr_data;
    wire player_app_rd_en;
    wire [20:0] player_app_rd_addr;
    wire sdram_rd_valid;
    wire [31:0] sdram_rd_data;

    sdram u_sdram (
        .Clk(mem_clk), .Clk_sft(mem_clk_shift), .Rst(~mem_rst_n),
        .Sdr_init_done(sdram_init_done),
        .Sdr_init_ref_vld(sdram_refresh_active), .Sdr_busy(sdram_busy),
        .App_wr_en(ingest_app_wr_en), .App_wr_addr(ingest_app_wr_addr),
        .App_wr_dm(ingest_app_wr_mask), .App_wr_din(ingest_app_wr_data),
        .App_rd_en(player_app_rd_en), .App_rd_addr(player_app_rd_addr),
        .Sdr_rd_en(sdram_rd_valid), .Sdr_rd_dout(sdram_rd_data)
    );

    reg ingest_start;
    reg ingest_started;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            ingest_start <= 1'b0;
            ingest_started <= 1'b0;
        end else begin
            ingest_start <= 1'b0;
            if (sdram_init_done && !ingest_started) begin
                ingest_start <= 1'b1;
                ingest_started <= 1'b1;
            end
        end
    end

    wire ingest_busy;
    wire ingest_done;
    wire [2:0] ingest_error_stage;
    wire [7:0] ingest_error_code;
    wire [7:0] ingest_error_detail;
    wire card_ready;
    wire card_high_capacity;
    wire [3:0] resource_valid;
    wire [3:0] image_complete;
    wire [159:0] image_res_mem;
    media_storage_ingest_top u_storage_ingest (
        .clk(mem_clk), .rst_n(mem_rst_n), .start(ingest_start),
        .busy(ingest_busy), .done(ingest_done),
        .error_stage(ingest_error_stage), .error_code(ingest_error_code),
        .error_detail(ingest_error_detail), .card_ready(card_ready),
        .card_high_capacity(card_high_capacity),
        .image_res_bcd(image_res_mem),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .controller_init_done(sdram_init_done),
        .controller_busy(sdram_busy), .refresh_active(sdram_refresh_active),
        .app_wr_en(ingest_app_wr_en), .app_wr_addr(ingest_app_wr_addr),
        .app_wr_mask(ingest_app_wr_mask), .app_wr_data(ingest_app_wr_data),
        .sd_cs_n(sd_cs_n), .sd_sclk(sd_sclk),
        .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    // Storage owns writes until all four frames commit. Playback then owns
    // only the read port; the two stages never issue commands concurrently.
    reg player_enable_mem;
    wire storage_error_mem;
    always @(posedge mem_clk or negedge mem_rst_n) begin
        if (!mem_rst_n) begin
            player_enable_mem <= 1'b0;
        end else if (ingest_done) begin
            if (ingest_error_stage == 0 && ingest_error_code == 0 &&
                image_complete == 4'hf)
                player_enable_mem <= 1'b1;
        end
    end

    // Slide switches: button_event gives 2FF sync + 20 ms debounce, and its
    // level output is the debounced ~key_n, so feed it the inverted switch.
    wire demo_mode;
    wire arrive_sw;
    wire emerg_sw;
    button_event u_sw1 (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .key_n(~sw1),
        .press(), .level(demo_mode)
    );
    button_event u_sw2 (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .key_n(~sw2),
        .press(), .level(arrive_sw)
    );
    button_event u_sw3 (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .key_n(~sw3),
        .press(), .level(emerg_sw)
    );

    // Key lockout, applied to the key modules' event outputs so every user
    // below sees the gated pulse. The emergency bank blocks KEY2..KEY4
    // entirely; any pinned bank blocks KEY2 before the fade, so it cannot
    // flash black. key2_lock MUST match `override` in media_player_control.
    // Dropped pulses are never replayed; the key FSMs keep running.
    wire key_lock_all = emerg_sw;
    wire key2_lock = emerg_sw | (arrive_sw & ~demo_mode);
    wire key2_press_raw;
    wire key3_press_raw;
    wire key3_long_press_raw;
    wire config_save_event_raw;
    wire menu_cfg_valid_raw;
    wire menu_evt_raw;
    wire key2_press = key2_press_raw & ~key2_lock;
    wire key3_press = key3_press_raw & ~key_lock_all;
    wire key3_long_press = key3_long_press_raw & ~key_lock_all;
    wire config_save_event = config_save_event_raw & ~key_lock_all;
    wire menu_cfg_valid = menu_cfg_valid_raw & ~key_lock_all;
    wire menu_evt = menu_evt_raw & ~key_lock_all;

    wire config_save_locked;
    wire config_ready;
    wire config_busy;
    wire config_load_done;
    wire config_save_done;
    wire config_apply_valid;
    wire config_rejected;
    wire config_fatal_error;
    wire [7:0] config_error_code;
    wire config_request_dropped;
    wire stored_config_valid;
    wire [31:0] stored_config_version;
    wire [31:0] config_period_ms;
    wire [31:0] config_period_cycles;
    wire [7:0] config_volume;
    wire [7:0] config_mode;
    wire [23:0] config_jedec_id;
    wire [7:0] config_status1, config_status2, config_status3;
    wire auto_enabled;

    // Human-operated chord contract: a single key acts on release; while the
    // first key remains held, the second key may join and start a 2 s save hold.
    dual_key_chord_router #(
        .DEBOUNCE_CYCLES(1000000),
        .HOLD_CYCLES(100000000),
        .KEY3_LONG_CYCLES(50000000)
    ) u_key_router (
        .clk(sys_clk), .rst_n(ctrl_rst_n), .save_enabled(config_ready),
        .key2_n(key2_n), .key3_n(key3_n), .key2_event(key2_press_raw),
        .key3_event(key3_press_raw), .key3_long_event(key3_long_press_raw),
        .save_event(config_save_event_raw),
        .save_locked(config_save_locked), .key2_stable_n(),
        .key3_stable_n()
    );

    // Session-level brightness ladder: KEY3 held alone for one second and
    // released steps 100/75/50/25%% and back to 100%%. The level rides along
    // with the KEY2+KEY3 save chord (Flash mode byte bits 2:1) and is restored
    // once from Flash when the configuration load completes; a level change
    // alone never triggers a Flash write or a cfg_update (that would reset
    // the slideshow countdown).
    reg [1:0] brightness_level;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            brightness_level <= 2'd0;
        else if (config_load_done)
            brightness_level <= config_mode[2:1];
        else if (key3_long_press && config_ready)
            brightness_level <= brightness_level + 1'b1;
    end
    reg [7:0] brightness_sys;
    always @* begin
        case (brightness_level)
            2'd0: brightness_sys = 8'd255;
            2'd1: brightness_sys = 8'd192;
            2'd2: brightness_sys = 8'd128;
            default: brightness_sys = 8'd64;
        endcase
    end

    // KEY4 parameter menu: short press steps the volume ladder, a one
    // second hold steps the slideshow period ladder. The persistence service
    // samples the new value immediately; the dual-key chord still controls
    // the Flash write.
    wire [31:0] menu_cfg_period;
    wire [7:0] menu_cfg_volume;
    wire [1:0] menu_kind;

    param_menu_controller #(
        .CLKS_PER_MS(50000)
    ) u_param_menu (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .key4_n(key4_n), .service_ready(config_ready),
        .live_volume(config_volume), .live_period_ms(config_period_ms),
        .cfg_update_valid(menu_cfg_valid_raw),
        .cfg_period_ms(menu_cfg_period), .cfg_volume(menu_cfg_volume),
        .menu_event(menu_evt_raw), .menu_kind(menu_kind), .menu_level()
    );

    player_config_persistence u_player_config (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .cfg_update_valid((key3_press || menu_cfg_valid) && config_ready),
        .cfg_period_ms(menu_cfg_valid ? menu_cfg_period : config_period_ms),
        .cfg_volume(menu_cfg_valid ? menu_cfg_volume : config_volume),
        // KEY3 toggles the slideshow in the same cycle, so the persisted
        // mode must be the inverted current value; a KEY4 menu update leaves
        // the mode untouched and must record it as-is, otherwise every
        // volume/period change silently flips auto-slideshow - and writes
        // the flipped state back to flash across reboots.
        .cfg_mode(key3_press ? {5'd0, brightness_level, ~auto_enabled} :
                              {5'd0, brightness_level, auto_enabled}),
        .cfg_brightness(brightness_level),
        .save_request(config_save_event), .service_ready(config_ready),
        .busy(config_busy), .load_done(config_load_done),
        .save_done(config_save_done), .apply_valid(config_apply_valid),
        .config_rejected(config_rejected),
        .fatal_error(config_fatal_error), .error_code(config_error_code),
        .request_dropped(config_request_dropped),
        .stored_config_valid(stored_config_valid),
        .active_version(stored_config_version),
        .live_period_ms(config_period_ms),
        .live_period_cycles(config_period_cycles),
        .live_volume(config_volume), .live_mode(config_mode),
        .jedec_id(config_jedec_id), .status1(config_status1),
        .status2(config_status2), .status3(config_status3),
        .flash_miso(flash_miso), .flash_cs_n(flash_cs_n),
        .flash_sclk(flash_sclk), .flash_mosi(flash_mosi),
        .flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
    );

    reg config_save_ok_latched;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            config_save_ok_latched <= 1'b0;
        else if (config_save_done && !config_fatal_error)
            config_save_ok_latched <= 1'b1;
    end

    wire [3:0] image_complete_sys;
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1) begin : g_image_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(image_complete[bit_index]),
                .sync_out(image_complete_sys[bit_index])
            );
        end
    endgenerate

    wire video_clk;
    wire video_hs;
    wire video_vs;
    wire video_de;
    wire [23:0] video_rgb;
    wire [9:0] video_x;
    wire [1:0] active_index;
    wire [1:0] pending_index;
    wire frame_start;
    wire reader_busy;
    wire reader_underflow;
    wire [7:0] video_error;

    // FADE_FRAMES=16 gives roughly a 0.27 s ramp at 640x480@60 on both the
    // fade-out and fade-in halves of a manual switch.
    //
    // The session brightness is NOT applied here: it is scaled once at the end
    // of the overlay chain (u_bright_scale) so the status bar, the subtitle and
    // the spectrum bars dim together with the picture instead of staying at
    // full brightness. This instance is therefore pinned to 255, which makes
    // the pipeline's internal (brightness+1)/256 factor exactly 1.0 and lets
    // synthesis constant-fold it away.
    wire [7:0] brightness_pix;
    genvar bright_bit;
    generate
        for (bright_bit = 0; bright_bit < 8; bright_bit = bright_bit + 1) begin : g_bright_sync
            sync_2ff u_sync (
                .clk(pixel_clk), .rst_n(pix_rst_n),
                .async_in(brightness_sys[bright_bit]),
                .sync_out(brightness_pix[bright_bit])
            );
        end
    endgenerate

    media_video_pipeline #(
        .FADE_FRAMES(16)
    ) u_video (
        .brightness(8'd255),
        .ctrl_clk(sys_clk), .ctrl_rst_n(ctrl_rst_n),
        .demo_mode(demo_mode), .arrive_sw(arrive_sw), .emerg_sw(emerg_sw),
        .next_event(key2_press), .toggle_auto_event(key3_press),
        .period_cfg_valid(config_apply_valid),
        .period_cfg_cycles(config_period_cycles),
        .auto_cfg_valid(config_apply_valid),
        .auto_cfg_enabled(config_mode[0]),
        .image_complete(image_complete_sys),
        .player_enable(player_enable_mem), .mem_clk(mem_clk),
        .mem_rst_n(mem_rst_n), .controller_init_done(sdram_init_done),
        .controller_busy(sdram_busy), .refresh_active(sdram_refresh_active),
        .app_rd_en(player_app_rd_en), .app_rd_addr(player_app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pixel_clk), .pix_rst_n(pix_rst_n),
        .video_clk(video_clk), .video_hs(video_hs),
        .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb), .video_x(video_x),
        .active_index(active_index),
        .pending_index(pending_index), .auto_enabled(auto_enabled),
        .frame_start(frame_start), .reader_busy(reader_busy),
        .reader_underflow(reader_underflow), .video_error(video_error)
    );

    // Audio-video linkage: the displayed image picks the sustained note and
    // the persisted volume scales it. Both are slow, frame-granular signals
    // crossing into the registered video clock domain.
    wire [1:0] active_index_video;
    wire [7:0] volume_video;
    genvar media_bit;
    generate
        for (media_bit = 0; media_bit < 2; media_bit = media_bit + 1) begin : g_media_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(active_index[media_bit]),
                .sync_out(active_index_video[media_bit])
            );
        end
    endgenerate
    generate
        for (media_bit = 0; media_bit < 8; media_bit = media_bit + 1) begin : g_volume_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(config_volume[media_bit]),
                .sync_out(volume_video[media_bit])
            );
        end
    endgenerate

    wire [9:0] audio_symbol0;
    wire [9:0] audio_symbol1;
    wire [9:0] audio_symbol2;
    wire audio_sequence_error;
    wire audio_tone_overflow;
    wire audio_pcm_contract_error;
    wire audio_phy_phase_error;
    wire audio_blip_active;

    // Audio faults surface as 8'h71 (distinct from the 0x6x reader family
    // and 0x5x control family) so the UART log and the status bar report the
    // same failure the 4'hd LED shows.
    // Cross-domain status wires (declared before first use to keep
    // synthesis logs free of HDL-5373 used-before-declaration noise).
    wire player_enable_sys;
    wire storage_error_sys;
    wire video_fault_sys;
    wire audio_fault_sys;
    wire [3:0] video_error_sys;

    // Storage failures surface the real ingest error code (SD init
    // 0x01-0x0c, filesystem 0x10-0x22, decoder 0x31-0x38, loader 0x41-0x46)
    // so the status bar and UART distinguish "no card" (CMD0 timeout) from
    // "no FAT/no BMP"; the blanket 0xFE remains for code-less failures.
    wire [7:0] storage_reported_error;
    // Publish an immutable code and its valid flag together in sys_clk.
    // The previous direct ingest_error_code -> UART path crossed mem_clk
    // without a coherent snapshot and failed final setup timing.
    sticky_error_cdc u_storage_error_snapshot (
        .src_clk(mem_clk), .src_rst_n(mem_rst_n),
        .src_error(ingest_done &&
                   (ingest_error_stage != 0 || ingest_error_code != 0 ||
                    image_complete != 4'hf)),
        .src_code(ingest_error_code), .src_latched(storage_error_mem),
        .dst_clk(sys_clk), .dst_rst_n(ctrl_rst_n),
        .dst_valid(storage_error_sys), .dst_code(storage_reported_error)
    );
    wire [7:0] reported_error = storage_error_sys ? storage_reported_error :
                                 config_fatal_error ? config_error_code :
                                 video_fault_sys ? {4'b0, video_error_sys} :
                                 audio_fault_sys ? 8'h71 :
                                 8'd0;

    // Auto-slideshow flag and fault code for the bottom status bar.
    wire auto_enabled_video;
    wire [7:0] reported_error_video;
    sync_2ff u_auto_status_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(auto_enabled), .sync_out(auto_enabled_video)
    );
    genvar err_bit;
    generate
        for (err_bit = 0; err_bit < 8; err_bit = err_bit + 1) begin : g_status_err
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(reported_error[err_bit]),
                .sync_out(reported_error_video[err_bit])
            );
        end
    endgenerate

    // Info overlay state: the subtitle shows only in normal mode and never
    // during emergency; SW2 picks the arrival sentence. Registered in
    // sys_clk first so the synchronizers sample flops, not logic.
    reg sub_show_sys;
    reg sub_arrive_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            sub_show_sys <= 1'b0;
            sub_arrive_sys <= 1'b0;
        end else begin
            sub_show_sys <= ~emerg_sw & ~demo_mode;
            sub_arrive_sys <= arrive_sw;
        end
    end
    wire sub_show_video;
    wire sub_arrive_video;
    sync_2ff u_sub_show_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(sub_show_sys), .sync_out(sub_show_video)
    );
    sync_2ff u_sub_arrive_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(sub_arrive_sys), .sync_out(sub_arrive_video)
    );

    // Audio source: the background song plays only in the normal-mode
    // operating state (SW1..SW3 all off), the arrival chime in the normal-mode
    // arrival state, the siren whenever SW3 is down; demo keeps the per-image
    // melody. Each level is registered in sys_clk, then one sync_2ff; the
    // priority is resolved here, so a one-clock skew between the three
    // synchronizers only lasts one pixel clock.
    reg song_mode_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            song_mode_sys <= 1'b0;
        else
            song_mode_sys <= ~demo_mode & ~arrive_sw & ~emerg_sw;
    end
    reg arrive_audio_sys;
    reg emerg_audio_sys;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            arrive_audio_sys <= 1'b0;
            emerg_audio_sys <= 1'b0;
        end else begin
            arrive_audio_sys <= arrive_sw & ~demo_mode & ~emerg_sw;
            emerg_audio_sys <= emerg_sw;
        end
    end
    wire song_mode_video;
    sync_2ff u_song_mode_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(song_mode_sys), .sync_out(song_mode_video)
    );
    wire arrive_audio_video;
    sync_2ff u_arrive_audio_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(arrive_audio_sys), .sync_out(arrive_audio_video)
    );
    wire emerg_audio_video;
    sync_2ff u_emerg_audio_sync (
        .clk(video_clk), .rst_n(pix_rst_n),
        .async_in(emerg_audio_sys), .sync_out(emerg_audio_video)
    );

    // Status bar inputs that live in sys_clk (brightness step, overlay mode,
    // slideshow period step) are packed into one register and synchronized
    // bit by bit; status_bar_24 only latches the word once it is stable.
    wire [5:0] status_cfg_sys;
    wire [5:0] status_cfg_video;
    status_bar_cfg_pack u_status_cfg (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .demo_mode(demo_mode), .arrive_sw(arrive_sw), .emerg_sw(emerg_sw),
        .bright_lvl(brightness_level), .period_ms(config_period_ms),
        .cfg(status_cfg_sys)
    );
    genvar status_bit;
    generate
        for (status_bit = 0; status_bit < 6; status_bit = status_bit + 1) begin : g_status_cfg_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(status_cfg_sys[status_bit]),
                .sync_out(status_cfg_video[status_bit])
            );
        end
    endgenerate

    // Picture resolutions (BMP header sizes, 4 x 40-bit BCD from the ingest
    // stage in mem_clk). The table is written only while the card is read,
    // and an ingest run happens only after reset, so it is quasi-static by
    // the time the picture is on screen; each bit still crosses through its
    // own sync_2ff, and status_bar_24 latches the word only when it has been
    // stable, exactly like the status_cfg word above.
    wire [159:0] image_res_video;
    genvar res_bit;
    generate
        for (res_bit = 0; res_bit < 160; res_bit = res_bit + 1) begin : g_res_sync
            sync_2ff u_sync (
                .clk(video_clk), .rst_n(pix_rst_n),
                .async_in(image_res_mem[res_bit]),
                .sync_out(image_res_video[res_bit])
            );
        end
    endgenerate

    // Overlay stack, bottom of the frame upwards: status bar (rows 444-479),
    // subtitle band (404-443), spectrum bars (340-403).

    // E5 extension: audio spectrum bars. The analyser runs Goertzel bins on
    // the song's 16 pentatonic "guzheng strings" over the samples the bridge
    // actually transmits (one tap pulse per sample); the overlay draws 16
    // rainbow bars right above the subtitle band. Combinational overlay - the
    // timing bundle stays aligned. Shown only in the operating state
    // (song_mode_video): hidden on arrival, in demo mode and during emergency.
    wire [23:0] video_rgb_wave;
    wire audio_pcm_tap_valid;
    wire signed [15:0] audio_pcm_tap_left;
    wire [111:0] spectrum_bar_target;
    audio_spectrum_goertzel u_audio_spectrum (
        .clk(video_clk), .rst_n(pix_rst_n),
        .pcm_tap_valid(audio_pcm_tap_valid), .pcm_tap_left(audio_pcm_tap_left),
        .bar_target(spectrum_bar_target), .fifo_overflow()
    );
    audio_spectrum_bars #(
        .BAR_X(64), .BAR_Y(340), .BAR_H(64), .BAR_W(24)
    ) u_spectrum_bars (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(video_vs), .de(video_de),
        .rgb_in(video_rgb), .pixel_x(video_x),
        .enable(song_mode_video),
        .bar_target(spectrum_bar_target),
        .rgb_out(video_rgb_wave), .bars_active()
    );

    // E1 extension: scrolling passenger subtitle on a dimmed band - operating
    // "下一站..." (white) or, with SW2, arrival "某某站到了..." (yellow); hidden
    // in demo mode and during emergency. Registered stage - rgb and the whole
    // timing bundle shift by the same clock.
    wire [23:0] video_rgb_sub;
    wire video_hs_sub;
    wire video_vs_sub;
    wire video_de_sub;
    wire [9:0] video_x_sub;
    subtitle_scroll_24 #(
        .BAND_Y(404), .BAND_H(40), .SCROLL_STEP(2), .H_ACT(640),
        .DIM_SHIFT(1), .COLOR_RUN(24'hFFFFFF), .COLOR_ARRIVE(24'hFFE14D)
    ) u_subtitle (
        .clk(video_clk), .rst_n(pix_rst_n),
        .show(sub_show_video), .msg_sel(sub_arrive_video),
        .hsync(video_hs), .vsync(video_vs), .de(video_de),
        .pixel_x(video_x), .rgb_in(video_rgb_wave),
        .hsync_out(video_hs_sub), .vsync_out(video_vs_sub),
        .de_out(video_de_sub), .pixel_x_out(video_x_sub),
        .rgb_out(video_rgb_sub), .subtitle_active()
    );

    // Bottom status bar, shown in every mode: volume, brightness, overlay
    // mode, auto-slideshow flag, period step and image number (or the fault
    // code). Registered stage drawn last, so it sits on top of every other
    // overlay; rgb and the whole timing bundle shift by the same clock.
    wire [23:0] video_rgb_bar;
    wire video_hs_bar;
    wire video_vs_bar;
    wire video_de_bar;
    wire [9:0] video_x_bar;
    status_bar_24 #(.BAR_Y(444)) u_status_bar (
        .clk(video_clk), .rst_n(pix_rst_n),
        .volume(volume_video), .bright_lvl(status_cfg_video[5:4]),
        .mode(status_cfg_video[3:2]), .auto_on(auto_enabled_video),
        .period_lvl(status_cfg_video[1:0]), .image_index(active_index_video),
        .image_res_bcd(image_res_video),
        .error_code(reported_error_video),
        .hsync(video_hs_sub), .vsync(video_vs_sub), .de(video_de_sub),
        .pixel_x(video_x_sub), .rgb_in(video_rgb_sub),
        .hsync_out(video_hs_bar), .vsync_out(video_vs_bar),
        .de_out(video_de_bar), .pixel_x_out(video_x_bar),
        .rgb_out(video_rgb_bar)
    );

    // Session brightness, applied once at the very end of the overlay chain.
    // The picture, the spectrum bars, the subtitle and the status bar are all
    // drawn at full brightness above; scaling here dims every displayed pixel
    // by the same factor. The factor is confirmed at frame start inside the
    // stage, so one frame never mixes two brightness steps.
    wire [23:0] video_rgb_bright;
    video_brightness_scale u_bright_scale (
        .clk(video_clk), .rst_n(pix_rst_n),
        .vsync(video_vs_bar), .brightness(brightness_pix),
        .rgb_in(video_rgb_bar), .rgb_out(video_rgb_bright)
    );

    media_hdmi_audio_bridge u_hdmi_audio_bridge (
        .pixel_clk(video_clk), .pixel_rst_n(pix_rst_n),
        .video_hsync(video_hs_bar), .video_vsync(video_vs_bar),
        .video_de(video_de_bar), .video_x(video_x_bar),
        .video_rgb(video_rgb_bright),
        .media_id(active_index_video), .volume(volume_video),
        .song_mode(song_mode_video),
        .arrive_audio(arrive_audio_video), .emerg_audio(emerg_audio_video),
        .pcm_tap_valid(audio_pcm_tap_valid), .pcm_tap_left(audio_pcm_tap_left),
        .channel0_symbol(audio_symbol0),
        .channel1_symbol(audio_symbol1),
        .channel2_symbol(audio_symbol2),
        .sequence_error(audio_sequence_error),
        .tone_overflow(audio_tone_overflow),
        .pcm_contract_error(audio_pcm_contract_error),
        .blip_active(audio_blip_active)
    );

    hdmi_tmds_eg4_phy u_hdmi_audio_phy (
        .pixel_clk(video_clk), .pixel_rst_n(pix_rst_n),
        .clk_5x(pixel_clk_5x), .clk_5x_rst_n(pix_5x_rst_n),
        .channel0_symbol(audio_symbol0),
        .channel1_symbol(audio_symbol1),
        .channel2_symbol(audio_symbol2),
        .tmds_clock_p(HDMI_CLK_P), .tmds_data0_p(HDMI_D0_P),
        .tmds_data1_p(HDMI_D1_P), .tmds_data2_p(HDMI_D2_P),
        .phase_error(audio_phy_phase_error)
    );

    sync_2ff u_player_enable_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(player_enable_mem), .sync_out(player_enable_sys)
    );
    sync_2ff u_video_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(video_error != 0), .sync_out(video_fault_sys)
    );
    sync_2ff u_audio_fault_sys (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .async_in(audio_sequence_error || audio_tone_overflow ||
                  audio_pcm_contract_error ||
                  audio_phy_phase_error),
        .sync_out(audio_fault_sys)
    );

    genvar error_bit_index;
    generate
        for (error_bit_index = 0; error_bit_index < 4;
             error_bit_index = error_bit_index + 1) begin : g_video_error_sync
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(video_error[error_bit_index]),
                .sync_out(video_error_sys[error_bit_index])
            );
        end
    endgenerate

    // UART status reporter: boot banner, image switch lines, parameter
    // menu changes and fault codes on the board USB-UART at 115200 8N1.
    wire [1:0] active_index_sys;
    genvar uart_bit;
    generate
        for (uart_bit = 0; uart_bit < 2; uart_bit = uart_bit + 1) begin : g_media_sys
            sync_2ff u_sync (
                .clk(sys_clk), .rst_n(ctrl_rst_n),
                .async_in(active_index[uart_bit]),
                .sync_out(active_index_sys[uart_bit])
            );
        end
    endgenerate

    reg [1:0] active_index_sys_q;
    always @(posedge sys_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            active_index_sys_q <= 2'd0;
        else
            active_index_sys_q <= active_index_sys;
    end
    wire switch_evt = (active_index_sys != active_index_sys_q);


    uart_status_reporter #(.CLKS_PER_BIT(434)) u_uart_report (
        .clk(sys_clk), .rst_n(ctrl_rst_n),
        .enable(player_enable_sys), .media_id(active_index_sys),
        .volume(config_volume), .period_ms(config_period_ms),
        .auto_enabled(auto_enabled),
        .switch_event(switch_evt), .menu_event(menu_evt),
        .menu_kind(menu_kind), .error_code(reported_error),
        .bright_event(key3_long_press && config_ready),
        .bright_value(brightness_sys),
        .uart_tx(uart_tx_o)
    );

    // Competition-facing playback indicators with fault-code priority:
    // storage all-on, config code, audio 4'hD, video code, save-ok 4'b0101,
    // then the running bank/auto/auto state.
    assign led = storage_error_sys ? 4'hf :
                 config_fatal_error ? {1'b1,config_error_code[2:0]} :
                 audio_fault_sys ? 4'hd :
                 video_fault_sys ? video_error_sys :
                 config_save_ok_latched ? 4'b0101 :
                 player_enable_sys ? {1'b0, auto_enabled, active_index} :
                 {1'b0, 1'b0, &image_complete_sys,
                  mem_locked & video_locked};

endmodule
