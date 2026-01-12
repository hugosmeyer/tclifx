# Tcl package index file for ifx::odbc
#
# This file is sourced by Tcl's package mechanism to register
# available packages. 
#
# Installation structure:
#   $dir/
#     ├── pkgIndex.tcl      (this file)
#     ├── libIfxTdbc.tcl    (main Tcl library)
#     └── libifxcli.so      (native extension)
#
# Usage:
#   export TCLLIBPATH="/opt/sup/tcl/lib"  # or wherever parent dir is
#   package require ifx::odbc
#

package ifneeded ifx::odbc 1.0 [list apply {{dir} {
    # Load the native extension from this directory
    load [file join $dir libifxcli.so] Ifxcli
    
    # Source the main library (it will skip loading .so since already loaded)
    source [file join $dir libIfxTdbc.tcl]
}} $dir]
