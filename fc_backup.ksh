#!/usr/bin/ksh
#*******************************************************************************
# This script is designed to take a flash copy backup of ds4700 logical drives that are presented to the vios vioserver. 
# The vios client system will have to be quiesced before the flash copy is taken, eg databases brought down.
# Once the flash copy completes the databases can be brought backup again. 
# Once we have a flash copy and the databases are back up and running we can take our time backing it up to tape. 
# The script is coded such that in the middle somewhere it will bring the databases down, take a flash copy, then
# bring the databases up. These 3 steps will happen in sequence so that we minimize the downtime on the databases.
# A little warning, to understand this script you need to have knowledge 
# of Unix, vios servers, ds4700, and lto tape drives.
#*******************************************************************************
# First declare all the functions.
#*******************************************************************************
# Function print_usage: used to display a usage statement. 
#*******************************************************************************
print_usage () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	echo "Usage: $SCRIPT_NAME [-i|-f] [hostname]..."

} # End of function print_usage

#*******************************************************************************
# Function date_print: Used to prefix output with a date and time stamp.
#*******************************************************************************

date_print () {
	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi
	echo "$(date) $*"
} # End of function date print

#*******************************************************************************
# Function mail_signature: Used to put a useful signature on the bottom of emails.
#*******************************************************************************
mail_signature () {
	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi
	echo "This message was produced by the script $0 on $(hostname -s) at $(date)."
	echo "The log file for the script run is $LOG_FILE"
	echo "The script was called to backup the following hosts:"
	echo "$HOSTS_TO_BACKUP"
}  # End of function mail_signature.

#*******************************************************************************
# Function mail_result: Used to mail interested parties if something goes wrong.
#*******************************************************************************

mail_result () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	MAIL_ADDRESS_FILE=/usr/local/etc/mail_list

	if [[ $DEBUG = "Y" ]] | [[ $DEBUG = "T" ]]
	then
		RECIPIENTS=$(awk '$1 == "TEST_GROUP"  {printf $2" "}
					END {print}' $MAIL_ADDRESS_FILE)
	else
		RECIPIENTS=$(awk '$1 == "UNIX_ADMIN" || $1 == "DBA_ADMIN" {printf $2" "}
					END {print}' $MAIL_ADDRESS_FILE)
	fi

	MAIL_BODY=$TEMP_DIR/$1."mailbody"

	while read line
	do
		echo "$line"
	done > $MAIL_BODY

	mail -s "$1" $RECIPIENTS <<-EOF2
		$(<$MAIL_BODY)
		$(mail_signature)
	EOF2

} # End of function mail_result.

#*******************************************************************************
# Function get_controller_address: returns the ip address of the controller 
# of a logical device.
#*******************************************************************************
get_controller_address () {
	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	CONTROLLER=$(SMcli $DS4700_CTRLA -S -c "show logicaldrive [\"$1\"];" | grep Current|awk '{print $NF}')

	if [[ $CONTROLLER = "A" ]]
	then
		echo $DS4700_CTRLA
	else
		echo $DS4700_CTRLB
	fi
} # end of function get_controller_address

#*******************************************************************************
# Function gather_vios_disk_information: Used to gather disk information at
# the vios level.
#*******************************************************************************
gather_vios_disk_information () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Gathering disk information from the vios $VIO_SERVER."
	# The next step is to log into the vios and get a list of disks that are presented to the vios
	# client without being carved up into logical volumes. ie where the backing device is a disk.

	WHOLE_DISK_BD=$TEMP_DIR/whole_disk_backing_devices_$$
	rm -f $WHOLE_DISK_BD

	rcmd="ssh padmin@$VIO_SERVER ioscli"
	
	# note here that I convert the lpar number to decimal using the "%d" in the printf statement.
	# It makes life a bit easier later.

	$rcmd lsmap -all -type disk -fmt : \
		| grep ^v \
		| awk -F: '	{ for ( i = 4;i < NF; i += 4)
					{
						printf("%d:%s:%s\n",$3,$(i+1),$(i+2))
					}
				}' > $WHOLE_DISK_BD

	# The format of the $WHOLE_DISK_BD file is 
	# lparnumber:lun:bd
	# Where the lun is in hex, the lun is the lun id for the lpar client. The bd is the backing device eg hdisk5.

	# Now we need to get the wwn  for each disk and put it into the master file together with the above info. 

	for diskline in $(<$WHOLE_DISK_BD)
	do
		disk=$(echo $diskline | awk -F: '{print $NF}')
		WWN=$($rcmd lsdev -attr ieee_volname -dev $disk | awk 'NR == 3 {print $0}')
		echo $diskline":"$WWN
	done > $VIOS_DISK_INFORMATION
	

} # end of function gather_vios_disk_information 

