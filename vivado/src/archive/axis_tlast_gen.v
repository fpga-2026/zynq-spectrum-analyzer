module axis_tlast_gen
#(
    parameter LEN = 512
)(
input               aclk,
input       [31:0]  s_tdata,
input               s_tvalid,

output reg  [31:0]  m_tdata,
output reg          m_tvalid,
output reg          m_tlast
);

reg [9:0] cnt;

always @(posedge aclk) begin
    if(!s_tvalid) begin
        cnt <= 10'd0;
        m_tlast <= 1'b0;
    end
    else begin
        m_tdata  <= s_tdata;
        m_tvalid <= s_tvalid;
        cnt <= cnt + 10'd1;
        if(cnt == LEN - 2) begin
            m_tlast <= 1'b1;
        end
        else begin
            m_tlast <= 1'b0;
        end
    end
end

endmodule
