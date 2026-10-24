module axis_mux_2to1 #(
    parameter DATA_WIDTH = 32
)(
    input  wire                     aclk,
    input  wire                     aresetn,
    // 选择信号: 0 -> s00(AD), 1 -> s01(DDS)
    input  wire                     sel,
    // S00 输入（AD通路）
    input  wire [DATA_WIDTH-1:0]    s00_tdata,
    input  wire                     s00_tvalid,
    output wire                     s00_tready,
    input  wire                     s00_tlast,
    // S01 输入（DDS+mixer通路）
    input  wire [DATA_WIDTH-1:0]    s01_tdata,
    input  wire                     s01_tvalid,
    output wire                     s01_tready,
    input  wire                     s01_tlast,
    // 输出到FFT
    output reg [DATA_WIDTH-1:0]     m_tdata,
    output reg                      m_tvalid,
    input  wire                     m_tready,
    output reg                      m_tlast
);
    // Accept a beat when the holding register is empty, or when it is being
    // drained in the same cycle (pop + load -> full throughput, no loss).
    wire can_accept = (~m_tvalid) | m_tready;
    assign s00_tready = (~sel) & can_accept;
    assign s01_tready = ( sel) & can_accept;
    wire                    in_valid = sel ? s01_tvalid : s00_tvalid;
    wire [DATA_WIDTH-1:0]   in_tdata = sel ? s01_tdata : s00_tdata;
    wire                    in_tlast = sel ? s01_tlast : s00_tlast;
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_tdata  <= {DATA_WIDTH{1'b0}};
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
        end
        else if (in_valid && can_accept) begin
            // load (or re-load while the previous beat is being consumed)
            m_tdata  <= in_tdata;
            m_tlast  <= in_tlast;
            m_tvalid <= 1'b1;
        end
        else if (m_tvalid && m_tready) begin
            // register drained, nothing new to load
            m_tvalid <= 1'b0;
        end
    end
endmodule