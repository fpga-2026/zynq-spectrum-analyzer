module hanning_window (
    input                 aclk,
    input                 aresetn,
    
    // AXI-Stream Input (From Mixer)
    input  [31:0]         s_axis_tdata,
    input                 s_axis_tvalid,
    input                 s_axis_tlast,  
    output reg            s_axis_tready,
    
    // ROM接口
    output reg [12:0]     rom_addr,
    input  [15:0]         rom_dout,      
    
    // AXI-Stream Output (To FFT)
    output reg [31:0]     m_axis_tdata,
    output reg            m_axis_tvalid,
    output reg            m_axis_tlast,  
    input                 m_axis_tready
);

parameter FFT_LEN = 8192;

reg [12:0] addr_cnt;

wire input_handshake  = s_axis_tvalid && s_axis_tready;
wire output_handshake = m_axis_tvalid && m_axis_tready;

// 寄存输入数据，等待ROM输出延迟一拍的窗系数
reg [31:0] s_tdata_reg;
reg        s_tlast_reg;
reg        s_tvalid_reg;

// 16bit定点饱和函数
function signed [15:0] saturate_16bit;
    input signed [31:0] din;
begin
    if(din > $signed(32'h00007FFF))
        saturate_16bit = 16'h7FFF;
    else if(din < $signed(32'hFFFF8000))
        saturate_16bit = 16'h8000;
    else
        saturate_16bit = din[15:0];
end
endfunction

// ======================
// 地址计数器 + ROM地址预补偿，跟随上游tlast帧同步
// ======================
always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        addr_cnt <= 13'd0;
        rom_addr <= 13'd0;
    end 
    else if(input_handshake) begin
        rom_addr <= addr_cnt; // 提前送出当前序号，补偿ROM 1clk延迟
        if(s_axis_tlast) begin
            addr_cnt <= 13'd0;
        end else begin
            addr_cnt <= addr_cnt + 13'd1;
        end
    end
end

// 拆分I/Q，乘以汉宁窗系数
wire signed [15:0] curr_i   = s_tdata_reg[15:0];
wire signed [15:0] curr_q   = s_tdata_reg[31:16];
wire signed [15:0] win_coef = rom_dout; 

wire signed [31:0] mult_i_res = curr_i * win_coef;
wire signed [31:0] mult_q_res = curr_q * win_coef;

wire signed [15:0] i_sat = saturate_16bit(mult_i_res);
wire signed [15:0] q_sat = saturate_16bit(mult_q_res);

// ======================
// AXI-Stream握手逻辑，修复反压，透传tlast
// ======================
always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
        s_axis_tready <= 1'b1;
        s_tdata_reg   <= 32'd0;
        s_tlast_reg   <= 1'b0;
        s_tvalid_reg  <= 1'b0;
        
        m_axis_tdata  <= 32'd0;
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
    end else begin
        //下游握手成功，清除输出valid
        if(output_handshake) begin
            m_axis_tvalid <= 1'b0;
        end

        //上游握手成功，寄存数据、tlast，锁住上游
        if(input_handshake) begin
            s_tdata_reg  <= s_axis_tdata;
            s_tlast_reg  <= s_axis_tlast;
            s_tvalid_reg <= 1'b1;
            s_axis_tready <= 1'b0;
        end

        //输出饱和结果，同步透传tlast
        if(s_tvalid_reg && !m_axis_tvalid) begin
            m_axis_tdata  <= {q_sat, i_sat};
            m_axis_tlast  <= s_tlast_reg;
            m_axis_tvalid <= 1'b1;
            s_tvalid_reg <= 1'b0;
            s_axis_tready <= 1'b1; //释放上游，可以接收下一个采样
        end
    end
end

endmodule
