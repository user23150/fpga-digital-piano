# Build script for Gowin EDA
# Usage:  gw_sh build.tcl
# Locates the project relative to this script, so it works from any directory.

set script_dir [file dirname [file normalize [info script]]]
set proj_file  [file join $script_dir day3.gprj]

open_project $proj_file
set_option -top_module top
run all
