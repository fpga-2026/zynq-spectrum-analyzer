module ad9280_capture (
    input  wire       ad_clk,      // 32MHz，来自 AD9280 或 PLL
    input  wire       rst_n,       // 复位
    input  wire [7:0] ad_data,     // AD9280 原始数据
    
    // 写入异步 FIFO 接口
    output reg        fifo_wr_en,
    output reg [15:0] fifo_wr_data,
    output wire       fifo_full
);

    // 简单状态机或直接打拍，确保数据稳定
    always @(posedge ad_clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_en   <= 1'b0;
            fifo_wr_data <= 16'd0;
        end else begin
            if (!fifo_full) begin
                // 采集时先不做复杂运算，保留原始精度
                // 高8位补0，低8位放数据，留给下游做符号扩展
                fifo_wr_data <= {8'd0, ad_data}; 
                fifo_wr_en   <= 1'b1;
            end else begin
                fifo_wr_en <= 1'b0; // FIFO 满了就暂停采集
            end
        end
    end

endmodule
