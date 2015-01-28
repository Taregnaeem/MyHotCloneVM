#!/bin/bash
# Rel. 0.6 - HotCloneVm.sh
# S. Coter - simon.coter@oracle.com
# https://blogs.oracle.com/scoter
# Target of this script is to obtain a clone, on a different repository, of one guest running on Oracle VM
# Reqs:
# 1) ovmcli enabled on Oracle VM Manager on port 10000
# Tested on Oracle VM 3.3.1 Build 1065 or newer
# New features of release 0.4:
# Script is now able to partial clone one guest that:
#       - owns also physical disks
#       - owns virtual disks on different repositories
# Cloned target guest, obviously, has only virtual-disks of the source-one
# New features of release 0.6:
#       - complete rewrited script ( now only bash )
#       - backup retention implemented
#       - fixed strange result with some virtual-disks ( mostly if upgraded from 3.2.x to 3.3.1 where 3.2.x is < 3.2.8 )

if [ $# -lt 6 ]
 then
        clear
        echo ""
        echo "#####################################################################################"
        echo " You have to specify <guest id> or <guest name>:"
        echo " Use HotCloneVm.sh <Oracle VM Manager password> <Oracle VM Manager host> <guest name> <Oracle VM Server Pool> <target Repository> <Backup Retention>"
        echo " Example:"
        echo "           HotCloneVm.sh Welcome1 ovm-mgr.oracle.local vmdb01 myPool repotarget 8d ( retention will be 8 days )"
        echo "           HotCloneVm.sh Welcome1 ovm-mgr.oracle.local vmdb01 myPool repotarget d8 ( retention will be 8 days )"
        echo "           HotCloneVm.sh Welcome1 ovm-mgr.oracle.local vmdb01 myPool repotarget 8c ( retention will be 8 copies of that guest )"
        echo "           HotCloneVm.sh Welcome1 ovm-mgr.oracle.local vmdb01 myPool repotarget c8 ( retention will be 8 copies of that guest )"
        echo "##########################################################################################"
        echo ""
        exit -1
fi
today=`date +'%Y%m%d-%H%M'`
password=$1
mgrhost=$2
guest=$3
pool=$4
repotarget=$5
retention=$6
retention_count=`echo ${retention//[^0-9]/}`
retention_type=`echo ${retention//[^A-Z]/}`
if [ $retention_count -lt 1 ] || ([ "$retention_type" != "d" ] && [ "$retention_type" != "c" ]);then
        echo "Invalid Retention Type or Count specified!"
        exit 1
fi

# Default copy-type is SPARSE
# If you want you can modify to "NON_SPARSE_COPY"
#copytype=NON_SPARSE_COPY
#copytype=SPARSE_COPY
#copytype=THIN_CLONE

# Execute first-connection in case of reboot of Oracle VM Manager, specifying admin password
/usr/bin/expect FirstConn.exp $password $mgrhost

# (1) Get the number of physical and virtual disks to understand the correct approach

# Get mapping-id of virtual-disks owned by the guest
DISK_MAP=`ssh admin@$mgrhost -p 10000 show vm name=$guest |grep VmDiskMapping|awk '{print $5}'`

# Get the association between mapping-id and disk-name of disks owned by the guest - both physical and virtual
unset -v DISK_LIST
for diskid in `echo "$DISK_MAP"`; do
        tmp=`echo $diskid "$(ssh admin@$mgrhost -p 10000 show VmDiskMapping id=$diskid |egrep "(Virtual|Physical)"|awk '{print $5}')"`
        if [ "x$DISK_LIST" = "x" ]; then
        DISK_LIST=`echo $tmp`
        else
        DISK_LIST=`echo -e "$DISK_LIST\n$tmp"`
        fi
done
TOTAL_DISKS=`echo "$DISK_LIST" |wc -l`
PHY_DISKS=`echo "$DISK_LIST" |grep -cv "\.img"`
VIR_DISKS=`echo "$DISK_LIST" |grep -c "\.img"`
echo "$DISK_MAP"
echo "$DISK_LIST"

if [ "$TOTAL_DISKS" = "$PHY_DISKS" ]; then
        echo "Virtual Machine $guest owns only physical disks - hot-clone not possible"
        exit 1
fi

if [ "$PHY_DISKS" -gt 0 ]
then
        # Create Customizer to clone only virtual-disks owned by the guest
        ssh admin@$mgrhost -p 10000 create VmCloneCustomizer name=vDisks-$guest-$today description=vDisks-$guest-$today on Vm name=$guest
        #/usr/bin/expect CreateCustomizerVirtual.cli $password $mgrhost $guest $pool $today
        MAP=`echo "$DISK_LIST" |grep "\.img" |awk '{print $1 }'`
        declare DISKS=($(echo `echo "$DISK_LIST" |grep "\.img" |awk '{print $2}'`))
        i=0
        copytype=THIN_CLONE
        for diskmapping in `echo "$MAP"`; do
                # Get Repository that hosts the virtual-disk
                diskid=${DISKS[$i]}
                ((i++))
                reposource=`ssh admin@$mgrhost -p 10000 show VirtualDisk id=$diskid |grep "Repository Id" |awk '{print $6}' |cut -d "[" -f2 | cut -d "]" -f1`
                echo $reposource
                # Prepare CloneCustomizer with THIN_CLONE of virtual-disks only
                ssh admin@$mgrhost -p 10000 create VmCloneStorageMapping cloneType=$copytype name=vDisks-Mapping-$diskmapping vmDiskMapping=$diskmapping repository=$reposource on VmCloneCustomizer name=vDisks-$guest-$today
        done
        # Create a clone of the guest with only virtual-disks on board and delete custom CloneCustomizer
        ssh admin@$mgrhost -p 10000 clone Vm name=$guest destType=Vm destName=$guest-CLONE-$today ServerPool=$pool cloneCustomizer=vDisks-$guest-$today
        ssh admin@$mgrhost -p 10000 delete VmCloneCustomizer name=vDisks-$guest-$today
else
        # Enter this case only if guest owns only virtual-disks
        # Create an hot-clone of the guest based on ocfs2 ref-links and Create a new temporary Clone Customizer
        ssh admin@$mgrhost -p 10000 clone Vm name=$guest destType=Vm destName=$guest-CLONE-$today ServerPool=$pool
fi
# COPY-TYPE becomes SPARSE for moving on further repository
copytype=SPARSE_COPY

# (1) Create a new temporary Clone Customizer for machine moving
ssh admin@$mgrhost -p 10000 create VmCloneCustomizer name=$guest-$today description=$guest-$today on Vm name=$guest-CLONE-$today

# (2) Prepare storage mappings for clone customizer created
MAP=`ssh admin@$mgrhost -p 10000 show vm name=$guest-CLONE-$today |grep VmDiskMapping|awk '{print $5}'`

for diskmapping in `echo "$MAP"`; do
        ssh admin@$mgrhost -p 10000 create VmCloneStorageMapping cloneType=$copytype name=Storage_Mapping-$diskmapping vmDiskMapping=$diskmapping repository=$repotarget on VmCloneCustomizer name=$guest-$today
done

# (3) Move cloned guest to target repository, delete Clone Customizer and move the target guest under "Unassigned Virtual Machine" folder

ssh admin@$mgrhost -p 10000 moveVmToRepository Vm name=$guest-CLONE-$today CloneCustomizer=$guest-$today targetRepository=$repotarget
ssh admin@$mgrhost -p 10000 delete VmCloneCustomizer name=$guest-$today
ssh admin@$mgrhost -p 10000 migrate Vm name=$guest-CLONE-$today

echo "Guest Machine $guest has cloned and moved to $guest-CLONE-$today on repository $repotarget"
echo "Guest Machine $guest-CLONE-$today resides under 'Unassigned Virtual Machine Folder'"

# (4) Add HotClone-Backup tag to vm cloned and moved to backup repository
ssh admin@$mgrhost -p 10000 create tag name=HotClone-Backup-$guest-CLONE-$today
ssh admin@$mgrhost -p 10000 add tag name=HotClone-Backup-$guest-CLONE-$today to Vm name=$guest-CLONE-$today

# (5) Retention Management: get list of vm backupped
vmlist=`ssh admin@$mgrhost -p 10000 list vm |grep $guest-CLONE|grep -v $guest-CLONE-$today|cut -d "-" -f3,4,5,6,7|sort -n`

# (6) Retention Management: get list of vm backupped that need to be removed
if [ "x$vmlist" != "x" ]; then
#if [ ! -z "${vmlist}" ]; then

case $retention_type in
[d]*)   echo "Retention type is time-based"
        echo "Actual reference is: $today"
        echo "All backups of this guest older than $retention_count days will be deleted!!!"
        dayinseconds=86400
        retention_seconds=$[$dayinseconds*$retention_count]
        today_date=`echo $today|awk '{print $1}'|cut -d "-" -f1`
        today_time=`echo $today|awk '{print $1}'|cut -d "-" -f2`
        today_seconds=$[`date --utc -d $today_date +%s`+`echo $today|cut -c1-2|sed 's/^0*//'`*3600+`echo $today|cut -c3-4|sed 's/^0*//'`*60]
        for backup_tmp in `echo "$vmlist"`; do
                backup_date=`echo $backup_tmp|awk '{print $1}'|cut -d "-" -f1`
                backup_time=`echo $backup_tmp|awk '{print $1}'|cut -d "-" -f2`
                backup_guest=`echo $guest-CLONE-$backup_tmp`
                backup_seconds=$[`date --utc -d $backup_date +%s`+`echo $backup_time|cut -c1-2|sed 's/^0*//'`*3600+`echo $backup_time|cut -c3-4|sed 's/^0*//'`*60]
                diff_seconds=$[$today_seconds-$backup_seconds]
                if [ $diff_seconds -gt $retention_seconds ]
                then
                        check_vm_tag=`ssh admin@$mgrhost -p 10000 show vm name=$backup_guest |grep Tag|grep -c HotClone-Backup-$guest`
                        if [ $check_vm_tag -gt 0 ]
                        then
                                        if [ "x$GUEST_REMOVE_LIST" = "x" ]; then
                                                GUEST_REMOVE_LIST=`echo $backup_guest`
                                        else
                                                GUEST_REMOVE_LIST=`echo -e "$GUEST_REMOVE_LIST\n$backup_guest"`
                                        fi
                        else
                                echo "$backup_guest hasn't a properly configured tag."
                                echo "$backup_guest won't be deleted."
                        fi
                fi
        done;;
