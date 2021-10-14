#!/bin/bash
# script checking that the dockerd daemon has started

TIMEOUT=10
DAEMON="dockerd"
i=0
echo $DAEMON
while [ $i -lt $TIMEOUT ] && ! /usr/bin/pgrep $DAEMON
do
    i=$((i+1))
    sleep 2
done

pid=`/usr/bin/pgrep $DAEMON` 

if [ -z "$pid" ]
then
    echo "$DAEMON has not started after $(($TIMEOUT*2)) seconds" 2>&1 | tee -a ${LOG}
    exit 1
else
    echo "Found $DAEMON pid:$pid"  2>&1 | tee -a ${LOG}
    ps -aef | grep docker | grep -v grep
    sleep 10
    ps -aef
    if ! test -d /root/.docker 
    then
        # docker login : only for tests
        mkdir /root/.docker
        echo "$DOCKER_SECRET_AUTH" > /root/.docker/config.json
        echo "Docker login" 2>&1 | tee -a ${LOG}
    fi
    echo "Launching docker info" 2>&1 | tee -a ${LOG}
    docker info 2>&1 | tee -a ${LOG}
    
fi