#*******************************************************************************
# Function gather_aix_disk_information: Used to gather disk information at
# the aix level.
#*******************************************************************************
gather_aix_disk_information () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	HOST_TO_FLASH=$1

	date_print "Gathering disk information from the host $HOST_TO_FLASH"

	# What we need to do first is work out which logical drives in the ds4700 belong to 
	# $HOST_TO_FLASH. We also need to eliminate drives that are allocated to the host
	# but are not used.
	# So lets start at the $HOST_TO_FLASH and work our way through to the ds4700, 
	# to find out what logical drives we need to flash.

	# rcmd stands for "remote command" it just saves typing in the long string lots of times.
	# We will change it later to use it for vios commands.

	rcmd="sudo -u rcmduser ssh -q -o ConnectTimeout=4 $HOST_TO_FLASH"
	if ! $rcmd hostname > /dev/null 2>&1
	then
		date_print "********************************************************************************"
		date_print " WARNING Unable to ssh into $HOST_TO_FLASH."
		date_print " WARNING : Aborting backup of $HOST_TO_FLASH"
		date_print "********************************************************************************"
		WARNINGS=/usr/bin/true
		return 
	fi

	list_virtual_disks_to_fc >> $AIX_DISK_INFORMATION

	# What $AIX_DISK_I@NFORMATION now contains is a colon delimited list of disks 
	# that are candidates for flash copy. The file is in the format:
	# hostname:partition number:volume group name:disk name:lun
	
} # gather_aix_disk_information

#*******************************************************************************
# Function list_virtual_disks_to_fc: Lists virtual disks that we want to flash copy
#*******************************************************************************
# This only lists the disks at the aix level we want to backup. It does not 
# necessarily mean they are flash copyable. If they turn out to be an lv in the vios
# then we won't be able to back them up. 
#*******************************************************************************
# This will list: all of the disks that are from non rootvg volume groups that 
# are comprised solely of virtual disks. 
#*******************************************************************************
list_virtual_disks_to_fc () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	for vg in $(list_vgs_to_fc)
	do
		for disk in $($rcmd lsvg -p $vg| awk 'NR > 2 {print $1}')
		do
			partition_number=$($rcmd lparstat -i | awk '$1 == "Partition" && $2 == "Number" {print $NF}')
			lun=$($rcmd lscfg -vpl $disk |awk 'NR == 1 {print $2}'| awk -F- '{print $NF}' | sed 's/^L//')
			echo $HOST_TO_FLASH":"$partition_number":"$vg":"$disk":0x"$lun
		done
	done
} # End of function list_virtual_disks_to_fc

#*******************************************************************************
# Function:list_vgs_to_fc 
#*******************************************************************************
# Lists the active, non rootvg, volume groups that are comprised of solely 
# virtual disks
#*******************************************************************************

list_vgs_to_fc () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	for vg in $($rcmd lsvg -o | grep -v ^rootvg$)
	do
		vg_totally_virtual=/usr/bin/true
		for pv in $($rcmd lsvg -p $vg | awk 'NR > 2 {print $1}')
		do
			if ! $rcmd lsdev -Cl$pv | grep -q Virtual
			then
				vg_totally_virtual=/usr/bin/false
			fi
		done
		if $vg_totally_virtual
		then
			echo $vg
		fi
	done 

} # End of function list_vgs_to_fc 
#*******************************************************************************
# Function create_list_of_disks_to_flash_copy : This is takes the information
# created by the gather_aix_disk_information  and the gather_vios_disk_information
# functions and works out which disks can be meaningfully flash copied. ie 
# we can flash copy them and we will be able to back up what is on there. 
#*******************************************************************************
create_list_of_disks_to_flash_copy () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Collating vios and aix disk information to establish what can be flash copied."

	for lpar in $(awk -F: '{print $2}' $AIX_DISK_INFORMATION | sort -u)
	do
		for vg in $(awk -F: '$2 == lpar {print $3}' lpar=$lpar $AIX_DISK_INFORMATION| sort -u)
		do
			vg_fc_capable=/usr/bin/true
			for disk in $(awk -F: '$2 == lpar && $3 == vg {print $0}' lpar=$lpar vg=$vg $AIX_DISK_INFORMATION)
			do
				lun=$(echo $disk | awk -F: '{print $NF}')
				if ! grep -q ^$lpar":"$lun $VIOS_DISK_INFORMATION
				then
					vg_fc_capable=/usr/bin/false
				fi
			done
			host=$(awk -F: '$2 == lpar {print $1}' lpar=$lpar $AIX_DISK_INFORMATION| sort -u)
			if $vg_fc_capable 
			then
				date_print "The volume group $vg in the lpar $host can be flash copied"
				for disk_to_fc in $(awk -F: '$2 == lpar && $3 == vg {print $0}' lpar=$lpar vg=$vg $AIX_DISK_INFORMATION)
				do
					lpar=$(echo $disk_to_fc | awk -F: '{print $2}')
					lun=$(echo $disk_to_fc | awk -F: '{print $NF}')
					wwn=$(grep ^$lpar":"$lun $VIOS_DISK_INFORMATION| awk -F: '{ print $NF}')
					echo $disk_to_fc":"$wwn >> $DISKS_TO_FLASH_COPY
				done
			else
				echo "********************************************************************************"
				date_print "WARNING: The volume group $vg in the lpar $host cannot be flash copied"
				echo "********************************************************************************"
				WARNINGS=/usr/bin/true
			fi
		done
	done

} # End of function create_list_of_disks_to_flash_copy 

