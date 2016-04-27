#!/bin/sh

chain_exists() {
    [ $# -lt 1 -o $# -gt 2 ] && {
        echo "Usage: chain_exists <chain_name> [table]" >&2
        return 1
    }
    local chain_name="$1" ; shift
    [ $# -eq 1 ] && local table="--table $1"
    iptables $table -n --list "$chain_name" >/dev/null 2>&1
}

DOCKER_INT="docker0"
DOCKER_NETWORK="172.17.0.0/16"

iptables-save | grep -v -- '-j DOCKER' | iptables-restore
chain_exists DOCKER && iptables -X DOCKER
chain_exists DOCKER nat && iptables -t nat -X DOCKER

iptables -N DOCKER
iptables -t nat -N DOCKER

iptables -A FORWARD -o ${DOCKER_INT} -j DOCKER
iptables -A FORWARD -o ${DOCKER_INT} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${DOCKER_INT} ! -o ${DOCKER_INT} -j ACCEPT
iptables -A FORWARD -i ${DOCKER_INT} -o ${DOCKER_INT} -j ACCEPT

iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
iptables -t nat -A POSTROUTING -s ${DOCKER_NETWORK} ! -o ${DOCKER_INT} -j MASQUERADE

containers=`docker ps -q`

if [ `echo ${containers} | wc -c` -gt "1" ] ; then
        for container in ${containers} ; do
                rules=`docker port ${container} | sed 's/ //g'`

                if [ `echo ${rules} | wc -c` -gt "1" ] ; then
                        ipaddr=`docker inspect -f "{{.NetworkSettings.IPAddress}}" ${container}`

                        for rule in ${rules} ; do
                                src=`echo ${rule} | awk -F'->' '{ print $2 }'`
                                dst=`echo ${rule} | awk -F'->' '{ print $1 }'`

                                src_ip=`echo ${src} | awk -F':' '{ print $1 }'`
                                src_port=`echo ${src} | awk -F':' '{ print $2 }'`

                                dst_port=`echo ${dst} | awk -F'/' '{ print $1 }'`
                                dst_proto=`echo ${dst} | awk -F'/' '{ print $2 }'`

                                iptables -A DOCKER -d ${ipaddr}/32 ! -i ${DOCKER_INT} -o ${DOCKER_INT} -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j ACCEPT

                                iptables -t nat -A POSTROUTING -s ${ipaddr}/32 -d ${ipaddr}/32 -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j MASQUERADE
                                iptables -t nat -A DOCKER ! -i ${DOCKER_INT} -p ${dst_proto} -m ${dst_proto} --dport ${src_port} -j DNAT --to-destination ${ipaddr}:${dst_port}
                        done
                fi
        done
fi
