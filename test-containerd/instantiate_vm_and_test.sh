#!/bin/bash

SSH_KEY=""
NAME=""
NETWORK=""
OUTPUT="."
RUNC_FLAVOR="runc"
TEST_RUNTIME="io.containerd.runc.v2"

set -euxo pipefail

function usage() {
	cat << EOF
The script creates a server, and runs tests with required options.
Usage: instanciate_powervs_vm.sh --key <SSH_KEY> --name <NAME> --network <NETWORK> [OPTIONS]
Options:
	--key <SSH_KEY>: name of the ssh key used;
	--name <NAME>: mandatory option, name without space;
	--network <NETWORK>: network used by PowerVS;
	--output <OUTPUT>: location to save results;
	--runc <RUNC_FLAVOR>: runc or crun (runc by default);
	--runtime <TEST_RUNTIME>: io.containerd.runtime.v1.linux,
		io.containerd.runc.v1 or io.containerd.runc.v2
		(io.containerd.runc.v2 by default);
EOF
}

function delete_vm() {
  if [ -z $1 ]; then echo "Nothing to delete. delete_vm requires the vm ID as an argument."; return; fi

  # Ensure we are yet connected
  echo "" | ibmcloud login
  # Remove machine after test
  ibmcloud pi instance-delete $1
}

function delete_network() {
  if [ -z $1 ]; then echo "Nothing to delete. delete_network requires the network ID as an argument."; return; fi

  # Ensure we are yet connected
  echo "" | ibmcloud login
  # Remove network after test
  ibmcloud pi netd $1
}

# Get options
while [[ $# != 0 ]]; do
	case "$1" in
		--help | -h) usage; exit 0;;
		--key) SSH_KEY=$2; shift; shift;;
		--name) NAME=$2; shift; shift;;
		--network) NETWORK=$2; shift; shift;;
		--output) OUTPUT=$2; shift; shift;;
		--runc) RUNC_FLAVOR=$2; shift; shift;;
		--runtime) TEST_RUNTIME=$2; shift; shift;;
		*) echo "FAIL: Unknown argument $1"; usage; exit 1;;
	esac
done

# Ensure key, name and network are fulfilled
if [ -z $SSH_KEY ]; then echo "FAIL: Key not fulfilled."; usage; exit 1; fi
if [ -z $NAME ]; then echo "FAIL: Name not fulfilled."; usage; exit 1; fi

# Create a machine
# Sometime fail, but the machine is correctly instanciated
RAND_VAL=$(head -c 64 /dev/urandom | base64 | tr -dc [:alnum:] | head -c 10; echo)
NAME="$NAME-$RAND_VAL"

# Create public network for VM
NETNAME="prow-net-$RAND_VAL"
NETWORK=$(ibmcloud pi netcpu $NETNAME --dns-servers "9.9.9.9" | grep -m 1 ID | awk '{print $2}') || true

if [ -z "$NETWORK" ]; then echo "FAIL: fail to configure network."; exit 1; fi

ID=$(ibmcloud pi instance-create $NAME --image ubuntu_2004_tier1 --key-name $SSH_KEY --memory 8 --processor-type shared --processors '0.5' --network $NETWORK --storage-type tier1 | grep -m 1 ID | awk '{print $2}') || true

# Wait it is registred
sleep 120

# If no ID, stop with error
if [ -z "$ID" ]; then echo "FAIL: fail to get ID. Probably VM has not started correctly."; exit 1; fi

# Using ID, get IP
# First, wait it starts
# Typical time needed: 5 to 6 minutes
TIMEOUT=10
i=0
while [ $i -lt $TIMEOUT ] && [ -z "$(ibmcloud pi in $ID | grep 'External Address:')" ]; do
  i=$((i+1))
  sleep 60
done
# Fail to connect
if [ "$i" == "$TIMEOUT" ]; then echo "FAIL: fail to get IP" ; delete_vm $ID; sleep 120; delete_network $NETWORK; exit 1; fi

IP=$(ibmcloud pi in $ID | grep -Eo "External Address:[[:space:]]*[0-9.]+" | cut -d ' ' -f3)

# Check if the server is up
sleep 360

TIMEOUT=10
i=0
mkdir -p ~/.ssh
while [ $i -lt $TIMEOUT ] && ! ssh ubuntu@$IP -i /etc/ssh-volume/ssh-privatekey echo OK
do
  if ! ssh-keyscan -t rsa $IP >> ~/.ssh/known_hosts; then echo "keyscan failed, try again"; fi
  i=$((i+1))
  sleep 60
done
# Fail to connect, try to reboot to bypass grub trouble
if [ "$i" == "$TIMEOUT" ]; then
  echo "Fail to get IP. Rebooting."
  ibmcloud pi insrb $ID
  # And try to connect again
  j=0
  while [ $j -lt $TIMEOUT ] && ! ssh ubuntu@$IP -i /etc/ssh-volume/ssh-privatekey echo OK
  do
    if ! ssh-keyscan -t rsa $IP >> ~/.ssh/known_hosts; then echo "keyscan failed, try again"; fi
    j=$((j+1))
    sleep 60
  done
  # Fail again to connect
  if [ "$j" == "$TIMEOUT" ]; then echo "FAIL: fail to connect to the VM" ; echo "Going to sleep" ; sleep 7200 ; sleep infinity ; delete_vm $ID; sleep 120; delete_network $NETWORK; exit 1; fi
fi

# Get test script and execute it
ssh ubuntu@$IP -i /etc/ssh-volume/ssh-privatekey wget https://raw.githubusercontent.com/ppc64le-cloud/docker-ce-build/main/test-containerd/test_on_powervs.sh
ssh ubuntu@$IP -i /etc/ssh-volume/ssh-privatekey sudo bash test_on_powervs.sh $RUNC_FLAVOR $TEST_RUNTIME
scp -i /etc/ssh-volume/ssh-privatekey "ubuntu@$IP:/home/containerd_test/containerd/*.xml" ${OUTPUT}

delete_vm $ID
sleep 120
delete_network $NETWORK
