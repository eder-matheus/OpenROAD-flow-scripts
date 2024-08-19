utl::set_metrics_stage "detailedroute__{}"
source $::env(SCRIPTS_DIR)/load.tcl
if { [info exists ::env(USE_WXL)]} {
  set db_file 4_cts.odb
} else {
  set db_file 5_1_grt.odb
}
load_design $db_file 4_cts.sdc
set_propagated_clock [all_clocks]

set additional_args ""
if { [info exists ::env(dbProcessNode)]} {
  append additional_args " -db_process_node $::env(dbProcessNode)"
}
if { [info exists ::env(OR_SEED)]} {
  append additional_args " -or_seed $::env(OR_SEED)"
}
if { [info exists ::env(OR_K)]} {
  append additional_args " -or_k $::env(OR_K)"
}

if { [info exists ::env(MIN_ROUTING_LAYER)]} {
  append additional_args " -bottom_routing_layer $::env(MIN_ROUTING_LAYER)"
}
if { [info exists ::env(MAX_ROUTING_LAYER)]} {
  append additional_args " -top_routing_layer $::env(MAX_ROUTING_LAYER)"
}
if { [info exists ::env(VIA_IN_PIN_MIN_LAYER)]} {
  append additional_args " -via_in_pin_bottom_layer $::env(VIA_IN_PIN_MIN_LAYER)"
}
if { [info exists ::env(VIA_IN_PIN_MAX_LAYER)]} {
  append additional_args " -via_in_pin_top_layer $::env(VIA_IN_PIN_MAX_LAYER)"
}
if { [info exists ::env(DISABLE_VIA_GEN)]} {
  append additional_args " -disable_via_gen"
}
if { [info exists ::env(REPAIR_PDN_VIA_LAYER)]} {
  append additional_args " -repair_pdn_vias $::env(REPAIR_PDN_VIA_LAYER)"
}

append additional_args " -save_guide_updates -verbose 1"

# DETAILED_ROUTE_ARGS is used when debugging detailed, route, e.g. append
# "-droute_end_iter 5" to look at routing violations after only 5 iterations,
# speeding up iterations on a problem where detailed routing doesn't converge
# or converges slower than expected.
#
# If DETAILED_ROUTE_ARGS is not specified, save out progress report a
# few iterations after the first two iterations. The first couple of
# iterations would produce very large .drc reports without interesting
# information for the user.
#
# The idea is to have a policy that gives progress information soon without
# having to go spelunking in Tcl or modify configuration scripts, while
# not having to wait too long or generating large useless reports.

set arguments [expr {[info exists ::env(DETAILED_ROUTE_ARGS)] ? $::env(DETAILED_ROUTE_ARGS) : \
 [concat $additional_args {-drc_report_iter_step 5}]}]

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc.rpt \
  -output_maze $::env(RESULTS_DIR)/maze.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

set_global_routing_layer_adjustment $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER) 0.5
set_routing_layers -signal $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER)

if { [info exists ::env(DRT_INCREMENTAL_REPAIR)] } {
  # Run extraction and STA
  if {[info exist ::env(RCX_RULES)]} {

    # Set RC corner for RCX
    # Set in config.mk
    if {[info exist ::env(RCX_RC_CORNER)]} {
      set rc_corner $::env(RCX_RC_CORNER)
    }

    # RCX section
    define_process_corner -ext_model_index 0 X
    extract_parasitics -ext_model_file $::env(RCX_RULES)

    # Write Spef
    write_spef $::env(RESULTS_DIR)/5_drt.spef
    file delete $::env(DESIGN_NAME).totCap

    # Read Spef for OpenSTA
    read_spef $::env(RESULTS_DIR)/5_drt.spef

    # Repair timing using detailed route parasitics from RCX
    # process user settings
    set additional_args "-verbose"
    append_env_var additional_args SKIP_PIN_SWAP -skip_pin_swap 0
    append_env_var additional_args SKIP_GATE_CLONING -skip_gate_cloning 0
    puts "repair_timing [join $additional_args " "]"
    repair_timing {*}$additional_args

    if {[info exist ::env(DETAILED_METRICS)]} {
      report_metrics 5 "detailed route post repair timing"
    }

    # Running DPL to fix overlapped instances
    # Run to get modified net by DPL
    global_route -start_incremental
    detailed_placement
    # Route only the modified net by DPL
    global_route -end_incremental  -congestion_report_file $::env(REPORTS_DIR)/congestion_post_drt_repair_timing.rpt
  }
}

check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

write_db $::env(RESULTS_DIR)/5_2_route.odb
