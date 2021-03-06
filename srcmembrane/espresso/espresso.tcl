# ::cgtools::espresso
#
#------------------------------------------------------------#
# Script for running a CG membrane simulation
# Author: Zun-Jing Wang 
# 2008 Sep. 23 - Oct. 9 
#
# Implements settings contained in a parameter file which should be
# given as an argument.
#
# -----------------------------------------------------------#
#
# Get the name of the current namespace
package provide cgtools::espresso 1.0.0
package require ::mmsg
package require ::cgtools::utils
package require ::cgtools::generation
package require ::cgtools::analysis

namespace eval cgtools {

    namespace eval espresso {
	# Initialize an espresso simulation
	# from the lipid chain we built with the script.
	# This routine will be called by the cgtoolsmain script as well as
	# the parameter optimizer. Different paths.
	# Argument : the list of coordinate file name.
	# Returns nothing.
	proc espresso_init { } {

	    #############################################################
	    # local variable: 	
	    #		  	f_topo
	    #                 	starttime
	    #                 	i 
    	    #			startj
    	    #			startk
	    #                 	cutoff 
	    #                 	timingstart 
	    #                 	timingcurr
	    #                 	elapsedtime
	    #############################################################
		global topology 
    		global jjjjjj
    		global kkkkkk
    		global checkpointexists
		global errorInfo errorCode 


	     	set this [namespace current]
                mmsg::send $this "Feeding lipid parameters into ESPResSo running..."

    		# Attempt to read a checkpoint file
    		set checkpointexists [ ::cgtools::utils::readcheckpoint $cgtools::outputdir ]
 
    		# Set the starting time for this run ie override the value in checkpoint file
    		set starttime [clock seconds]

		#----------- Default Parameters set from System Params ----#
		if { $cgtools::warmup_temp == 0 } {
			set cgtools::warmup_temp [lindex $cgtools::systemtemp 0 ]
	   	}

		# ----------- Initialization ------------------ -----------#

		# Start a new computation, if no checkpoint
		if { !$checkpointexists } {
			# No checkpoint exists so we need to setup everything from scratch
    		        set startj 0
    			set startk 0

    			# Setup the output directory by creating it and copying forcetables and overlapped potcoffs to it
    			::cgtools::utils::setup_outputdir  $cgtools::outputdir -paramsfile $cgtools::paramsfile \
				-tabdir $cgtools::tabledir -tabnames $cgtools::tablenames -coffdir $cgtools::overlapdir \
				-coffnames $cgtools::overlapnames -readpdbdir $cgtools::readpdbdir \
				-readpdbname $cgtools::readpdbname

    			# Set the box dimensions
    			setmd box_l [lindex $cgtools::setbox_l 0] [lindex $cgtools::setbox_l 1] [lindex $cgtools::setbox_l 2]
                	setmd periodic 1 1 1
			if {$cgtools::linetension } {setmd periodic 1 0 1}
			puts "period is [setmd periodic]"
	
    			# Specify the bonded interactions
    			#puts "bonded_parms $cgtools::bonded_parms"
    			::cgtools::utils::set_bonded_interactions $cgtools::bonded_parms

    			# Specify any other non-bonded interactions
    			if { [ catch { ::cgtools::utils::set_nb_interactions $cgtools::nb_interactions } ] } {
				mmsg::send $this "no non-bonded interactions used"
    			}

    			set cutoff [setmd max_cut] 
    			puts "max_cut is $cutoff"

    			# Initialize variable moltypelists in the namespace ::cgtools::utils
    			::cgtools::utils::initmoltypeskey $cgtools::moltypelists 
    			#puts "$cgtools::moltypelists"

			#puts "$cgtools::ident"
			#puts "$cgtools::system_specs"
			#puts "$cgtools::setbox_l"
    			# Initialize topology
    			set topology [::cgtools::generation::generate_system $cgtools::system_specs $cgtools::setbox_l]
    			#puts "topology= $topology"
    			# Set the generated topology into the internals of espresso.
    			::cgtools::utils::set_topology $topology
	    		
    			set cgtools::trappedmols [::cgtools::generation::get_trappedmols]
    			# Fix molecules if necessary
    			if { $cgtools::trappedmols != -1 } {
				::cgtools::utils::trap_mols $cgtools::trappedmols
    			}

			# set exclustions for the bonded particles 1: 2-bodyinteraction  2: 3-body interaction
    			part auto_exclusions 1

    			#Initialise Random Number Generator
    			::cgtools::utils::init_random $cgtools::nprocessors

    			setmd skin      $cgtools::verlet_skin

    			# See if there is any fixed molecules 
    
    			# ----------- Integration Parameters before warmup -----------#
    			# Set the topology and molecule information
    			#----------------------------------------------------------#
    			#write topology file
    			set f_topo [open "$cgtools::outputdir/$cgtools::ident.top" w]
    			blockfile_write_topology $f_topo write topology   
    			close $f_topo

    			# Check if there are any extra vmdcommands and if not initialize a default
    			::cgtools::utils::initialize_vmd $cgtools::use_vmd $cgtools::outputdir $cgtools::ident \
				$topology -extracommands $cgtools::vmdcommands

			#puts "topology= $topology"

    			#Perform the warm up integration
    
    			#----------------------------------------------------------#
    			# Warm up containing fixed particles 
    			setmd time_step $cgtools::warm_time_step
    			thermostat langevin $cgtools::warmup_temp $cgtools::langevin_gamma

    			mmsg::send $this "warming up at [setmd temp]"
    			::cgtools::utils::warmup  $cgtools::warmsteps $cgtools::warmtimes $topology -cfgs 10 -outputdir $cgtools::outputdir

    			# If the membrane have any fixed particles, unfix them after warmup
    			set cgtools::userfixedparts [::cgtools::generation::get_userfixedparts ]
    			for {set i 0} { $i <  [setmd n_part] } {incr i} {
				if { [lsearch $cgtools::userfixedparts $i ] == -1 } {
	    				part [expr $i] fix 0 0 0
				}
    			}

    			# Set MD step, themostat before warm up without any fixed article
    			setmd time_step $cgtools::main_time_step
    			thermostat langevin  [lindex $cgtools::systemtemp 0] $cgtools::langevin_gamma

    			# Warm up without any fixed particle 
    			::mmsg::send $this "warming up without fixed particles at  [setmd temp]"
    			::cgtools::utils::warmup $cgtools::free_warmsteps $cgtools::free_warmtimes $topology \
				-startcap 1000 -outputdir $cgtools::outputdir
    
    			# ----------- Integration Parameters after warmup -----------#
    			# Set MD step, themostat after warm up
    			setmd time_step $cgtools::main_time_step
    			thermostat langevin  [lindex $cgtools::systemtemp 0] $cgtools::langevin_gamma

    			# Setup analysis
    			::cgtools::analysis::setup_analysis $cgtools::analysis_flags -outputdir  $cgtools::outputdir -g $cgtools::mgrid -str $cgtools::stray_cut_off
    
    			mmsg::send $this "starting integration: run $cgtools::int_n_times times $cgtools::int_steps steps"

    			# Reset the time to a starttime (usually zero) after warmup
    			setmd time $cgtools::startmdtime   
		}
 
		# Resume a computation, if exists checkpoint
		if { $checkpointexists } {
    			# A checkpoint exists so all we need to do is reset the moltypelists, topology and setup analysis again
    
    			::cgtools::utils::initmoltypeskey $cgtools::moltypelists 
    			::cgtools::utils::read_topology "$cgtools::outputdir/$cgtools::topofile"
			
			# set exclustions for the bonded particles 1: 2-bodyinteraction  2: 3-body interaction
    			part auto_exclusions 1


			::cgtools::analysis::setup_analysis $cgtools::analysis_flags \ 
                                -outputdir  $cgtools::outputdir -g $cgtools::mgrid -str $cgtools::stray_cut_off

    			
			set topology [analyze set] 
    			::cgtools::utils::initialize_vmd $cgtools::use_vmd $cgtools::outputdir $cgtools::ident \
				$topology

    			# Make sure that we start exactly from where the checkpoint was written
    			set startj $jjjjjj
    			set startk [expr $kkkkkk + 1]
		}

    		#puts "Hello Zunjing, Hello Zunjing, Hello Zunjing, Hello Zunjing"
		#Main Integration                                          #
		#----------------------------------------------------------#
		set jjjjjj $startj

		thermostat langevin $cgtools::systemtemp $cgtools::langevin_gamma

		if { $cgtools::thermo == "DPD" } {
			thermostat off
    			set dpd_r_cut [setmd max_cut]
		        thermostat set dpd $cgtools::systemtemp $cgtools::dpd_gamma $dpd_r_cut
		        mmsg::send $this "DPD thermostat has been set"
		        mmsg::send $this "Thermostat is: [thermostat]"
		}
		if { $cgtools::npt == "on" } {
		        integrate set npt_isotropic $cgtools::p_ext $cgtools::piston_mass 1 1 0
		        mmsg::send $this "npt integrator has been set"
		        flush stdout
		        #-cubic_box
		        thermostat set npt_isotropic $cgtools::systemtemp  $cgtools::gamma_0  $cgtools::gamma_v
		}

		set timingstart [clock clicks -milliseconds]
		for {set kkkkkk $startk } { $kkkkkk <  $cgtools::int_n_times } { incr kkkkkk} {
		    	mmsg::send $this "run $kkkkkk at time=[setmd time]"

		    	# Call all of the analyze routines that we specified when setting up our analysis
		    	::cgtools::analysis::do_analysis

		    	# If kkkkkk is a multiple of analysis_write_frequency then write the analysis results to file
		    	if { [expr $kkkkkk + 1] % $cgtools::analysis_write_frequency ==0 } {
				::cgtools::analysis::print_averages
				#::cgtools::utils::update_force $rdfcglist $rdfaalist $tabledir $tablenames
		    	}

			# If kkkkkk is a multiple of write_frequency then write out a full particle configuration
			if { [expr $kkkkkk + 1] % $cgtools::write_frequency ==0 } {
			   #	polyBlockWrite "$cgtools::outputdir/$cgtools::ident.[format %04d $jjjjjj].out" \
			   #		{time box_l npt_p_diff } \
			   #		{id pos type mass v f molecule} 
			   #	mmsg::send $this "wrote file $cgtools::outputdir/$cgtools::ident.[format %04d $jjjjjj].out " 
			   # 	flush stdout

				if { $cgtools::use_vmd == "offline" } {
			    	    ::cgtools::utils::writecrd_charmm \
						"$cgtools::outputdir/$cgtools::ident.vmd[format %04d $jjjjjj].crd" $topology \
						-periodbox 1 -computecomz 1

    				     ::cgtools::utils::writepdb_charmm \
						"$cgtools::outputdir/$cgtools::ident.vmd[format %04d $jjjjjj].pdb" $topology \
						-periodbox 1 -computecomz 1
				}

				incr jjjjjj

			    	# Write a checkpoint to allow restarting.  Overwrites previous checkpoint
			   	mmsg::send $this "setting checkpoint $kkkkkk [setmd time] $jjjjjj"    
				catch { exec rm $cgtools::outputdir/checkpoint.latest.chk }
				#set code [catch { exec rm -f $cgtools::outputdir/checkpoint.latest.chk } string]
				#if {$code == 1}{
				#	return -code error -errorinfo $errorInfo -errorcode $errorCode $string
			   	#        mmsg::send $this "$errorInfo"    
			   	#        mmsg::send $this "errorCode"    
				#}
				catch { exec mv $cgtools::outputdir/checkpoint.latest.out \ 
					$cgtools::outputdir/checkpoint.latest.out.old }
			        checkpoint_set "$cgtools::outputdir/checkpoint.latest.out"
			        # Try to copy a checkpoint to the backup checkpoint folder
			        # Usefull if the program crashes while writing a checkpoint
			        if { [ catch { exec cp $cgtools::outputdir/checkpoint.latest.out \
					$cgtools::outputdir/checkpoint_bak/ } ] } {
					mmsg::warn $this "warning: couldn't copy backup checkpoint"
			    	}

			}
			#end of if { [expr $kkkkkk + 1] % $cgtools::write_frequency ==0 }

			# Do the real work of integrating equations of motion
                        integrate $cgtools::int_steps


			# Set the elapsed CPU time in computation, do not count that used for warm up
			set timingcurr [clock clicks -milliseconds]
			set elapsedtime [expr  $timingcurr - $timingstart]
			    ::mmsg::send $this "elapsed time: $elapsedtime"
		}
		#end of MD integration for {set kkkkkk $startk } { $kkkkkk <  $cgtools::int_n_times } { incr k}

		# Clean up the table, coefficent, readpdb files if they are in [pwd] or $outputdir
		#::cgtools::utils::cleanup_tabfiles $cgtools::tablenames $cgtools::tabledir $cgtools::outputdir
		#::cgtools::utils::cleanup_cofffiles $cgtools::overlapnames $cgtools::overlapdir $cgtools::outputdir
		#::cgtools::utils::cleanup_readpdbfiles $cgtools::readpdbname

		return
    	} 
	#end of proc espresso_init
     }
     #end of namespace eval espresso
}
#end of namespace eval cgtools 
source [file join [file dirname [info script]] replica.tcl ]
source [file join [file dirname [info script]] hybrid.tcl ]
source [file join [file dirname [info script]] annealfast.tcl ]
source [file join [file dirname [info script]] annealing.tcl ]
source [file join [file dirname [info script]] ffs.tcl ]