#*******************************************************************************
# function discover_ds4700_names: Used to find out what the names of the logical
# drives are that we intend to flash copy. 
#*******************************************************************************
discover_ds4700_names () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Gathering information from the ds4700 to prepare for flash copy."

# first create a logical device to wwn map from the ds4700 
	LD_TO_WWN_MAP=$TEMP_DIR/ld_to_wwn_map_$$

	SMcli $DS4700_CTRLA -S -c "show logicaldrives;" | egrep "SNAPSHOT|LOGICAL DRIVE NAME:|Logical Drive ID:" \
		| sed 's/://g' \
		| awk 'BEGIN { snapshotdata = 0 }
			{
				if ( $1 == "SNAPSHOT" )
					snapshotdata=1
				if ( snapshotdata == 0 )
					if ( $1 == "LOGICAL")
						{	
							printf("%s:",$NF)
						}
					else
						{
							printf("%s\n",toupper($NF))
						}
			}' > $LD_TO_WWN_MAP
					
	for line in $(<$DISKS_TO_FLASH_COPY)
	do
		wwn=$(echo $line | awk -F: '{print $NF}')
		LOGICAL_DEVICE_NAME=$(grep ":"$wwn$ $LD_TO_WWN_MAP |awk -F: '{print $1}')
		echo $line":"$LOGICAL_DEVICE_NAME
	done > $MASTER_FC_LIST
}
#*******************************************************************************
# function perform_flash_copy:
#*******************************************************************************
perform_flash_copy () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Ready to start work on the ds4700 flash copies."

	# Now we have all the information we need. We know which logical devices in the ds4700
	# to flash copy. We have the file MASTER_FC_LIST in the format
	# hostname:lpar number:volumegroup name:hdisk name as the client sees it: lun as the client sees it:wwn as the ds4700 sees it: logical devicename as the ds4700 sees it.
	# With all the above we can do the flash copy and put some meaningful messages out. 
	# for example "the databaseserver vg xyzvg has been backed up to so and so tape".
	# We don't know the tape names yet but we will, hang in there.

	# An interesting piece of information is that in order to perform actions on a logical device ( eg take a flash 
	# copy ) you have to address the SMcli command to the controller that owns the device. It appears that you can
	# use show commands to any controller but updates require you to address the controller that currently owns 
	# the logical device. 

	# First job is to get a list of existing flash copy logical drives and their associated base drive. 
	# We'll need to get rid of last nights flash copies so we might as well do it once here.
	# We could just use last nights but if the source disks have increased in size then the flash copy
	# may have become too small so I chose to recreate rather than re-use.

	EXISTING_FLASH_COPIES=$TEMP_DIR/existing_flash_copies_$$

	SMcli $DS4700_CTRLA -S -c "show alllogicaldrives ;" \
	| awk 'BEGIN { linefound = 0 }
		{ if ( $1 == "FLASHCOPY" && $2 == "LOGICAL" )
			linefound = 1;
		 if ( linefound == 1 )
			if ( $1 == "FLASHCOPY" )
				printf("%s",$NF)
			else if ( $1 == "Associated" && $2 == "base" )
				printf(":%s\n",$NF)
		}' | awk -F: '{print $2":"$1}' >  $EXISTING_FLASH_COPIES

