module tlast_gen #(
    parameter DATA_WIDTH = 16,      // 数据位宽，保持与DDS一致
    parameter FFT_LEN  = 8192       // FFT点数，对应计数器最大值
)(
    input  wire        aclk,        // 系统时钟 (100MHz 或 150MHz)
    input  wire        aresetn,     // 复位信号 (低电平有效)

    // 输入侧：连接 DDS 的输出 (S_AXIS)
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tready,
    input  wire [DATA_WIDTH*2-1:0] s_axis_tdata, // I/Q两路数据，通常DDS输出是拼接的

    // 输出侧：连接 FFT 的输入 (M_AXIS)
    output reg         m_axis_tvalid, // 直接透传 DDS 的 valid
    output reg         m_axis_tlast,  // 【核心功能】生成的帧结束信号
    output reg [DATA_WIDTH*2-1:0] m_axis_tdata // 直接透传数据
);

    // 定义计数器，8192需要13位宽 (2^13 = 8192)
    reg [12:0] cnt; 

    // 核心逻辑：生成 TLAST
    always @(posedge aclk) begin
        if (!aresetn) begin
            cnt <= 0;
            m_axis_tlast <= 1'b0;
        end 
        else begin
            // 默认拉低 TLAST
            m_axis_tlast <= 1'b0; 

            // 只有当数据有效传输时 (Valid & Ready)，计数器才工作
            if (s_axis_tvalid && s_axis_tready) begin
                if (cnt == FFT_LEN - 1) begin
                    cnt <= 0;
                    m_axis_tlast <= 1'b1; // 数满一帧，拉高 TLAST
                end 
                else begin
                    cnt <= cnt + 1;
                end
            end
        end
    end

    // 数据与 Valid 信号直接透传 (Wire 连接即可，这里为了模块完整性写成 reg)
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 0;
        end else begin
            m_axis_tvalid <= s_axis_tvalid;
            m_axis_tdata  <= s_axis_tdata;
        end
    end

endmodule
