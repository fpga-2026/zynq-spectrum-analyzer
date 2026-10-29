# =============================================================================
# bd_fix_cdc.tcl  --  remove the 32 MHz -> 100 MHz reset crossing
#
# Timing report (impl_1, after the AD-snapshot changes):
#   clk_fpga_2 -> clk_fpga_0 : WNS -2.415 ns, TNS -103.2 ns, 49 failing / 63
#       source      : ad_snapshot_capture_0/inst/fifo_rst_reg/C   (32 MHz)
#       destination : fifo_to_axis_8to32_0/inst/mem_reg_*/RAM*/WE (100 MHz)
#       requirement : 1.250 ns  (FCLK_CLK2 rise 218.750 -> FCLK_CLK0 rise 220.000)
#
# Root cause: bd_stage1_2.tcl connected the per-frame reset pulse
#     fifo_to_axis_8to32_0/aresetn = flush_and/Res = peripheral_aresetn AND ~fifo_rst
# where fifo_rst is generated in the 32 MHz capture clock domain.  A reset that
# crosses into the 100 MHz domain like that is an asynchronous CDC and cannot
# meet a 1.25 ns setup requirement.
#
# Fix: drop the per-frame reset of the 8->32 converter and put that reset back on
# the power-on reset net (its original connection).  This is functionally safe:
# the converter's frame counter is self-consistent because every snapshot
# delivers exactly FRAME_LEN = 8192 beats, so m_axis_tlast stays aligned; the
# only effect of the removed reset was to flush up to 8 buffered beats, which
# merely rotates the frame (harmless for the periodic AD signal).
#
# Run in the Block Design Tcl Console, then re-generate the bitstream:
#     source {D:/fpga_/AD add/stage0_2/bd_fix_cdc.tcl}
# =============================================================================

proc unpin {pin_path} {
    set p [get_bd_pins -quiet $pin_path]
    if {[llength $p] == 0} { puts "  (skip, pin not found: $pin_path)"; return }
    set n [get_bd_nets -quiet -of_objects $p]
    if {[llength $n] > 0} {
        disconnect_bd_net $n $p
        puts "  unconnected $pin_path"
    }
}

puts "== restore fifo_to_axis_8to32_0/aresetn on the power-on reset =="
unpin fifo_to_axis_8to32_0/aresetn
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins fifo_to_axis_8to32_0/aresetn]

# flush_and is now unused (its output was the only load).  Remove it so the
# 32 MHz fifo_rst net no longer reaches into the 100 MHz domain through it.
foreach c {flush_and flush_not} {
    set cell [get_bd_cells -quiet $c]
    if {[llength $cell] > 0} {
        delete_bd_objs $cell
        puts "  deleted unused cell $c"
    }
}

puts "== check the remaining loads of the 32 MHz fifo_rst =="
set fr [get_bd_pins -quiet ad_snapshot_capture_0/fifo_rst]
if {[llength $fr]} {
    set nets [get_bd_nets -quiet -of_objects $fr]
    foreach n $nets {
        puts "  net $n drives:"
        foreach p [get_bd_pins -quiet -of_objects $n] {
            if {$p ne $fr} { puts "      $p" }
        }
    }
}
puts "(expected: only flush_or/Op2 -> fifo_generator_0/rst, which the FIFO IP"
puts " treats as an asynchronous reset - it passes timing)"

validate_bd_design
save_bd_design
puts "== done. Re-generate the bitstream, then check WNS in impl_1 =="