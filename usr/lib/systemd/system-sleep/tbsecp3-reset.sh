#!/bin/bash

# TVH_UNIT: se impostata (es. tvheadend.service, container Quadlet/Podman)
# tvheadend viene fermato e riavviato con systemctl. Se vuota si usa il
# container Docker, come prima.
TVH_UNIT="${TVH_UNIT:-}"

tvh_stop() {
    if [ -n "$TVH_UNIT" ]; then
        systemctl stop "$TVH_UNIT" 2>/dev/null
    else
        CONTAINER_NAME=$(docker ps -a | grep -i tvheadend | awk '{print $NF}')
        docker stop -t 3 "$CONTAINER_NAME" 2>/dev/null
    fi
}

tvh_start() {
    if [ -n "$TVH_UNIT" ]; then
        systemctl start "$TVH_UNIT" 2>/dev/null
    else
        CONTAINER_NAME=$(docker ps -a | grep -i tvheadend | awk '{print $NF}')
        docker start "$CONTAINER_NAME" 2>/dev/null
    fi
}

case $1 in
    pre)
        echo "tbsecp3-reset: pre-suspend - stopping tvheadend and unloading modules"
        tvh_stop
        echo 1 > /sys/bus/pci/devices/{{TBS_PCI_1}}/remove 2>/dev/null
        echo 1 > /sys/bus/pci/devices/{{TBS_PCI_2}}/remove 2>/dev/null
        sleep 1
        modprobe -r tbsecp3
        modprobe -r gx1133
        modprobe -r tas2101
        ;;
    post)
        echo "tbsecp3-reset: post-resume - reloading modules and starting tvheadend"
        sleep 2
        echo 1 > /sys/bus/pci/rescan
        sleep 2
        modprobe tas2101
        modprobe gx1133
        modprobe tbsecp3
        sleep 5
        tvh_start
        ;;
esac
