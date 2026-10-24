`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// da_wave_gen : 256-point periodic sine for AD9708
//
//   f_out = 32 MHz / 256 = 125.000 kHz
//   sin_rom[i] = round(128 + 84*sin(2*pi*i/256)),  i = 0..255
//
//   * exactly one sine period in the 256-entry table
//   * mean = 128.0  -> no residual DC after the ADC's -128
//   * sin_rom[255]=126 -> sin_rom[0]=128 -> sin_rom[1]=130, so the
//     255->0 wrap is phase-continuous (no jump, no cusp)
//   * same +/-84 LSB amplitude (44..212) as the previous table, so the
//     analog loopback level does not change
// -----------------------------------------------------------------------------
module da_wave_gen(
    input  wire        clk_32m,    // 32 MHz, PS FCLK_CLK2
    input  wire        rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 da_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 32000000" *)
    output wire        da_clk,     // AD9708 clock
    output reg  [7:0]  da_data     // AD9708 8-bit data
);

    assign da_clk = clk_32m;

    // 256 x 8 sine ROM, one full period
    reg [7:0] sin_rom [0:255];

    initial begin
        sin_rom[0] = 8'd128; sin_rom[1] = 8'd130; sin_rom[2] = 8'd132; sin_rom[3] = 8'd134; sin_rom[4] = 8'd136; sin_rom[5] = 8'd138; sin_rom[6] = 8'd140; sin_rom[7] = 8'd142;
        sin_rom[8] = 8'd144; sin_rom[9] = 8'd146; sin_rom[10] = 8'd148; sin_rom[11] = 8'd150; sin_rom[12] = 8'd152; sin_rom[13] = 8'd154; sin_rom[14] = 8'd156; sin_rom[15] = 8'd158;
        sin_rom[16] = 8'd160; sin_rom[17] = 8'd162; sin_rom[18] = 8'd164; sin_rom[19] = 8'd166; sin_rom[20] = 8'd168; sin_rom[21] = 8'd169; sin_rom[22] = 8'd171; sin_rom[23] = 8'd173;
        sin_rom[24] = 8'd175; sin_rom[25] = 8'd176; sin_rom[26] = 8'd178; sin_rom[27] = 8'd180; sin_rom[28] = 8'd181; sin_rom[29] = 8'd183; sin_rom[30] = 8'd184; sin_rom[31] = 8'd186;
        sin_rom[32] = 8'd187; sin_rom[33] = 8'd189; sin_rom[34] = 8'd190; sin_rom[35] = 8'd192; sin_rom[36] = 8'd193; sin_rom[37] = 8'd194; sin_rom[38] = 8'd195; sin_rom[39] = 8'd197;
        sin_rom[40] = 8'd198; sin_rom[41] = 8'd199; sin_rom[42] = 8'd200; sin_rom[43] = 8'd201; sin_rom[44] = 8'd202; sin_rom[45] = 8'd203; sin_rom[46] = 8'd204; sin_rom[47] = 8'd205;
        sin_rom[48] = 8'd206; sin_rom[49] = 8'd206; sin_rom[50] = 8'd207; sin_rom[51] = 8'd208; sin_rom[52] = 8'd208; sin_rom[53] = 8'd209; sin_rom[54] = 8'd209; sin_rom[55] = 8'd210;
        sin_rom[56] = 8'd210; sin_rom[57] = 8'd211; sin_rom[58] = 8'd211; sin_rom[59] = 8'd211; sin_rom[60] = 8'd212; sin_rom[61] = 8'd212; sin_rom[62] = 8'd212; sin_rom[63] = 8'd212;
        sin_rom[64] = 8'd212; sin_rom[65] = 8'd212; sin_rom[66] = 8'd212; sin_rom[67] = 8'd212; sin_rom[68] = 8'd212; sin_rom[69] = 8'd211; sin_rom[70] = 8'd211; sin_rom[71] = 8'd211;
        sin_rom[72] = 8'd210; sin_rom[73] = 8'd210; sin_rom[74] = 8'd209; sin_rom[75] = 8'd209; sin_rom[76] = 8'd208; sin_rom[77] = 8'd208; sin_rom[78] = 8'd207; sin_rom[79] = 8'd206;
        sin_rom[80] = 8'd206; sin_rom[81] = 8'd205; sin_rom[82] = 8'd204; sin_rom[83] = 8'd203; sin_rom[84] = 8'd202; sin_rom[85] = 8'd201; sin_rom[86] = 8'd200; sin_rom[87] = 8'd199;
        sin_rom[88] = 8'd198; sin_rom[89] = 8'd197; sin_rom[90] = 8'd195; sin_rom[91] = 8'd194; sin_rom[92] = 8'd193; sin_rom[93] = 8'd192; sin_rom[94] = 8'd190; sin_rom[95] = 8'd189;
        sin_rom[96] = 8'd187; sin_rom[97] = 8'd186; sin_rom[98] = 8'd184; sin_rom[99] = 8'd183; sin_rom[100] = 8'd181; sin_rom[101] = 8'd180; sin_rom[102] = 8'd178; sin_rom[103] = 8'd176;
        sin_rom[104] = 8'd175; sin_rom[105] = 8'd173; sin_rom[106] = 8'd171; sin_rom[107] = 8'd169; sin_rom[108] = 8'd168; sin_rom[109] = 8'd166; sin_rom[110] = 8'd164; sin_rom[111] = 8'd162;
        sin_rom[112] = 8'd160; sin_rom[113] = 8'd158; sin_rom[114] = 8'd156; sin_rom[115] = 8'd154; sin_rom[116] = 8'd152; sin_rom[117] = 8'd150; sin_rom[118] = 8'd148; sin_rom[119] = 8'd146;
        sin_rom[120] = 8'd144; sin_rom[121] = 8'd142; sin_rom[122] = 8'd140; sin_rom[123] = 8'd138; sin_rom[124] = 8'd136; sin_rom[125] = 8'd134; sin_rom[126] = 8'd132; sin_rom[127] = 8'd130;
        sin_rom[128] = 8'd128; sin_rom[129] = 8'd126; sin_rom[130] = 8'd124; sin_rom[131] = 8'd122; sin_rom[132] = 8'd120; sin_rom[133] = 8'd118; sin_rom[134] = 8'd116; sin_rom[135] = 8'd114;
        sin_rom[136] = 8'd112; sin_rom[137] = 8'd110; sin_rom[138] = 8'd108; sin_rom[139] = 8'd106; sin_rom[140] = 8'd104; sin_rom[141] = 8'd102; sin_rom[142] = 8'd100; sin_rom[143] = 8'd98;
        sin_rom[144] = 8'd96; sin_rom[145] = 8'd94; sin_rom[146] = 8'd92; sin_rom[147] = 8'd90; sin_rom[148] = 8'd88; sin_rom[149] = 8'd87; sin_rom[150] = 8'd85; sin_rom[151] = 8'd83;
        sin_rom[152] = 8'd81; sin_rom[153] = 8'd80; sin_rom[154] = 8'd78; sin_rom[155] = 8'd76; sin_rom[156] = 8'd75; sin_rom[157] = 8'd73; sin_rom[158] = 8'd72; sin_rom[159] = 8'd70;
        sin_rom[160] = 8'd69; sin_rom[161] = 8'd67; sin_rom[162] = 8'd66; sin_rom[163] = 8'd64; sin_rom[164] = 8'd63; sin_rom[165] = 8'd62; sin_rom[166] = 8'd61; sin_rom[167] = 8'd59;
        sin_rom[168] = 8'd58; sin_rom[169] = 8'd57; sin_rom[170] = 8'd56; sin_rom[171] = 8'd55; sin_rom[172] = 8'd54; sin_rom[173] = 8'd53; sin_rom[174] = 8'd52; sin_rom[175] = 8'd51;
        sin_rom[176] = 8'd50; sin_rom[177] = 8'd50; sin_rom[178] = 8'd49; sin_rom[179] = 8'd48; sin_rom[180] = 8'd48; sin_rom[181] = 8'd47; sin_rom[182] = 8'd47; sin_rom[183] = 8'd46;
        sin_rom[184] = 8'd46; sin_rom[185] = 8'd45; sin_rom[186] = 8'd45; sin_rom[187] = 8'd45; sin_rom[188] = 8'd44; sin_rom[189] = 8'd44; sin_rom[190] = 8'd44; sin_rom[191] = 8'd44;
        sin_rom[192] = 8'd44; sin_rom[193] = 8'd44; sin_rom[194] = 8'd44; sin_rom[195] = 8'd44; sin_rom[196] = 8'd44; sin_rom[197] = 8'd45; sin_rom[198] = 8'd45; sin_rom[199] = 8'd45;
        sin_rom[200] = 8'd46; sin_rom[201] = 8'd46; sin_rom[202] = 8'd47; sin_rom[203] = 8'd47; sin_rom[204] = 8'd48; sin_rom[205] = 8'd48; sin_rom[206] = 8'd49; sin_rom[207] = 8'd50;
        sin_rom[208] = 8'd50; sin_rom[209] = 8'd51; sin_rom[210] = 8'd52; sin_rom[211] = 8'd53; sin_rom[212] = 8'd54; sin_rom[213] = 8'd55; sin_rom[214] = 8'd56; sin_rom[215] = 8'd57;
        sin_rom[216] = 8'd58; sin_rom[217] = 8'd59; sin_rom[218] = 8'd61; sin_rom[219] = 8'd62; sin_rom[220] = 8'd63; sin_rom[221] = 8'd64; sin_rom[222] = 8'd66; sin_rom[223] = 8'd67;
        sin_rom[224] = 8'd69; sin_rom[225] = 8'd70; sin_rom[226] = 8'd72; sin_rom[227] = 8'd73; sin_rom[228] = 8'd75; sin_rom[229] = 8'd76; sin_rom[230] = 8'd78; sin_rom[231] = 8'd80;
        sin_rom[232] = 8'd81; sin_rom[233] = 8'd83; sin_rom[234] = 8'd85; sin_rom[235] = 8'd87; sin_rom[236] = 8'd88; sin_rom[237] = 8'd90; sin_rom[238] = 8'd92; sin_rom[239] = 8'd94;
        sin_rom[240] = 8'd96; sin_rom[241] = 8'd98; sin_rom[242] = 8'd100; sin_rom[243] = 8'd102; sin_rom[244] = 8'd104; sin_rom[245] = 8'd106; sin_rom[246] = 8'd108; sin_rom[247] = 8'd110;
        sin_rom[248] = 8'd112; sin_rom[249] = 8'd114; sin_rom[250] = 8'd116; sin_rom[251] = 8'd118; sin_rom[252] = 8'd120; sin_rom[253] = 8'd122; sin_rom[254] = 8'd124; sin_rom[255] = 8'd126;

    end

    // One table step per 32 MHz clock; 8-bit address wraps at 256.
    reg [7:0] addr;

    // Launch addr/da_data on the FALLING edge of clk_32m.
    // da_clk is clk_32m, and the AD9708 latches on its rising edge, so the
    // data is stable for half a period (15.6 ns) before the DAC samples it.
    // This removes the same-edge launch/skew sensitivity that made the DC
    // jump between bitstreams; see AD支路修复说明.md section 15.
    always @(negedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            addr    <= 8'd0;
            da_data <= 8'd128;
        end
        else begin
            addr    <= addr + 8'd1;
            da_data <= sin_rom[addr];
        end
    end

endmodule
