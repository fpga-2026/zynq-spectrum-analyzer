module dds_to_axis#(
    parameter WIDTH = 32,
    parameter LEN   = 512
)(
    input  aclk,
    input  [WIDTH-1:0] dds_tdata,
    output reg [WIDTH-1:0] m_axis_tdata,
    output reg m_axis_tlast,
    output reg m_axis_tvalid
);

reg [9:0] cnt;

always @(posedge aclk) begin
    cnt <= cnt + 10'd1;
    m_axis_tdata <= dds_tdata;
    m_axis_tvalid <= 1'b1;
    m_axis_tlast <= (cnt == (LEN-1));
    if(cnt == LEN-1) cnt <= 10'd0;
end

endmodule
