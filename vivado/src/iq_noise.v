module iq_noise_mixer (
    input  wire        aclk,
    input  wire        aresetn,

    // AXI-Stream Input
    input  wire [31:0] s_axis_tdata,
     input  wire        s_axis_tvalid,
     output wire        s_axis_tready,

    // AXI-Stream Output
     output wire [31:0] m_axis_tdata,
     output wire        m_axis_tvalid,
     output wire        m_axis_tlast,
     input  wire        m_axis_tready,

    // Noise Control
    input  wire        noise_en,    // noise enable (AXI GPIO): 1=add noise, 0=bypass
    input  wire [15:0] noise_raw,
    input  wire [3:0]  noise_level
);

    // Frame Counter: count only handshaked (tvalid && tready) samples
    (* mark_debug = "true" *) reg [12:0] frame_cnt;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            frame_cnt <= 13'd0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            if (frame_cnt == 13'd8191)
                frame_cnt <= 13'd0;
            else
                frame_cnt <= frame_cnt + 13'd1;
        end
    end

    // --- Data Split & Mixing (combinational) ---
    wire signed [15:0] dds_i = s_axis_tdata[15:0];
    wire signed [15:0] dds_q = s_axis_tdata[31:16];

    (* mark_debug = "true" *) wire signed [16:0] noise_bipolar;
    // noise_raw actual range is 0..16383 (LFSR >>>3); subtract its midpoint 8192
    // to obtain a symmetric, zero-mean range [-8192,+8191] (no DC -> no bin-0 peak).
    assign noise_bipolar = $signed({1'b0, noise_raw}) - 17'sd8192;

    (* mark_debug = "true" *) wire signed [16:0] noise_scaled;
    assign noise_scaled = (noise_level == 4'd0) ? noise_bipolar : (noise_bipolar >>> noise_level);

    wire signed [17:0] dds_i_ext = {{2{dds_i[15]}}, dds_i};
    wire signed [17:0] dds_q_ext = {{2{dds_q[15]}}, dds_q};
    wire signed [17:0] noise_ext = noise_en ? {{1{noise_scaled[16]}}, noise_scaled} : 18'sd0;

    (* mark_debug = "true" *) wire signed [17:0] sum_i = dds_i_ext + noise_ext;
    (* mark_debug = "true" *) wire signed [17:0] sum_q = dds_q_ext + noise_ext;

    // saturate (combinational, signed comparison)
    function signed [15:0] saturate;
        input signed [17:0] val;
        begin
            if (val > 18'sd32767)
                saturate = 16'sd32767;
            else if (val < -18'sd32768)
                saturate = -16'sd32768;
            else
                saturate = val[15:0];
        end
    endfunction

    (* mark_debug = "true" *) wire signed [15:0] out_i = saturate(sum_i);
    (* mark_debug = "true" *) wire signed [15:0] out_q = saturate(sum_q);

    // ========= AXI-Stream 0-latency pass-through (combinational) =========
    assign s_axis_tready  = m_axis_tready;
    assign m_axis_tvalid  = s_axis_tvalid;
    assign m_axis_tdata   = {out_q, out_i};
    assign m_axis_tlast   = (frame_cnt == 13'd8191) && s_axis_tvalid;

endmodule
