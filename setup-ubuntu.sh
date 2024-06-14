#!/bin/sh

. ./functions.sh

NAME=$1
MAC=$2
IP=$3

virsh net-update susecon24-demo add ip-dhcp-host --live --config \
    "<host mac='$MAC' name='$NAME' ip='$IP' />"

# Prepare the cloudinit ISO
# virt-install forces the on_reboot to destroy if the --cloud-init parameter is used, so we prepare the ISO ourselves
mkdir -p tmp/cloudinit
cat >tmp/cloudinit/user-data <<EOF
#cloud-config

hostname: $NAME
fqdn: $NAME.susecon24.com
ssh_pwauth: true
password: linux
chpasswd:
  expire: false

ssh_authorized_keys:
  - `cat "${PWD}/id_rsa.pub"`

bootcmd:
  - [sed, 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=8/', -i, /etc/default/grub]
  - [sed, 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=8/', -i, /etc/default/grub.d/50-cloudimg-settings.cfg]
  - [grub-mkconfig, -o, /boot/grub/grub.cfg]
  - [sh, -c, "cd /boot; ln -s /boot/grub/ grub2"]
  - [ln, -s, /usr/sbin/grub-mkconfig, /usr/sbin/grub2-mkconfig]
EOF

echo "instance-id: $NAME" >tmp/cloudinit/meta-data

xorrisofs -o pool/ubuntu-cloudinit-$NAME.iso -J -V cidata -input-charset utf8 -rational-rock tmp/cloudinit/

# Create the Ubuntu VM
qemu-img create -f qcow2 -F qcow2 -b "${PWD}/data/vms/jammy-server-cloudimg-amd64.img" "${PWD}/pool/$NAME.qcow2" 40G
virt-install -n susecon24-$NAME \
    --memory 1024 \
    --vcpus 1 \
    --import \
    --disk $PWD/pool/$NAME.qcow2,format=qcow2 \
    --disk $PWD/pool/ubuntu-cloudinit-$NAME.iso,device=cdrom \
    --network network=susecon24-demo,mac=$MAC \
    --graphics=vnc \
    --os-variant ubuntu22.04 \
    --noautoconsole

wait_for_machine ubuntu@$IP

# Eject the cloud init cdrom for future boots
virsh change-media susecon24-$NAME sda --eject --live --config

# Bootstrap the Ubuntu VM
${SSH} root@192.168.110.2 mgrctl exec -- mgr-bootstrap --activation-keys=1-UBUNTU-2204 --script=ubuntu-bootstrap.sh --force-bundle
${SSH} ubuntu@$IP sudo sh -c '"curl -s http://manager.susecon24.com/pub/bootstrap/ubuntu-bootstrap.sh | bash -"'  
${SSH} root@192.168.110.2 mgrctl exec -- salt-key -y --accept $NAME.susecon24.com

# Wait for Ubuntu system to be completely bootstrapped
COMPLETED_TASKS=`spacecmd -u admin -p admin system_listeventhistory $NAME.susecon24.com 2>/dev/null | grep 'Status: \+Completed' | wc -l`
while test $COMPLETED_TASKS -ne 3
do
    sleep 10
done

# Create a snapshot of the Ubuntu VM
cat >tmp/snapshot.xml <<EOF
<domainsnapshot>
    <name>ubuntu</name>
</domainsnapshot>
EOF
virsh snapshot-create susecon24-$NAME tmp/snapshot.xml
