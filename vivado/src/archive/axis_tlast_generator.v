module axis_tlast_generator (
    input  wire        aclk,
    input  wire        aresetn,
    
    // --- 输入接口 (连接 FFT 输出) ---
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,   
    
    // --- 输出接口 (连接 FIFO 输入) ---
    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,    
    input  wire        m_axis_tready
);

    parameter DATA_WIDTH = 32;
    parameter CNT_WIDTH  = 13; 
    parameter FRAME_LEN  = 8192; 

    reg [CNT_WIDTH-1:0] frame_cnt;

    // -------------------------------------------------------
    // 1. 计数器逻辑 (独立运行，不受下游背压影响)
    // -------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            frame_cnt <= {CNT_WIDTH{1'b0}};
        end 
        // 【关键修改】：只要上游(FFT)有数据有效，我就计数！
        // 不管下游(FIFO)是否准备好，帧的节奏不能乱。
        else if (s_axis_tvalid && m_axis_tready) begin 

            if (frame_cnt == FRAME_LEN - 1) 
                frame_cnt <= {CNT_WIDTH{1'b0}}; 
            else 
                frame_cnt <= frame_cnt + 1'b1;
        end
    end

    // -------------------------------------------------------
    // 2. 握手与输出逻辑
    // -------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axis_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            s_axis_tready <= 1'b0;
        end else begin
            
            // A. 生成 Tlast (基于当前的计数值)
            // 当数到最后一个点时，Tlast 必须拉高
            if (frame_cnt == FRAME_LEN - 1)
                m_axis_tlast <= 1'b1;
            else
                m_axis_tlast <= 1'b0;

            // B. 数据透传逻辑
            // 只有当下游(FIFO)准备好时，我才把数据给它
            if (m_axis_tready && s_axis_tvalid) begin
                m_axis_tdata  <= s_axis_tdata;
                m_axis_tvalid <= 1'b1;
            end else begin
                // 如果下游没准备好，Valid 拉低 (FIFO 不会收数据)
                // 但注意：Tlast 在上面已经根据计数器生成了，
                // 一旦下游 Ready，它就会在正确的数据点收到 Tlast。
                m_axis_tvalid <= 1'b0; 
            end

            // C. 对上游(FFT)的 Ready 控制
            // 【策略选择】：
            // 为了防止 FIFO 溢出导致数据错乱，通常这里还是要看下游 Ready。
            // 但由于我们刚才把计数器解耦了，所以这里可以安全地阻塞上游。
            // 也就是：FIFO 满了 -> 阻塞 FFT -> FFT 暂停输出 -> 等我处理完 -> 继续。
            s_axis_tready <= m_axis_tready; 
        end
    end

endmodule
