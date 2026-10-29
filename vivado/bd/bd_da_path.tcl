# =============================================================================
# bd_da_sweep.tcl  (v3)  --  insert da_path_mux between da_wave_gen and the DA
#                            pins, and make axi_gpio_0 a 32-bit sweep register
#
#   axi_gpio_0/gpio_io_o[31:0] --> da_path_mux_0/ctrl
#   da_wave_gen/da_data[7:0]   --> da_path_mux_0/da_in
#                                 da_path_mux_0/da_out[7:0] --> da_data (port)
#
#   ctrl[31]=0 : pass-through -> the stock 125.000 kHz calibrator (unchanged)
#   ctrl[31]=1 : programmable tone, f = ctrl[30:0] * 32 MHz / 2^31
#
# v3: fixes the v2 bug where a deleted cell object was reused (that produced
#     "Invalid option value '/da_path_mux_0'").  It now deletes any previous mux
#     cell first, creates a fresh one, prints and validates every pin by literal
#     name, and only then connects anything.
#
# PREREQUISITE: da_path_mux.v is in Design Sources and the BD was closed and
# reopened after adding it.   Run:
#     source {D:/fpga_/AD add/stage0_2/bd_da_sweep.tcl}
# =============================================================================

proc cell_name {c} {
    set s "$c"
    return [string trimleft $s "/"]
}

puts "== 0. refresh the source list =="
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- 1. GPIO ----
puts "== 1. axi_gpio_0 -> 32-bit output register =="
if {![llength [get_bd_cells -quiet axi_gpio_0]]} { error "axi_gpio_0 not found" }
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH   {32} \
    CONFIG.C_IS_DUAL      {0} \
    CONFIG.C_ALL_INPUTS   {0} \
    CONFIG.C_ALL_OUTPUTS  {1} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
] [get_bd_cells axi_gpio_0]
puts "   C_GPIO_WIDTH = [get_property CONFIG.C_GPIO_WIDTH [get_bd_cells axi_gpio_0]]"

# ------------------------------------------------------- 2. drop ad9833 port --
puts "== 2. remove the unused ad9833 external port =="
set ap [get_bd_ports -quiet ad9833]
if {[llength $ap]} {
    foreach n [get_bd_nets -quiet -of_objects $ap] { catch { disconnect_bd_net $n $ap } }
    delete_bd_objs $ap
    puts "   removed ad9833[2:0]"
} else {
    puts "   (not present)"
}

# --------------------------------------------------- 3. clean out old muxes ---
puts "== 3. remove any previous da_path_mux cell =="
foreach c [get_bd_cells -quiet -filter {NAME =~ *da_path_mux*}] {
    set cp [get_bd_pins -quiet -of_objects $c]
    if {[llength $cp]} {
        foreach n [get_bd_nets -quiet -of_objects $cp] { catch { disconnect_bd_net $n $cp } }
    }
    puts "   deleting [cell_name $c]"
    delete_bd_objs $c
}

# ------------------------------------------------------------ 4. create it ---
puts "== 4. create da_path_mux_0 from the RTL =="
if {[catch {create_bd_cell -type module -reference da_path_mux da_path_mux_0} emsg]} {
    puts "   -type module failed: $emsg"
    puts "   retrying with -type module_ref"
    if {[catch {create_bd_cell -type module_ref -reference da_path_mux da_path_mux_0} emsg2]} {
        error "create_bd_cell failed both ways: $emsg2 -> check da_path_mux.v is in Design Sources and reopen the BD"
    }
}
set mp [get_bd_pins -quiet -of_objects [get_bd_cells da_path_mux_0]]
puts "   pins: [llength $mp]"
foreach p $mp { puts "      $p" }
if {[llength $mp] < 5} {
    error "da_path_mux_0 has only [llength $mp] pins: module definition not visible (add da_path_mux.v, close+reopen the BD, re-run)"
}

# ------------------------------------------------- validate every needed pin --
puts "== 5. validate pins by literal name =="
foreach leaf {clk_32m rst_n ctrl da_in da_out} {
    if {![llength [get_bd_pins -quiet "da_path_mux_0/$leaf"]]} {
        error "pin da_path_mux_0/$leaf is missing"
    }
    puts "   ok  da_path_mux_0/$leaf"
}

set dw [get_bd_cells -quiet -filter {NAME =~ *da_wave_gen*}]
if {![llength $dw]} { error "da_wave_gen cell not found" }
set dwn [cell_name [lindex $dw 0]]
puts "   da_wave_gen cell = $dwn"
foreach leaf {clk_32m rst_n da_data} {
    if {![llength [get_bd_pins -quiet "${dwn}/$leaf"]]} { error "pin ${dwn}/$leaf missing" }
}

# ------------------------------------------------------ 6. clock and reset ---
puts "== 6. clock / reset (pin to pin, same sources as da_wave_gen) =="
# From the BD netlist: da_wave_gen_0/clk_32m is driven by
# processing_system7_0/FCLK_CLK2 and da_wave_gen_0/rst_n by
# proc_sys_reset_1/peripheral_aresetn.  Connecting source-pin to pin is
# deterministic; querying net objects here proved unreliable.
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK2]      [get_bd_pins da_path_mux_0/clk_32m]
connect_bd_net [get_bd_pins proc_sys_reset_1/peripheral_aresetn] [get_bd_pins da_path_mux_0/rst_n]
puts "   clk <- processing_system7_0/FCLK_CLK2"
puts "   rst <- proc_sys_reset_1/peripheral_aresetn"

# ----------------------------------------------------------------- 7. ctrl ---
puts "== 7. ctrl <- axi_gpio_0/gpio_io_o =="
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins da_path_mux_0/ctrl]

# ------------------------------------------------------------- 8. data path --
puts "== 8. rewire the DA data path =="
if {![llength [get_bd_ports -quiet da_data]]} { error "top-level port da_data not found" }
foreach n [get_bd_nets -quiet -of_objects [get_bd_ports da_data]] {
    catch { disconnect_bd_net $n [get_bd_ports da_data] }
}
connect_bd_net [get_bd_pins "${dwn}/da_data"] [get_bd_pins da_path_mux_0/da_in]
connect_bd_net [get_bd_pins da_path_mux_0/da_out] [get_bd_ports da_data]
puts "   ${dwn}/da_data -> da_path_mux_0/da_in ; da_path_mux_0/da_out -> da_data"

# ---------------------------------------------------------------- 9. verify --
puts "== 9. verify connections =="
foreach leaf {clk_32m rst_n ctrl da_in da_out} {
    set p [get_bd_pins -quiet "da_path_mux_0/$leaf"]
    set nn [get_bd_nets -quiet -of_objects $p]
    puts [format "   %-22s <- %s" $leaf $nn]
}

validate_bd_design
save_bd_design
puts "== done =="
puts "   next: delete ad.xdc from the constraints (the ad9833 port is gone),"
puts "         Generate Bitstream -> Export Hardware -> Regenerate BSP"