[c]*)   echo "Retention type is Redundancy-Based"
        echo "Actual reference is: $today"
        echo "Latest $retention_count backup images will be retained while other backup images will be deleted!!!"
        backup_count=`echo "$vmlist"|wc -l`
        num_guest_to_delete=$[$backup_count-$retention_count+1]
        if [ $num_guest_to_delete -gt 0 ]
        then
                unset -v GUEST_REMOVE_LIST
                for backup_tmp in `echo "$vmlist"|head -$num_guest_to_delete`; do
                backup_guest=`echo $guest-CLONE-$backup_tmp`
                check_vm_tag=`ssh admin@$mgrhost -p 10000 show vm name=$backup_guest |grep Tag|grep -c HotClone-Backup-$guest`
                        if [ $check_vm_tag -gt 0 ]
                        then
                                        if [ "x$GUEST_REMOVE_LIST" = "x" ]; then
                                                GUEST_REMOVE_LIST=`echo $backup_guest`
                                        else
                                                GUEST_REMOVE_LIST=`echo -e "$GUEST_REMOVE_LIST\n$backup_guest"`
                                        fi
                        else
                                echo "!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!"
                                echo "$backup_guest hasn't a properly configured tag."
                                echo "$backup_guest won't be deleted."
                        fi
                done
        fi;;
esac
fi

# (7) Verify if guest is running, has virtual-disks or have configured vNic & Delete obsolete VmDiskMapping / VirtualDisk / Vm

echo "All backupped guests that:"
echo "================================="
echo "1) aren't in a stopped state"
echo "2) have physical disk configured"
echo "3) have configured vNIC"
echo "================================="
echo "Won't be removed by the automatic retention even if are obsolete backups."
echo ""

if [ "x$GUEST_REMOVE_LIST" = "x" ]; then
        echo "============================================================="
        echo "Based on retention policy any guest backup will be deleted!!!"
        echo "============================================================="
        exit 0
fi

for guest_to_delete in `echo "$GUEST_REMOVE_LIST"`; do
        guest_candidate=`ssh admin@$mgrhost -p 10000 show vm name=$guest_to_delete`
        guest_status=`echo "$guest_candidate"|grep -c "Status = Stopped"`
        # guest_status=1 -> proceed!
        guest_vnics=`echo "$guest_candidate"|grep -c "Vnic 1"`
        # guest_vnic=1 -> stop!
        DISK_MAP=`ssh admin@$mgrhost -p 10000 show vm name=$guest_to_delete |grep VmDiskMapping|awk '{print $5}'`
        guest_phydisks=0
        for disktmp in `echo "$DISK_MAP"`; do
                physicaldisk=`ssh admin@$mgrhost -p 10000 show VmDiskMapping id=$disktmp |grep -c Physical`
                guest_phydisks=$[$guest_phydisks+$physicaldisk]
        done
        if [ $guest_status -eq 1 ] && [ $guest_vnics -eq 0 ] && [ $guest_phydisks -eq 0 ]
        then
                unset -v DISK_LIST
                unset -v diskid
                for diskid in `echo "$DISK_MAP"`; do
                        virtualdisk=`ssh admin@$mgrhost -p 10000 show VmDiskMapping id=$diskid |grep Virtual|awk '{print $5}'`
                        ssh admin@$mgrhost -p 10000 delete VmDiskMapping id=$diskid
                        ssh admin@$mgrhost -p 10000 delete VirtualDisk id=$virtualdisk
                done
                ssh admin@$mgrhost -p 10000 delete vm name=$guest_to_delete
                ssh admin@$mgrhost -p 10000 delete tag name=HotClone-Backup-$guest_to_delete
                echo "==============================================="
                echo "guest backup $guest_to_delete deleted!"
                echo "==============================================="
        else
                echo "It's not possible to remove guest $guest_to_delete due to one of the following possible reason(s):"
                echo " - Guest is running"
                echo " - Guest owns physical disks"
                echo " - Guest has virtual-nics configured"
        fi
done
