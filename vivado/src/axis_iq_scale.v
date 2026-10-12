module axis_iq_scale #(
    parameter DATA_W = 16,
    parameter SHIFT  = 3
)(
    input  wire               aclk,
    input  wire               aresetn,
    // AXI-Stream slave
    input  wire [2*DATA_W-1:0] s_axis_tdata,
    input  wire               s_axis_tvalid,
    output wire               s_axis_tready,
    // AXI-Stream master
    output wire [2*DATA_W-1:0] m_axis_tdata,
    output wire               m_axis_tvalid,
    input  wire               m_axis_tready,

    input wire                scale_en
);

wire signed [DATA_W-1:0] i_in, q_in;

assign {i_in, q_in} = s_axis_tdata;

// ========= 修改点：固定直通，不再判断scale_en =========
wire signed [DATA_W-1:0] i_out = i_in;
wire signed [DATA_W-1:0] q_out = q_in;
// ================================================

assign m_axis_tdata  = {i_out, q_out};
assign m_axis_tvalid = s_axis_tvalid;
assign s_axis_tready = m_axis_tready;

endmodule
