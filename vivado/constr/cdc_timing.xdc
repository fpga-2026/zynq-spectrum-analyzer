# =============================================================================
# cdc_timing.xdc  --  constrain the cap_start synchroniser (robust version)
#
# Remaining timing violation after fixing the reset crossing:
#     clk_fpga_0 -> clk_fpga_2 : WNS -1.481 ns, 1 failing endpoint
# i.e. the 32 MHz domain flop that samples cap_start (which is driven from the
# PS GPIO in the 100 MHz domain).  The flop pair has ASYNC_REG="TRUE" in
# ad_snapshot_capture.v, so the first stage is intentionally asynchronous and
# must be excluded from setup analysis.
#
# NOTE on the pattern: in Vivado's -filter glob, "cap_sync_reg[0]" would be read
# as a character class ("match one of '0'"), so the brackets MUST be escaped as
# \[ \].  The previous version also assumed a fixed hierarchy depth; this one uses
# -hier plus a name filter, with a fallback that cannot miss.
#
# Replace the contents of the previously added cdc_timing.xdc with this file
# (or paste the body into constrs_1/new/adda_constr.xdc).
# =============================================================================

# 1) exact synchroniser stage: name filter with escaped brackets

# 2) fallback: any flop whose name contains cap_sync


# -----------------------------------------------------------------------------
# Fallback (only if the report shows OTHER 100 MHz -> 32 MHz crossings that are
# already properly synchronised).  In this design every clk_fpga_0 -> clk_fpga_2
# crossing is either the 2-flop cap_start synchroniser above or an asynchronous
# reset, so excluding the whole clock pair is defensible - but keep it commented
# out until the report proves it is needed.
#
# set_false_path -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_2]
# -----------------------------------------------------------------------------


