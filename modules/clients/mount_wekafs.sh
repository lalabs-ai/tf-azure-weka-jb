echo "$(date -u): before weka agent installation"

INSTALLATION_PATH="/tmp/weka"
mkdir -p $INSTALLATION_PATH
cd $INSTALLATION_PATH

backend_ip="${backend_lb_ip}"
# install weka using random backend ip from ips list
function retry_weka_install {
  retry_max=60
  retry_sleep=30
  count=$retry_max

  while [ $count -gt 0 ]; do
      curl --fail -o install_script.sh $backend_ip:14000/dist/v1/install && break
      count=$(($count - 1))
      echo "Retrying weka install from $backend_ip in $retry_sleep seconds..."
      sleep $retry_sleep
  done
  [ $count -eq 0 ] && {
      echo "weka install failed after $retry_max attempts"
      echo "$(date -u): weka install failed"
      return 1
  }
  chmod +x install_script.sh && ./install_script.sh
  return 0
}

retry_weka_install

echo "$(date -u): weka agent installation complete"

FILESYSTEM_NAME=default # replace with a different filesystem at need
MOUNT_POINT=/mnt/weka # replace with a different mount point at need
mkdir -p $MOUNT_POINT

weka local stop && weka local rm -f --all

gateways="${all_gateways}"
subnets="${all_subnets}"
NICS_NUM="${nics_num}"
eth0=$(ifconfig | grep eth0 -C2 | grep 'inet ' | awk '{print $2}')


function getNetStrForDpdk {
		i=$1
		j=$2
		gateways=$3

		if [ -n "$gateways" ]; then #azure and gcp
			gateways=($gateways)
		fi

		net="-o net="
		for ((i; i<$j; i++)); do
			eth=eth$i
			subnet_inet=$(ifconfig $eth | grep 'inet ' | awk '{print $2}')
			if [ -z $subnet_inet ];then
				net=""
				break
			fi
			enp=$(ls -l /sys/class/net/$eth/ | grep lower | awk -F"_" '{print $2}' | awk '{print $1}') #for azure
			bits=$(ip -o -f inet addr show $eth | awk '{print $4}')
			IFS='/' read -ra netmask <<< "$bits"

			if [ -n "$gateways" ]; then
				gateway=$${gateways[0]}
				net="$net$enp/$subnet_inet/$${netmask[1]}/$gateway"
			fi
		done
}

function retry {
  local retry_max=$1
  local retry_sleep=$2
  shift 2
  local count=$retry_max
  while [ $count -gt 0 ]; do
      "$@" && break
      count=$(($count - 1))
      echo "Retrying $* in $retry_sleep seconds..."
      sleep $retry_sleep
  done
  [ $count -eq 0 ] && {
      echo "Retry failed [$retry_max]: $*"
      echo "$(date -u): retry failed"
      return 1
  }
  return 0
}

mount_command="mount -t wekafs -o net=udp $backend_ip/$FILESYSTEM_NAME $MOUNT_POINT"
if [[ ${mount_clients_dpdk} == true ]]; then
  getNetStrForDpdk $(($NICS_NUM-1)) $(($NICS_NUM)) "$gateways" "$subnets"
  mount_command="mount -t wekafs $net -o num_cores=1 -o mgmt_ip=$eth0 $backend_ip/$FILESYSTEM_NAME $MOUNT_POINT"
fi

retry 60 45 $mount_command

rm -rf $INSTALLATION_PATH
echo "$(date -u): wekafs mount complete"
