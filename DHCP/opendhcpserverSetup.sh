#!/bin/sh
Bridge=br1
DHCP_Serv_Inst="opendhcpV1.72.tar.gz"
Cfg_File=/opt/opendhcp/opendhcp.ini
Subnetmask="255.255.255.0"
Bridge_IP=192.168.0.1
Bridge_Subnet=`echo $Bridge_IP | rev | cut -d "." -f2- | rev`
Work_Dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
function Cfg_Gen {
	echo "[LISTEN_ON]" 
	echo $Bridge_IP 
	echo "[LOGGING]"
	echo "LogLevel=None"
	echo "[GLOBAL_OPTIONS]"
	echo "SubNetMask=$Subnetmask"
	echo "Router=$Bridge_IP"
	for i in {2..9}; do
		echo "[56:00:0$i:00:0$i:dd]"
		echo "IP=$Bridge_Subnet.$i"
	done
	for i in {10..99}; do
		echo "[56:00:$i:00:$i:dd]"
		echo "IP=$Bridge_Subnet.$i"
	done
}
wget https://downloads.sourceforge.net/project/dhcpserver/Open%20DHCP%20Server%20%28Regular%29/${DHCP_Serv_Inst}
if [ ! -f "$Work_Dir/$DHCP_Serv_Inst" ]; then
	echo "DHCP Server Installation file is missing"
	exit 0 
fi
tar -xf $Work_Dir/$DHCP_Serv_Inst -C /opt/
rm ${DHCP_Serv_Inst}
chmod 755 /opt/opendhcp/opendhcpd
ln -sf /opt/opendhcp/rc.opendhcp /etc/init.d/opendhcp
chmod 755 /etc/init.d/opendhcp
chkconfig --add opendhcp
chkconfig opendhcp on
printf "DEVICE=$Bridge\nTYPE=Bridge\nONBOOT=yes\nDELAY=0\nBOOTPROTO=static\nIPADDR=$Bridge_IP\nNETMASK=$Subnetmask\nBROADCAST=$Bridge_Subnet.255\nNETWORK=$Bridge_Subnet.0" > /etc/sysconfig/network-scripts/ifcfg-$Bridge
ifup $Bridge
echo "`Cfg_Gen`" > $Cfg_File
service opendhcp restart