# 
# Now do the business of taking flash copies.
#

	for host in $(awk -F: '{print $1}' $MASTER_FC_LIST| sort -u)
	do
		quiesce_system $host

		# Do a quick check for any running databases.		
		# continue anyway but warn. 
		rcmd="sudo -u rcmduser ssh -q -o ConnectTimeout=4 $host"
		if $rcmd ps -ef | grep ingres | grep -q iigcn
		then
			echo "********************************************************************************"
			date_print "WARNING: There appear to be databases running on $host."
			date_print "The referential integrity of the ingres database backups could be a problem."
			date_print "Here are the running iigcn processes."
			$rcmd ps -ef | grep ingres | grep iigcn
			date_print "To ensure we have good backups please shutdown the databases prior to running a backup."
			date_print "Continuing with backup."
			echo "********************************************************************************"
		else
			date_print "There appear to be no ingres databases running on $host."
			date_print "Any ingres database backups should be ok."
		fi

		for vg in $(awk -F: '$1 == host {print $3}' host=$host $MASTER_FC_LIST | sort -u )
		do
			for logical_device in $(awk -F: '$1 == host && $3 == vg {print $7}' host=$host vg=$vg $MASTER_FC_LIST )
			do
				# First get rid of old flash copies.
				for flash_copy in $(grep ^$logical_device":"$BACKUP_SERVER"_"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]"_"$logical_device$ $EXISTING_FLASH_COPIES| awk -F: '{print $2}')
				do
					date_print "Preparing to delete the flash copy $flash_copy"
					DS4700=$(get_controller_address $flash_copy)
					date_print "Deleting the flash copy $flash_copy"	
					SMcli $DS4700 -c "delete logicaldrive [\"$flash_copy\"];"  -p b0ssman
				done
	
				FC_NAME=$BACKUP_SERVER"_"$(date +%m%d%H%M)"_"$logical_device
				FC_NAME_R=$FC_NAME"_R"

				DS4700=$(get_controller_address $logical_device)
				date_print "Creating the flash copy of $logical_device as $FC_NAME via $DS4700"

				if SMcli $DS4700 -c "create Flashcopylogicaldrive baselogicaldrive=\"$logical_device\" userlabel=\"$FC_NAME\" repositoryUserLabel=\"$FC_NAME_R\";" -p $PASSWORD
				then
					echo $logical_device":"$FC_NAME >> $FC_TAKEN
				else
					date_print "Failed to take a flash copy of $logical_device, please investigate."
				fi

			done
		done
		# Now wait for all the flash copies to complete before restarting databases etc.
		for logical_device in $(grep ^$host":" $MASTER_FC_LIST| awk -F: '{print $NF}')
		do
			flash_copy=$(grep ^$logical_device":" $FC_TAKEN| awk -F: '{print $NF}')
			wait_for_flash_copy_to_complete $flash_copy 
		done

		date_print "All flash copies have completed."

		restart_system $host
	done


} # End of function perform_flash_copy


#*******************************************************************************
# Function quiesce_system : Used to close databases etc prior to a flash copy.
#*******************************************************************************
quiesce_system () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Shutting down normal service on $host"
	date_print "Shutdown of normal service is being done by another script and initiated by cron."
	date_print "So skipping shutdown of normal service."

} # End of function quiesce_system

#*******************************************************************************
# Function restart_system : Used to restart databases etc after a flash copy.
#*******************************************************************************
restart_system () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Restarting services on $host."
	date_print "Restart of normal service is being done by another script and initiated by cron."
	date_print "So skipping restart of normal service."

} # End of function restart_system 
#*******************************************************************************
# Function process_flash_copies: ie give the flash copies to the backup server. 
# and get the backup server back the data up to tape.
# Note: at this point all the flash copy commands have been issued however
# the process of creating the repository may not have finished. But we will deal 
# with that later. In the meantime I wanted the script to progress as far as it
# could to minimize delay.
#*******************************************************************************
process_flash_copies () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	date_print "Now starting to get the flash copies to tape."

	SMcli_output_file=$TEMP_DIR/SMcli_output_file_$$

	rm -f $USED_LUN_NUMBERS

	if SMcli $DS4700_CTRLA -S -c "show storageSubsystem lunMappings host[\"$BACKUP_SERVER\"];" > $SMcli_output_file 2>&1
	then
		awk '$1 != "MAPPINGS" && $1 != "VOLUME" { print $2}' $SMcli_output_file | grep -v ^$ > $USED_LUN_NUMBERS
	else
		touch $USED_LUN_NUMBERS
	fi

	rm -f $SMcli_output_file

	

