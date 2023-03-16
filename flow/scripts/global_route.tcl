utl::set_metrics_stage "globalroute__{}"
source $::env(SCRIPTS_DIR)/load.tcl
load_design 4_cts.odb 4_cts.sdc "Starting global routing"

if {[info exist env(PRE_GLOBAL_ROUTE)]} {
  source $env(PRE_GLOBAL_ROUTE)
}

puts "Using resource adjustment $env(RESOURCES_ADJUSTMENT)"
set_global_routing_layer_adjustment $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER) $env(RESOURCES_ADJUSTMENT)
set_routing_layers -signal $env(MIN_ROUTING_LAYER)-$env(MAX_ROUTING_LAYER)

if {[info exists env(CLOCK_LAYERS)]} {
  set_routing_layers -clock $env(MIN_ROUTING_LAYER_CLOCK)-$env(MAX_ROUTING_LAYER_CLOCK)
}

global_route -guide_file $env(RESULTS_DIR)/route.guide \
               -congestion_report_file $env(REPORTS_DIR)/congestion.rpt \
               {*}[expr {[info exists ::env(GLOBAL_ROUTE_ARGS)] ? $::env(GLOBAL_ROUTE_ARGS) : {-congestion_iterations 100 -verbose}}]

if  {[info exist env(REPAIR_ANTENNAS)]} {
  repair_antennas -iterations 3
}

set_propagated_clock [all_clocks]
estimate_parasitics -global_routing

source $env(SCRIPTS_DIR)/report_metrics.tcl
report_metrics "global route"

puts "\n=========================================================================="
puts "check_antennas"
puts "--------------------------------------------------------------------------"
check_antennas

# Write SDC to results with updated clock periods that are just failing.
# Use make target update_sdc_clock to install the updated sdc.
source [file join $env(SCRIPTS_DIR) "write_ref_sdc.tcl"]
if {![info exists save_checkpoint] || $save_checkpoint} {
  write_db $env(RESULTS_DIR)/5_1_grt.odb
}
