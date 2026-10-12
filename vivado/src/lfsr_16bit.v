module lfsr_16bit (
    input  wire        clk,
    input  wire        rst_n,
    output reg signed [15:0] noise_out
);
    // 4 个独立的 16-bit LFSR
    reg [15:0] lfsr_0, lfsr_1, lfsr_2, lfsr_3;
    
    // 4 个不同的反馈多项式，确保它们互不相关
    wire fb_0 = lfsr_0[15] ^ lfsr_0[13] ^ lfsr_0[12] ^ lfsr_0[10];
    wire fb_1 = lfsr_1[15] ^ lfsr_1[14] ^ lfsr_1[12] ^ lfsr_1[11];
    wire fb_2 = lfsr_2[15] ^ lfsr_2[14] ^ lfsr_2[13] ^ lfsr_2[11];
    wire fb_3 = lfsr_3[15] ^ lfsr_3[13] ^ lfsr_3[11] ^ lfsr_3[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 给 4 个 LFSR 不同的非零种子
            lfsr_0 <= 16'hABCD;
            lfsr_1 <= 16'h1234;
            lfsr_2 <= 16'h5678;
            lfsr_3 <= 16'hDEAD;
            noise_out <= 16'sd0;
        end
        else begin
            // 4 个 LFSR 同时移位
            lfsr_0 <= {lfsr_0[14:0], fb_0};
            lfsr_1 <= {lfsr_1[14:0], fb_1};
            lfsr_2 <= {lfsr_2[14:0], fb_2};
            lfsr_3 <= {lfsr_3[14:0], fb_3};
            
            // 【核心】将 4 个 LFSR 当作有符号数相加
            // 4 个均匀分布相加 = 近似高斯分布！
            // 相加后位宽会变成 18 bit，我们截取中间 16 bit 作为输出
            noise_out <= ({lfsr_0[15], lfsr_0} + 
                          {lfsr_1[15], lfsr_1} + 
                          {lfsr_2[15], lfsr_2} + 
                          {lfsr_3[15], lfsr_3}) >>> 3; // 右移2位防止溢出，保持16-bit范围
        end
    end
endmodule
