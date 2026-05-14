source $::env(SCRIPTS_DIR)/load.tcl
erase_non_stage_variables generate_abstract

set stem [expr {
  [env_var_exists_and_non_empty ABSTRACT_SOURCE] ?
  $::env(ABSTRACT_SOURCE) :
  "6_final"
}]

set result [find_sdc_file $stem.odb]
set design_stage [lindex $result 0]
set sdc_file [lindex $result 1]

log_cmd load_design $stem.odb [file tail $sdc_file]

if { $design_stage >= 6 && [file exists $::env(RESULTS_DIR)/$stem.spef] } {
  log_cmd read_spef $::env(RESULTS_DIR)/$stem.spef
} elseif { $design_stage >= 3 } {
  log_cmd estimate_parasitics -placement
}

if { $design_stage >= 4 } {
  set_propagated_clock [all_clocks]
}
# write_timing_model includes the source latency in the model
set_clock_latency -source 0 [all_clocks]
puts "Generating abstract views"
# When USE_LDB=1, emit a sibling .ldb next to each written .lib so the
# parent design (which loads block libs as ADDITIONAL_LIBS -> LDB_FILES
# via .lib -> .ldb patsubst) can find a matching cache.
proc write_ldb_sibling { lib_file } {
  if { ![env_var_equals USE_LDB 1] } { return }
  set libs_before [get_libs *]
  read_liberty $lib_file
  set new_libs {}
  foreach lib [get_libs *] {
    if { [lsearch -exact $libs_before $lib] == -1 } {
      lappend new_libs $lib
    }
  }
  if { [llength $new_libs] != 1 } {
    error "write_ldb_sibling: expected 1 new library after read_liberty $lib_file, got [llength $new_libs]: $new_libs"
  }
  set ldb_file [string range $lib_file 0 end-4].ldb
  log_cmd write_ldb [lindex $new_libs 0] $ldb_file
}

if { [env_var_exists_and_non_empty CORNERS] } {
  foreach corner $::env(CORNERS) {
    set lib_file $::env(RESULTS_DIR)/$::env(DESIGN_NAME)_$corner.lib
    log_cmd write_timing_model -scene $corner $lib_file
    write_ldb_sibling $lib_file
  }
} else {
  set lib_file $::env(RESULTS_DIR)/$::env(DESIGN_NAME)_typ.lib
  log_cmd write_timing_model $lib_file
  write_ldb_sibling $lib_file
}
log_cmd write_abstract_lef -bloat_occupied_layers $::env(RESULTS_DIR)/$::env(DESIGN_NAME).lef

if { [env_var_exists_and_non_empty CDL_FILES] } {
  cdl read_masters $::env(CDL_FILES)
  cdl out $::env(RESULTS_DIR)/$stem.cdl
}
