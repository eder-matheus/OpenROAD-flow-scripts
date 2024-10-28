utl::set_metrics_stage "detailedroute__{}"
source $::env(SCRIPTS_DIR)/load.tcl
load_design 5_1_grt.odb 5_1_grt.sdc
if {![grt::have_routes]} {
  error "Global routing failed, run `make gui_grt` and load $::global_route_congestion_report \
        in DRC viewer to view congestion"
}
erase_non_stage_variables route
set_propagated_clock [all_clocks]

set additional_args ""
append_env_var additional_args dbProcessNode -db_process_node 1
append_env_var additional_args OR_SEED -or_seed 1
append_env_var additional_args OR_K -or_k 1
append_env_var additional_args MIN_ROUTING_LAYER -bottom_routing_layer 1
append_env_var additional_args MAX_ROUTING_LAYER -top_routing_layer 1
append_env_var additional_args VIA_IN_PIN_MIN_LAYER -via_in_pin_bottom_layer 1
append_env_var additional_args VIA_IN_PIN_MAX_LAYER -via_in_pin_top_layer 1
append_env_var additional_args DISABLE_VIA_GEN -disable_via_gen 0
append_env_var additional_args REPAIR_PDN_VIA_LAYER -repair_pdn_vias 1
append_env_var additional_args DETAILED_ROUTE_END_ITERATION -droute_end_iter 1

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

set arguments [expr {[env_var_exists_and_non_empty DETAILED_ROUTE_ARGS] ? $::env(DETAILED_ROUTE_ARGS) : \
 [concat $additional_args {-drc_report_iter_step 5}]}]

set all_args [concat [list \
  -output_drc $::env(REPORTS_DIR)/5_route_drc.rpt \
  -output_maze $::env(RESULTS_DIR)/maze.log] \
  $arguments]

log_cmd detailed_route {*}$all_args

set_global_routing_layer_adjustment $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER) 0.5
set_routing_layers -signal $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER)

if {[env_var_equals DRT_INCREMENTAL_TIMING_REPAIR 1]} {
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
    puts "Repair setup and hold violations..."

    if {[repair_timing_helper]} {
      if {[info exist ::env(DETAILED_METRICS)]} {
        report_metrics 5 "detailed route post repair timing"
      }

      if {[env_var_exists_and_non_empty PRE_GLOBAL_ROUTE]} {
        source $::env(PRE_GLOBAL_ROUTE)
      }
      fast_route

      # Running DPL to fix overlapped instances
      # Run to get modified net by DPL
      global_route -start_incremental
      detailed_placement
      # Route only the modified net by DPL
      global_route -end_incremental -congestion_report_file $::env(REPORTS_DIR)/congestion_post_drt_repair_timing.rpt

      detailed_route {*}$all_args
    }
  }
}

if {![env_var_equals SKIP_ANTENNA_REPAIR_POST_DRT 1]} {
  puts "Repair antenna violations..."
  set repair_antennas_iters 1
  if {[repair_antennas]} {
    detailed_route {*}$all_args
  }
  while {[check_antennas] && $repair_antennas_iters < 5} {
    repair_antennas
    detailed_route {*}$all_args
    incr repair_antennas_iters
  }
}

if { [env_var_exists_and_non_empty POST_DETAIL_ROUTE_TCL] } {
  source $::env(POST_DETAIL_ROUTE_TCL)
}

check_antennas -report_file $env(REPORTS_DIR)/drt_antennas.log

if {![design_is_routed]} {
  error "Design has unrouted nets."
}

write_db $::env(RESULTS_DIR)/5_2_route.odb
