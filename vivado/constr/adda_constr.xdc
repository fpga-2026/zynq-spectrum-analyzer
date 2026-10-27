#==================== DA侧：AD9708 ====================
set_property PACKAGE_PIN Y11 [get_ports da_clk]
set_property PACKAGE_PIN Y9 [get_ports {da_data[0]}]
set_property PACKAGE_PIN Y8 [get_ports {da_data[1]}]
set_property PACKAGE_PIN W10 [get_ports {da_data[2]}]
set_property PACKAGE_PIN W9 [get_ports {da_data[3]}]
set_property PACKAGE_PIN V11 [get_ports {da_data[4]}]
set_property PACKAGE_PIN V10 [get_ports {da_data[5]}]
set_property PACKAGE_PIN Y13 [get_ports {da_data[6]}]
set_property PACKAGE_PIN Y12 [get_ports {da_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports da_clk]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {da_data[7]}]

#==================== AD侧：AD9280 ====================
set_property PACKAGE_PIN V13 [get_ports ad_clk]
set_property PACKAGE_PIN W15 [get_ports {ad_data[0]}]
set_property PACKAGE_PIN V15 [get_ports {ad_data[1]}]
set_property PACKAGE_PIN Y14 [get_ports {ad_data[2]}]
set_property PACKAGE_PIN W14 [get_ports {ad_data[3]}]
set_property PACKAGE_PIN W13 [get_ports {ad_data[4]}]
set_property PACKAGE_PIN V12 [get_ports {ad_data[5]}]
set_property PACKAGE_PIN U15 [get_ports {ad_data[6]}]
set_property PACKAGE_PIN U14 [get_ports {ad_data[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports ad_clk]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ad_data[7]}]

# AD量程溢出标志 ad_otr
set_property PACKAGE_PIN U13 [get_ports ad_otr]
set_property IOSTANDARD LVCMOS33 [get_ports ad_otr]

# ==================== AD/DA source-synchronous IO timing (2026-10-24) ====================
# da_clk / ad_clk are forwarded 32 MHz clocks (FCLK_CLK2, 31.25 ns period).
# da_data is launched on the FALLING edge of clk_32m in da_wave_gen, so it is
# stable for half a period (15.6 ns) before the AD9708 rising edge.
# The delay values below are conservative starting points; replace them with
# the AD9708/AD9280 datasheet tSU/tH/tOD plus PCB skew for the final build.
# If Vivado reports the forwarded clock as unrelated to clk_32m, use
# report_clocks to find the FCLK_CLK2 clock name and reference that clock
# instead, or use create_generated_clock -source <FCLK_CLK2 pin>.
create_clock -period 31.250 -name da_clk_fwd [get_ports da_clk]
create_clock -period 31.250 -name ad_clk_fwd [get_ports ad_clk]

set_output_delay -clock da_clk_fwd -max 5.000 [get_ports {da_data[*]}]
set_output_delay -clock da_clk_fwd -min -1.000 [get_ports {da_data[*]}]

set_input_delay -clock ad_clk_fwd -max 10.000 [get_ports {ad_data[*]}]
set_input_delay -clock ad_clk_fwd -min 1.000 [get_ports {ad_data[*]}]

set_false_path -to [get_cells -hier -filter {NAME =~ *cap_sync_reg*}]

set_false_path -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_2]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets da_clk_OBUF]
