module ad9280_axis_sample(
    input  wire        wr_clk,       // 32MHz full_clk2
    input  wire        wr_rst_n,
    input  wire        fifo_full,    // 来自异步FIFO full信号

    // AD9280 硬件端口
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ad_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 32000000" *)
    output wire        ad_clk,       // AD驱动时钟，输出到引脚A3
    input  wire [7:0]  ad_data,      // AD并行采样数据
    input  wire        ad_otr,       // 量程溢出标志（预留，可ILA观测）

    // 输出到异步FIFO写端口
    output reg  [7:0]  fifo_din,
    output reg         fifo_wr_en
);

assign ad_clk = wr_clk; // AD时钟同步32M

always @(posedge wr_clk) begin
    if(!wr_rst_n) begin
        fifo_din   <= 8'd0;
        fifo_wr_en <= 1'b0;
    end
    else begin
        fifo_din   <= ad_data;
        fifo_wr_en <= ~fifo_full; // FIFO未满才写入，防止溢出丢数据
    end
end

endmodule