# I am doing for host loop like this to preserve the order in which they may
# have been specified on the command line. Just in case the order specified is 
# the desired order of backup. Some hosts may have nothing to backup,  
# the "for" loops will skip them for us. 

	for host in $HOSTS_TO_BACKUP 
	do
		let lun=0
		let tape_archive=0

		prepare_tape

		TAPE_HARD_LABEL=$(tapeutil -f /dev/smc0 inventory |  grep -p "^Drive Address 257$" | grep "Volume Tag" | awk '{print $NF}')
		date_print "The backup will be written to the tape $TAPE_HARD_LABEL"
		soft_label_tape

		let tape_archive=$tape_archive+1

		for vg in $(awk -F: '$1 == host {print $3}' host=$host $MASTER_FC_LIST | sort -u )
		do
			for logical_device in $(awk -F: '$1 == host && $3 == vg {print $7}' host=$host vg=$vg $MASTER_FC_LIST )
			do
				let lun=$(get_next_available_lun)
				FLASH_COPY=$(grep ^$logical_device":" $FC_TAKEN | awk -F: '{print $2}')
				controller=$(get_controller_address $FLASH_COPY)
				date_print "Mapping the flash copy $FLASH_COPY to $BACKUP_SERVER."
				SMcli $controller -c "set logicaldrive[\"$FLASH_COPY\"] logicalUnitNumber=$lun hostGroup=\"$BACKUP_SERVER\";" -p $PASSWORD
				
			done

			# Now the drives of $vg are mapped to $BACKUP_SERVER, now cfgmgr.

			date_print "About to run cfgmgr so $BACKUP_SERVER can see the flash copied vg $vg of the host $host."
			/usr/sbin/cfgmgr

			# So the disks should now be veiwable by lspv. Now find a disk that belongs to $vg.
			# We can't just assume that any disks not assigned to a vg are the ones we want. 
			# So here goes. 
			# First get the wwn of one of the luns. 

			WWN=$(SMcli $controller -c "show logicaldrive [\"$FLASH_COPY\"];" | awk '$1 == "Logical" {print $NF}'| sed 's/://g'|dd conv=ucase 2> /dev/null)

			# Now find which pv it is. 

			pv_to_import=""

			for pv in $(lspv | awk '{print $1}')
			do
				pv_wwn=$(lsattr -El $pv -a ieee_volname 2> /dev/null | awk '{print $2}')
				if [[ -z $pv_to_import ]]
				then
					if [[ $pv_wwn = $WWN ]]
					then
						pv_to_import=$pv
					fi
				fi
			done

			newvgname="tapehost"$vg
			date_print "Now importing the vg $vg as $newvgname onto $BACKUP_SERVER using the pv $pv_to_import"

			/usr/sbin/importvg -y $newvgname $pv_to_import

			# Now change the mount points of all filesystems to avoid conflicts with c38 native filesystems.

			BASE_DIR=$BACKUP_BASE_DIR/$host/$vg
			mkdir -p $BASE_DIR

			for filesystem in $(lsvg -l $newvgname | awk '$2 == "jfs2" || $2 == "jfs" {print $NF}' | grep  "^/")
			do
				chfs -m $BASE_DIR$filesystem $filesystem
			done

			# Now mount them on their new mount points then backup then unmount.
			for filesystem in $(lsvg -l $newvgname | awk '$2 == "jfs2" || $2 == "jfs" {print $NF}' | grep  "^/")
			do
				mount $filesystem
				cd $filesystem 
				date_print "Starting to back up $filesystem at position $tape_archive"
				echo "FSF position $tape_archive" >> $TAPE_LOG

			# Work out what the real directory name is without all the extra c38 mount point added.
			# So the log is less confusing. 

				real_dir_name=$( echo $filesystem |awk '{gsub(basedir,"",$1)
									print $1 }' basedir=$BASE_DIR)

				echo "Backup of $host:$real_dir_name starts $(date)" >> $TAPE_LOG

				if find . -print | backup -i -q -f $NOREWIND_TAPE_DRIVE
				then
					echo "Backup of $host:$real_dir_name ends $(date)" >> $TAPE_LOG
				else
					echo "Warning:Problem with backup of $host:$real_dir_name $(date)" >> $TAPE_LOG
					WARNINGS=/usr/bin/true
				fi

				date_print "Finished backing up $filesystem."

				echo " ---------- ---------- ---------- ---------- ----------" >> $TAPE_LOG

				let tape_archive=$tape_archive+1

				cd /
				unmount $filesystem
			done

			# now get rid of the volume group and disks
			# first make a note of what disks are in the vg. 
			# we will use the list to feed the rmdev in a bit.

			temp_disk_list=$TEMP_DIR/temp_disk_list_$$
			lsvg -p $newvgname | grep ^hdisk | awk '{print $1}' > $temp_disk_list

			/usr/sbin/varyoffvg $newvgname
			/usr/sbin/exportvg $newvgname
			for pv_togo in $(<$temp_disk_list)
			do
				rmdev -d -l $pv_togo
			done
