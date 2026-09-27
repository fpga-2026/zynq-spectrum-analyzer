module axis_add_tlast #(
    parameter CNT_MAX = 1024,
    parameter DATA_WIDTH = 32   //新增位宽参数
)(
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,

    output reg  [DATA_WIDTH-1:0]  m_axis_tdata,
    output reg          m_axis_tvalid,
    input  wire         m_axis_tready,
    output reg          m_axis_tlast
);

reg [9:0] cnt;
assign s_axis_tready = m_axis_tready;

always @(posedge aclk or negedge aresetn) begin
    if(!aresetn) begin
        cnt <= 10'd0;
        m_axis_tdata <= {DATA_WIDTH{1'b0}};
        m_axis_tvalid <= 1'b0;
        m_axis_tlast <= 1'b0;
    end
    else begin
        if(s_axis_tvalid && s_axis_tready) begin
            cnt <= cnt + 10'd1;
            m_axis_tdata <= s_axis_tdata;
            m_axis_tvalid <= 1'b1;
            if(cnt == CNT_MAX - 1) begin
                m_axis_tlast <= 1'b1;
                cnt <= 10'd0;
            end
            else begin
                m_axis_tlast <= 1'b0;
            end
        end
        else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast <= 1'b0;
        end
    end

end

endmodule
