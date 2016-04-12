#!/bin/bash

DOCKER_DIR="/bin"
IPTABLES_DIR="/sbin"
SYS_DIR="/usr/bin"


chain_exists() {
    [ $# -lt 1 -o $# -gt 2 ] && {
        echo "Usage: chain_exists <chain_name> [table]" >&2
        return 1
    }
    local chain_name="$1" ; shift
    [ $# -eq 1 ] && local table="--table $1"
    ${IPTABLES_DIR}/iptables $table -n --list "$chain_name" >/dev/null 2>&1
}

DOCKER_INT="docker0"
DOCKER_NETWORK="172.17.0.0/16"

${IPTABLES_DIR}/iptables-save | ${SYS_DIR}/grep -v -- '-j DOCKER' | ${IPTABLES_DIR}/iptables-restore
chain_exists DOCKER && ${IPTABLES_DIR}/iptables -X DOCKER
chain_exists DOCKER nat && ${IPTABLES_DIR}/iptables -t nat -X DOCKER

${IPTABLES_DIR}/iptables -N DOCKER
${IPTABLES_DIR}/iptables -t nat -N DOCKER

${IPTABLES_DIR}/iptables -A FORWARD -o ${DOCKER_INT} -j DOCKER
${IPTABLES_DIR}/iptables -A FORWARD -o ${DOCKER_INT} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
${IPTABLES_DIR}/iptables -A FORWARD -i ${DOCKER_INT} ! -o ${DOCKER_INT} -j ACCEPT
${IPTABLES_DIR}/iptables -A FORWARD -i ${DOCKER_INT} -o ${DOCKER_INT} -j ACCEPT

${IPTABLES_DIR}/iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
${IPTABLES_DIR}/iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
${IPTABLES_DIR}/iptables -t nat -A POSTROUTING -s ${DOCKER_NETWORK} ! -o ${DOCKER_INT} -j MASQUERADE

containers=`${DOCKER_DIR}/docker ps -q`

if [ `echo ${containers} | ${SYS_DIR}/wc -c` -gt "1" ] ; then
        for container in ${containers} ; do
                rules=`${DOCKER_DIR}/docker port ${container} | ${SYS_DIR}/sed 's/ //g'`

                if [ `echo ${rules} | ${SYS_DIR}/wc -c` -gt "1" ] ; then
                        ipaddr=`${DOCKER_DIR}/docker inspect -f "{{.NetworkSettings.IPAddress}}" ${container}`

                        for rule in ${rules} ; do
                                src=`echo ${rule} | ${SYS_DIR}/awk -F'->' '{ print $2 }'`
                                dst=`echo ${rule} | ${SYS_DIR}/awk -F'->' '{ print $1 }'`

                                src_ip=`echo ${src} | ${SYS_DIR}/awk -F':' '{ print $1 }'`
                                src_port=`echo ${src} | ${SYS_DIR}/awk -F':' '{ print $2 }'`

                                dst_port=`echo ${dst} | ${SYS_DIR}/awk -F'/' '{ print $1 }'`
                                dst_proto=`echo ${dst} | ${SYS_DIR}/awk -F'/' '{ print $2 }'`

                                ${IPTABLES_DIR}/iptables -A DOCKER -d ${ipaddr}/32 ! -i ${DOCKER_INT} -o ${DOCKER_INT} -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j ACCEPT

                                ${IPTABLES_DIR}/iptables -t nat -A POSTROUTING -s ${ipaddr}/32 -d ${ipaddr}/32 -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j MASQUERADE
                                ${IPTABLES_DIR}/iptables -t nat -A DOCKER ! -i ${DOCKER_INT} -p ${dst_proto} -m ${dst_proto} --dport ${src_port} -j DNAT --to-destination ${ipaddr}:${dst_port}
                        done
                fi
        done
fi