# Now remove the mappings
			for logical_device in $(awk -F: '$1 == host && $3 == vg {print $7}' host=$host vg=$vg $MASTER_FC_LIST )
			do
				FLASH_COPY=$(grep ^$logical_device":" $FC_TAKEN | awk -F: '{print $2}')
				controller=$(get_controller_address $FLASH_COPY)
				date_print "Removing lun mapping for $FLASH_COPY."
				SMcli $controller -c "remove logicalDrive[\"$FLASH_COPY\"] lunmapping hostGroup=\"$BACKUP_SERVER\";" -p $PASSWORD
			done

		done

		update_tape_logs

		eject_tape
		

	done


} # End of function process_flash_copies 
#*******************************************************************************
# function wait_for_flash_copy_to_complete : A known problem can occur if you 
# allocate a flash copy to a host and run cfgmgr before a flash copy has completed.
# This function is used to prevent such a situation to occur.
#*******************************************************************************
wait_for_flash_copy_to_complete () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	f_copy=$1
	repository_drive=$f_copy"_R"

	controller=$(get_controller_address $f_copy)

	until SMcli $controller  -c "show logicaldrive [\"$repository_drive\"] actionprogress;" | grep -q "No action in progress"
	do
		date_print "Waiting for the flash copy $f_copy to complete."
		sleep 5
	done

} # End of function wait_for_flash_copy_to_complete 
#*******************************************************************************
# Function get_next_available_lun: Used to get the next available lun.
#*******************************************************************************
get_next_available_lun () {
	while [[ $lun -lt 256 ]] &&  grep -q "^$lun$" $USED_LUN_NUMBERS
	do
		let lun=$lun+1
	done

	if [[ $lun -eq 256 ]]
	then
		date_print "Aborting run, all available lun numbers have been used. Cannot continue." 2>&1
		mail_result "ERROR - Flash copy aborted due to insufficient lun numbers." <<-EOF
			The flash copy backup was unable to allocate the flash copy to $BACKUP_SERVER
			As it had run out of free lun numbers. Please see the log for details.
		EOF
		exit 1
	else
		echo $lun >> $USED_LUN_NUMBERS 
		echo $lun
	fi
} # End of function get_next_available_lun
#*******************************************************************************
# Function prepare_tape: loads a tape and puts a header onto it.
#*******************************************************************************
prepare_tape () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	if tctl -f $TAPE_DRIVE rewind > /dev/null 2>&1
	then
		date_print "Tape rewound and ready to go."
	else
		date_print "No tape in drive so loading one..."

		date_print "The following tape load script gives errors please ignore them."
		/usr/local/bin/load_backup_257 $host
		date_print "The tape load script completed, errors from this point on should not be ignored."

		if tctl -f $TAPE_DRIVE rewind
		then
			date_print "Tape appears to be loaded ok, continuing."
		else
			date_print "No tape in drive after trying to load one, aborting script."
			mail_result "$BACKUP_SERVER - ERROR - Flash copy backup failed to find a tape." <<-EOF
				Failed to find a tape to archive flash copies onto.
				Aborting script.
				Flash copies have been taken, but they need to be written to tape ASAP.
			EOF
			exit
		fi
	fi

} # End of function prepare_tape
#*******************************************************************************
# Function soft_label_tape: Used to put a soft label on a tape.
# A soft label being a small archive at the begining of the tape. 
# The archive will detail not only when the backup was created but also 
# contain fairly detailed system configuration data.
#*******************************************************************************
soft_label_tape () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	SOFT_LABEL_DIR=$TEMP_DIR/$host
	mkdir -p $SOFT_LABEL_DIR
	chmod 777 $SOFT_LABEL_DIR

	cd $SOFT_LABEL_DIR

	if [[ $PWD != "/" ]]   # I know, I am paranoid. 
	then
		rm -f *
	fi

	TAPE_SOFT_LABEL=$SOFT_LABEL_DIR/tape_label_$$

	{
		echo "This tape was created as part of the backup that started at $START_TIME."
		echo "The host being backed up is $host."
		echo "The tape is $TAPE_HARD_LABEL"

		echo "Along with this file are the system documenter files which list, in detail, a lot"
		echo "of the configuration of $host, they might prove useful if you are rebuilding it."
		echo "Details such as networking, storage, and device configuration amongst others are stored there."
		echo "In particular the storage subsystem and filesystems are well documented."
		echo "That should help you rebuild the storage how it was."
		echo "Good luck."

	} > $TAPE_SOFT_LABEL 2>&1

	cd $SOFT_LABEL_DIR

	date_print "Gathering system documentaton to archive onto tape."

	if sudo -u rcmduser scp -Bp rcmduser@nim_master:/usr/local/system_documentation/$host/* .
	then
		date_print "Documentation for $host gathered ok."
	else
		date_print "********************************************************************************"
		date_print "WARNING An error occured whilst gathering system documentation for $host."
		date_print "Continuing with back up all the same."
		date_print "********************************************************************************"
		WARNINGS=/usr/bin/true
	fi
		

	if sudo -u rcmduser scp -Bp rcmduser@nim_master:/usr/local/system_documentation/$VIO_SERVER/* .
	then
		date_print "Documentation for $VIO_SERVER gathered ok."
	else
		date_print "********************************************************************************"
		date_print "WARNING An error occured whilst gathering system documentation for $VIO_SERVER."
		date_print "Continuing with back up all the same."
		date_print "********************************************************************************"
		WARNINGS=/usr/bin/true
	fi
		
	rm -f $TAPE_LOG
	rm -f $TAPE_LOG

	echo "START: $TAPE_HARD_LABEL $START_DATE" > $TAPE_LOG

	echo "FSF position $tape_archive" >> $TAPE_LOG
	echo "Backup of $host:$SOFT_LABEL_DIR starts $(date)" >> $TAPE_LOG

	cd $SOFT_LABEL_DIR

	ls | backup -i -q -f $NOREWIND_TAPE_DRIVE

	echo "Backup of $host:$SOFT_LABEL_DIR ends $(date)" >> $TAPE_LOG
	echo " ---------- ---------- ---------- ---------- ----------" >> $TAPE_LOG

} # End of function soft_label_tape

#*******************************************************************************
# Function update_tape_logs: updates the tape logs that are used to track the 
# age of tapes and when to re-use them. 
#*******************************************************************************
update_tape_logs () {
	
	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	echo "END: $TAPE_HARD_LABEL" >> $TAPE_LOG
	cat $TAPE_LOG >> $MASTER_TOTAL_TAPE_LOG
	
	sed '/START: '"${TAPE_HARD_LABEL}"'/,/END: '"${TAPE_HARD_LABEL}"'/d' $MASTER_ROLLING_TAPE_LOG >> $TAPE_LOG
	mv $TAPE_LOG $MASTER_ROLLING_TAPE_LOG

} # End of function update_tape_logs 
#*******************************************************************************
# Function eject_tape: Used to rewind, eject and move tape to an appropriate place.
#*******************************************************************************
eject_tape () {

	if [[ $DEBUG = "Y" ]]
	then
		set -x
	fi

	tctl -f $TAPE_DRIVE rewoffl

	# Now move the tape out of the drive to an appropriate place.
	if [[ $(tapeutil -f /dev/smc0 inventory | grep -p "Export Station Address 16$" | grep "Volume Tag" | awk '{print NF}') -eq 3 ]]
	then
		ADDR=16
		date_print "Import-Export station unoccupied moving tape to it."
	else
		# get address of 1st available space.
		ADDR=$(tapeutil -f /dev/smc0 inventory |  grep -p "^Slot Address" | grep -p "Volume Tag .....................  " | grep ^Slot | awk '{print $NF}' | tail -1)
		date_print "Import-Export station already occupied moving tape to slot $ADDR"
	fi

	tapeutil -f /dev/smc0 move 257 $ADDR

} # End of function eject_tape
#*******************************************************************************
# Main: This is where things start to happen.
#*******************************************************************************
# Set the variable DEBUG on the command line like this
# export DEBUG=y
# and the script will run with xtrace turned on.
# If you want to do a full run but have mails sent only to the test group then
# used "export DEBUG=t". See the file /usr/local/etc/mail_list for details.
#*******************************************************************************

typeset -uL1 DEBUG

if [[ $DEBUG = "Y" ]]
then
	set -x
fi

if [[ $(whoami) != "root" ]]
then
	date_print "This script must be run as the root user. Aborting..."
	exit 1
fi


# ******************** First off set up a log file. ****************************

LOG_DIR=/usr/local/log/backuplog
mkdir -p $LOG_DIR

TEMP_DIR=/tmp/fc_backup_temp_files
mkdir -p $TEMP_DIR
chmod 777 $TEMP_DIR

TIME_STAMP=$(date +%d"_"%m"_"%Y":"%H"_"%M)

LOG_FILE=$LOG_DIR"/"$(hostname -s)"_"$(basename $0)"_log_"$TIME_STAMP

{
	if [[ $# -eq 0 ]]
	then
		date_print "Script starting with no parameters passed."
	else
		date_print "Script starting with the following parameters passed:$*"
	fi

	#****************** Now setup some constants ***********************************

	SCRIPT_NAME=$(basename $0)
	VIO_SERVER=vioserver
	DS4700_CTRLA=192.168.1.1
	DS4700_CTRLB=192.168.1.2
	BACKUP_SERVER=backuphostname
	PASSWORD=$(</usr/secrets/ds4700_pw)
	BACKUP_BASE_DIR=/flash_copy_mountpt
	TAPE_DRIVE=/dev/rmt2
	NOREWIND_TAPE_DRIVE=/dev/rmt2.1
	USED_LUN_NUMBERS=$TEMP_DIR/used_lun_numbers_$$
	START_DATE=$(date +%d/%m/%y)
	START_TIME=$(date)
	TAPE_LOG=$TEMP_DIR/fc_backup_tape_log_$$
	MASTER_TOTAL_TAPE_LOG=/usr/local/bin/bkup_logs/total_tapes_log
	MASTER_ROLLING_TAPE_LOG=/usr/local/bin/bkup_logs/rolling_tapes_log

	#*************************** Set defaults **************************************

	BACKUP_TYPE=full

	HOSTS_TO_BACKUP="donald mickey goofy arnie"

	#***** Now work out what isn't going to be default from the paramters passed.***

	# Process command line variables. 
	let option_count=0
	while getopts ":if" opt
	do
		case $opt in 
			i) BACKUP_TYPE="incremental"
				let option_count=$option_count+1;;
			f) BACKUP_TYPE="full" 
				let option_count=$option_count+1;;
			\?) print_usage
				exit 1 ;;
		esac
	done

	if [[ $option_count -gt 1 ]]
	then
		print_usage
		"The -i and -f options are mutually exclusive please use just one."
		exit
	fi

	shift $(($OPTIND -1))

	if [[ $# -gt 0 ]]
	then
		HOSTS_TO_BACKUP="$*"
	fi

	# Now we know which hosts need backing up and if it is incremental or full.

	WARNINGS=/usr/bin/false

	# The next step is to gather information to work out which logical drives in the ds4700 to backup.
	# This is rather convoluted because we cannot flash copy backing devices which are from storage pools.
	# We can only backup backing devices which are whole disks that are presented to the vios clients as 
	# whole disks. Another issue is that if a volume group on a client  has any virtual disks in it which are backed
	# by logical volumes on the vios then it will be impossible to back up the whole vg even if it's just one pv 
	# that has a bd in a storage pool.
	# So what we need to find out is which vg's in the clients are comprised of solely bd that are not part of 
	# storage pools. These vg's can be backed up. To back them up we need to know which these map to in the ds4700.
	# So we have to trace them through the vios to the ds4700. We need to issue a flash copy command at some point 
	# so we need to know what to flash copy.

	# I have used several files here, where I could have used one. 
	# The reason: It is much easier to debug/maintain if there are distinct steps that you can trace.  

	AIX_DISK_INFORMATION=$TEMP_DIR/aix_disk_information_$$
	VIOS_DISK_INFORMATION=$TEMP_DIR/vios_disk_information_$$
	DISKS_TO_FLASH_COPY=$TEMP_DIR/disks_to_flash_copy_$$
	MASTER_FC_LIST=$TEMP_DIR/master_flash_copy_list_$$
	FC_TAKEN=$TEMP_DIR/flash_copies_taken_$$

	rm -f $AIX_DISK_INFORMATION $VIOS_DISK_INFORMATION $DISKS_TO_FLASH_COPY $MASTER_FC_LIST $FC_TAKEN

	for host in $HOSTS_TO_BACKUP
	do
		gather_aix_disk_information $host
	done

	if [[ -e $AIX_DISK_INFORMATION ]]
	then
		gather_vios_disk_information

		# Now we get the answers

		create_list_of_disks_to_flash_copy

		# So now we have a list of disks that we are going to flash copy. 
		# Now we have to log into the ds4700 and find out what they are called.

		discover_ds4700_names

		perform_flash_copy

		process_flash_copies

	else
		date_print "Could not find any disks to flash copy."
	fi
	
	# Now tidy temp files but ensure that TEMP_DIR is not null first for safety.
	date_print "Tidying up old temp and old log files."
	if [[ -n $TEMP_DIR ]]
	then
		find $TEMP_DIR -type f -mtime +7 -exec rm {} \;
	fi

	# Now tidy up log files.

	if [[ -n $LOG_DIR ]]
	then
		find $LOG_DIR -type f -mtime +35 -exec rm {} \;
	fi

	if $WARNINGS
	then 
		subject="$BACKUP_SERVER: Backup of $HOSTS_TO_BACKUP completed WITH WARNINGS"
		body="There were warnings during the backup please investigate and resolve."
	else
		subject="$BACKUP_SERVER: Backup of $HOSTS_TO_BACKUP completed without warnings."
		body="There were no warnings during the backup."
	fi

	mail_result "$subject" <<-EOF
		$body

	EOF
		
	date_print "End of run."

} > $LOG_FILE 2>&1
