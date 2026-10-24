`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// axis_fft_peak_detect  --  PIPELINED version (drop-in, same ports/params)
//
// Why: the original module was purely combinational in its datapath
//      s_axis_tdata -> 16x16 signed multiply (x2) -> 32-bit add
//                   -> 32-bit compare -> mux -> register
//   all inside one 100 MHz cycle (10 ns).  That is the reported worst setup
//   path (WNS -2.478 ns).  The AXIS pass-through itself was already 0-latency
//   and is UNCHANGED here, so the FFT / packet FIFO / DMA chain is untouched.
//
// Fix: split the work into three registered stages
//   A : capture the sample, its frame index and tlast
//   B : magnitude squared  (multiply-add is now its own stage)
//   C : compare against the running maximum, latch the result at tlast
// The peak result is therefore valid 2 cycles after tlast instead of in the
// same cycle - irrelevant, because software reads peak_mag_sq/peak_idx over
// slow AXI (GPIO) long after the frame ended.
//
// Interface is bit-identical to the original, so the Block Design needs no
// change: just replace the file contents and re-synthesise.
// -----------------------------------------------------------------------------
module axis_fft_peak_detect #(
    parameter DATA_W  = 16,
    parameter FRAME_N = 8192
)(
    input  wire                aclk,
    input  wire                aresetn,
    // FFT input AXI-Stream
    input  wire [2*DATA_W-1:0] s_axis_tdata,
    input  wire                s_axis_tvalid,
    input  wire                s_axis_tlast,
    output wire                s_axis_tready,
    // Pass-through to downstream (raw FFT samples, 0-latency)
    output wire [2*DATA_W-1:0] m_axis_tdata,
    output wire                m_axis_tvalid,
    output wire                m_axis_tlast,
    input  wire                m_axis_tready,
    // Peak result, valid after tlast
    output reg  [31:0]         peak_mag_sq,
    output reg  [12:0]         peak_idx
);
    // ---- 0-latency AXIS pass-through: unchanged, must stay combinational ----
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;
    wire signed [DATA_W-1:0] re = s_axis_tdata[DATA_W-1:0];
    wire signed [DATA_W-1:0] im = s_axis_tdata[2*DATA_W-1:DATA_W];
    wire beat = s_axis_tvalid && s_axis_tready;
    // stage A registers
    reg signed [DATA_W-1:0] re_a, im_a;
    reg [12:0] cnt_a;
    reg        last_a, valid_a;
    // stage B registers
    reg [31:0] mag_b;
    reg [12:0] cnt_b;
    reg        last_b, valid_b;
    // running maximum + frame counter
    reg [31:0] max_mag_sq;
    reg [12:0] max_idx;
    reg [12:0] cnt;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            re_a <= {DATA_W{1'b0}}; im_a <= {DATA_W{1'b0}};
            cnt_a <= 13'd0; last_a <= 1'b0; valid_a <= 1'b0;
            mag_b <= 32'd0; cnt_b <= 13'd0; last_b <= 1'b0; valid_b <= 1'b0;
            max_mag_sq <= 32'd0; max_idx <= 13'd0; cnt <= 13'd0;
            peak_mag_sq <= 32'd0; peak_idx <= 13'd0;
        end
        else begin
            /* ---- stage A ---- */
            if (beat) begin
                re_a    <= re;
                im_a    <= im;
                cnt_a   <= cnt;                       /* index of this beat    */
                last_a  <= s_axis_tlast;
                valid_a <= 1'b1;
                cnt     <= s_axis_tlast ? 13'd0 : (cnt + 13'd1);
            end
            else begin
                valid_a <= 1'b0;
            end
            /* ---- stage B : 16x16 multiply + 32-bit add, registered ---- */
            valid_b <= valid_a;
            if (valid_a) begin
                mag_b  <= re_a * re_a + im_a * im_a;
                cnt_b  <= cnt_a;
                last_b <= last_a;
            end
            /* ---- stage C : compare + latch ---- */
            if (valid_b) begin
                if (last_b) begin
                    /* tlast beat itself is a candidate (max not updated yet) */
                    if (mag_b > max_mag_sq) begin
                        peak_mag_sq <= mag_b;
                        peak_idx    <= cnt_b;
                    end
                    else begin
                        peak_mag_sq <= max_mag_sq;
                        peak_idx    <= max_idx;
                    end
                    max_mag_sq <= 32'd0;
                    max_idx    <= 13'd0;
                end
                else if (mag_b > max_mag_sq) begin
                    max_mag_sq <= mag_b;
                    max_idx    <= cnt_b;
                end
            end
        end
    end
endmodule