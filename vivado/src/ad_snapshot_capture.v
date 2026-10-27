`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ad_snapshot_capture
//
//   Stage 0-2 fix for the AD path.  The AD9280 is free-running at 32 MSPS and
//   cannot be back-pressured, so whenever the shared downstream (FFT / packet
//   FIFO / DMA / UART print) stalls, the old "~fifo_full" write enable silently
//   dropped ADC samples.  A frame that straddles such a drop is no longer 8192
//   consecutive 31.25 ns-spaced samples, so its DFT gets leakage, a DC step and
//   a dense noise floor.
//
//   This module makes each captured frame a *snapshot* of exactly FRAME_LEN
//   consecutive ADC samples:
//
//     IDLE  : waiting.  ADC writes are blocked, samples are discarded.
//     FLUSH : assert fifo_rst for FLUSH_CYCLES, clearing any stale FIFO data.
//     WAIT  : hold until the FIFO reports wr_rst_busy deasserted.
//     CAP   : pass exactly FRAME_LEN samples (one per 32 MHz clock) to the FIFO.
//     -> back to IDLE (frame_done pulse).
//
//   The FIFO is deepened to >= FRAME_LEN (16384), so even if the downstream
//   stops completely during the capture, occupancy can never exceed FRAME_LEN
//   and "full" never asserts inside a frame -> no sample can be lost.
//
//   No reset is applied to the DDS path, the AXIS mux, the FFT, the packet
//   FIFO, the peak detector or the DMA.  Only the AD-side FIFO and the
//   fifo_to_axis converter are re-armed per frame.
// -----------------------------------------------------------------------------
module ad_snapshot_capture #(
    parameter integer FRAME_LEN    = 8192,   // ADC samples per captured frame
    parameter integer FLUSH_CYCLES = 64      // fifo_rst width, 32 MHz cycles
)(
    input  wire        wr_clk,        // 32 MHz, PS FCLK_CLK2
    input  wire        wr_rst_n,      // 32 MHz domain reset, active low

    input  wire        cap_start,     // level from PS GPIO; rising edge = one snapshot
    input  wire [7:0]  ad_data,       // registered ADC data from ad9280_axis_sample
    input  wire        ad_wr_en,      // sample-module write enable (~fifo_full)
    input  wire        fifo_full,     // FIFO full (defensive)
    input  wire        wr_rst_busy,   // FIFO reset-busy, same 32 MHz domain

    output wire [7:0]  fifo_din,      // to fifo_generator_0/din
    output wire        fifo_wr_en,    // to fifo_generator_0/wr_en
    output reg         fifo_rst,      // to fifo_generator_0/rst (OR'd with power-on reset)
    output reg         frame_done     // 1-cycle pulse; optional (ILA / spare GPIO)
);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_FLUSH = 2'd1,
                     S_WAIT  = 2'd2,
                     S_CAP   = 2'd3;

    reg [1:0]  state;
    // cap_start comes from the PS GPIO (100 MHz domain); this 2-flop
    // synchroniser captures it in the 32 MHz domain.  ASYNC_REG tells the tools
    // to place the two flops together and treat the first stage as asynchronous
    // (see stage0_2/cdc_timing.xdc for the matching false path).
    (* ASYNC_REG = "TRUE" *) reg [1:0] cap_sync;
    reg [6:0]  flush_cnt;
    reg [12:0] sample_cnt;

    // Rising edge of cap_start, synchronised into the 32 MHz domain.
    wire cap_rise = (cap_sync == 2'b01);

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) cap_sync <= 2'b00;
        else           cap_sync <= {cap_sync[0], cap_start};
    end

    // Combinational write path: data and enable are aligned in the same cycle,
    // so exactly FRAME_LEN samples are written with no off-by-one.
    assign fifo_din   = ad_data;
    assign fifo_wr_en = (state == S_CAP) && ad_wr_en && !fifo_full;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            state      <= S_IDLE;
            flush_cnt  <= 7'd0;
            sample_cnt <= 13'd0;
            fifo_rst   <= 1'b0;
            frame_done <= 1'b0;
        end
        else begin
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    fifo_rst <= 1'b0;
                    if (cap_rise) begin
                        flush_cnt <= 7'd0;
                        fifo_rst  <= 1'b1;
                        state     <= S_FLUSH;
                    end
                end

                S_FLUSH: begin
                    fifo_rst <= 1'b1;
                    if (flush_cnt == FLUSH_CYCLES[6:0] - 7'd1) begin
                        fifo_rst <= 1'b0;
                        state    <= S_WAIT;
                    end
                    else begin
                        flush_cnt <= flush_cnt + 7'd1;
                    end
                end

                S_WAIT: begin
                    fifo_rst <= 1'b0;
                    if (!wr_rst_busy) begin
                        sample_cnt <= 13'd0;
                        state      <= S_CAP;
                    end
                end

                S_CAP: begin
                    if (fifo_wr_en) begin
                        if (sample_cnt == FRAME_LEN[12:0] - 13'd1) begin
                            frame_done <= 1'b1;
                            state      <= S_IDLE;
                        end
                        else begin
                            sample_cnt <= sample_cnt + 13'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule