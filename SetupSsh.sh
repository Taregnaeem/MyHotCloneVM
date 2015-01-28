#!/bin/bash
# Rel. 0.6 - HotCloneVm.sh
# Rel. 0.1 - SetupSSh.sh
# S. Coter - simon.coter@oracle.com
# https://blogs.oracle.com/scoter
# Target of this script is to obtain an ssh-key based authentication versus Oracle VM Manager Client.
# This feature will be used by the script "HotCloneVm.sh" to create guests hot-backups.
# Reqs:
# 1) ovmcli enabled on Oracle VM Manager on port 10000
# 2) expect installed on client that launch setup script

if [ $# -lt 3 ]; then
        clear
        echo ""
        echo "#####################################################################################"
        echo " You have to specify <guest id> or <guest name>:"
        echo " Use SetupSsh.sh <Oracle VM Manager host> <Linux oracle user password> <Oracle VM Manager Password>"
        echo " Example:"
        echo "           SetupSsh.sh ovm-mgr.oracle.local oracle Welcome1"
        echo "##########################################################################################"
        echo ""
        exit -1
fi
mgrhost=$1
orapassword=$2
mgrpassword=$3

if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -f ~/.ssh/id_rsa -N ''
fi
sshkey=`cat ~/.ssh/id_rsa.pub`
/usr/bin/expect SetupSsh.exp $orapassword $mgrhost $sshkey
#eval `ssh-agent -s`
#ssh-add
#First connection with password
/usr/bin/expect FirstConn.exp $mgrpassword $mgrhost
# TEST Connection with key-based authentication
ssh admin@$mgrhost -p 10000 'help;exit'
RESULT=$?
if [ "$RESULT" = "0" ]; then
        echo "OVMCLI Session successfully connected with key-based authentication!!!"
else
        echo "Key-Based authentication doesn't work"
fi
#kill -9 $SSH_AGENT_PID
#export SSH_AGENT_PID=
#export SSH_AUTH_SOCK=
