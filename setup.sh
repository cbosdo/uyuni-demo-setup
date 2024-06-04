#!/bin/sh

# Requires openvpn access to download the images
VM_IMAGE_URL=https://download.suse.de/ibs/home:/oholecek:/SUMA5-VM/images/SUSE-Manager-Server.x86_64-5.0.0-Qcow-Build12.23.qcow2
VM_IMAGE=`basename ${VM_IMAGE_URL}`

SLE15SP5_URL=https://download.suse.de/install/SLE-15-SP5-Full-GM/SLE-15-SP5-Full-x86_64-GM-Media1.iso

# Prepare libvirt storage pool and network

mkdir -p pool

POOL_PATH=`virsh pool-dumpxml susecon24-demo 2>/dev/null | sed -n 's/^ *<path>\([^<]\+\)<\/path>/\1/p'`

# Clear the pool if not referring to $PWD/pool. This would avoid confusions
if test -n "${POOL_PATH}" -a "${POOL_PATH}" != "${PWD}/pool"; then
    virsh pool-destroy susecon24-demo
    virsh pool-undefine susecon24-demo
fi

# Create the pool
if test "${POOL_PATH}" != "${PWD}/pool"; then
cat > pool.xml << EOF
<pool type='dir'>
  <name>susecon24-demo</name>
  <target>
    <path>${PWD}/pool</path>
    <permissions>
      <mode>0755</mode>
      <owner>1000</owner>
      <group>100</group>
    </permissions>
  </target>
</pool>
EOF

virsh pool-define pool.xml
virsh pool-autostart susecon24-demo
virsh pool-start susecon24-demo
virsh pool-build susecon24-demo
fi

# Create the network
if test -z `virsh net-list --all --name | grep susecon24-demo`; then
cat > net.xml << EOF
<network>
  <name>susecon24-demo</name>
  <forward mode='nat'/>
  <bridge stp='on' delay='0'/>
  <domain name='susecon24.com' localOnly='yes'/>
  <ip address='192.168.110.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.110.2' end='192.168.110.254'/>
      <host mac='2A:C3:A7:A7:01:02' name='manager' ip='192.168.110.2'/>
      <host mac='2A:C3:A7:A7:01:03' name='demo-srv1' ip='192.168.110.3'/>
      <bootp file='pxelinux.0' server='192.168.110.2'/>
    </dhcp>
  </ip>
</network>
EOF

virsh net-define net.xml
virsh net-autostart susecon24-demo
virsh net-start susecon24-demo
fi

# Download the VM image
if test ! -e "${PWD}/pool/${VM_IMAGE}"; then
    curl -L -o "${PWD}/pool/${VM_IMAGE}" ${VM_IMAGE_URL}
fi

# Prepare an overlay image and a data disk
qemu-img create -f qcow2 -F qcow2 -b "${PWD}/pool/${VM_IMAGE}" "${PWD}/pool/manager.qcow2" 40G
qemu-img create -f qcow2 "${PWD}/pool/manager-data.qcow2" 500G

virsh pool-refresh susecon24-demo

# Generate passwordless SSH key
if test ! -e "${PWD}/id_rsa"; then
    ssh-keygen -N "" -f "$PWD/id_rsa"
fi

. ${PWD}/scc_conf

cat >"${PWD}/pool/combustion" << EOF
#!/bin/bash
# combustion: network
# script generated with https://opensuse.github.io/fuel-ignition/

# Redirect output to the console
exec > >(exec tee -a /dev/tty0 /var/log/combustion) 2>&1

# Set a password for root, generate the hash with "openssl passwd -6"
echo 'root:\$6\$3aQC9rrDLHiTf1yR\$NoKe9tko0kFIpu0rQ2y/OzOOtbVvs0Amr2bx0T4cGf6aq8PG74EmVy8lSDJdbLVVFpOSzwELWyReRCiPHa7DG0' | chpasswd -e

# Add a public ssh key and enable sshd
mkdir -pm700 /root/.ssh/
echo "`cat "${PWD}/id_rsa.pub"`" >/root/.ssh/authorized_keys
systemctl enable sshd.service

# Hostname
echo "manager" >/etc/hostname

# Registration
if ! which SUSEConnect > /dev/null 2>&1; then
    zypper --non-interactive install suseconnect-ng
fi
ARCH=\`arch\`
BASE_PRODUCT=\`xmllint --xpath "/product/name/text()" /etc/products.d/baseproduct\`
BASE_VERSION=\`xmllint --xpath "//version/text()" /etc/products.d/baseproduct\`
SUSEConnect --product \${BASE_PRODUCT}/\${BASE_VERSION}/\${ARCH} --email ${SCC_EMAIL} --regcode ${SCC_SLE_MICRO_REGCODE}
SUSEConnect --product SUSE-Manager-Server/5.0/\${ARCH} --email ${SCC_EMAIL} --regcode ${SCC_SUMA_SERVER_REGCODE}

# Leave a marker
echo "Configured with combustion" > /etc/issue.d/combustion
EOF

# Create the manager server VM
virt-install -n susecon24-manager \
    --memory 16384 \
    --vcpus 4 \
    --import \
    --disk "${PWD}/pool/manager.qcow2,format=qcow2" \
    --disk "${PWD}/pool/manager-data.qcow2,format=qcow2" \
    --network network=susecon24-demo,mac.address=2A:C3:A7:A7:01:02 \
    --graphics vnc \
    --os-variant slem5.5 \
    --qemu-commandline="-fw_cfg name=opt/org.opensuse.combustion/script,file=${PWD}/pool/combustion" \
    --noautoconsole

# Wait for the server to be up
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa"
SSH="ssh ${SSH_OPTS}"
SCP="scp ${SSH_OPTS}" 
while true;
do
    ${SSH} root@192.168.110.2 /usr/bin/true 2>/dev/null
    if test $? -eq 0; then
        break
    fi
    sleep 10
done

# Format and mount the data disk
${SSH} root@192.168.110.2 mgr-storage-server /dev/vdb

# Install the SUSE Manager server
cat > mgradm.yaml << EOF
ssl:
  password: ${UYUNI_SSL_PASSWORD}
admin:
  password: ${UYUNI_ADMIN_PASSWORD}
  email: admin@manager.susecon24.com
scc:
  user: ${UYUNI_SCC_USER}
  password: ${UYUNI_SCC_PASSWORD}
EOF
${SCP} mgradm.yaml root@192.168.110.2:/root/
${SSH} root@192.168.110.2 mgradm install podman -c /root/mgradm.yaml --organization=SUSECon24

# Add Ubuntu 22.04 and SLE 15 SP5 channels
${SSH} root@192.168.11.2 mgrctl exec -- mgr-sync add channels \
    ubuntu-2204-amd64-main-amd64 \
    ubuntu-22.04-suse-manager-tools-amd64 \
    ubuntu-2204-amd64-main-backports-amd64 \
    ubuntu-2204-amd64-main-security-amd64 \
    ubuntu-2204-amd64-main-updates-amd64 \
    sle-product-sles15-sp5-pool-x86_64 \
    sle-product-sles15-sp5-updates-x86_64 \
    sle-manager-tools15-pool-x86_64-sp5 \
    sle-manager-tools15-updates-x86_64-sp5 \
    sle-module-basesystem15-sp5-pool-x86_64 \
    sle-module-basesystem15-sp5-updates-x86_64 \
    sle-module-server-applications15-sp5-pool-x86_64 \
    sle-module-server-applications15-sp5-updates-x86_64 \
    sle-module-python3-15-sp5-pool-x86_64 \
    sle-module-python3-15-sp5-updates-x86_64 \
    sle15-sp5-installer-updates-x86_64

# Wait for reposync to finish
while true
do
    FINISHED_SYNCS=`${SSH} root@192.168.110.2 mgrctl exec -- grep "\"'Sync completed'\"" -r /var/log/rhn/reposync/ 2>/dev/null | wc -l`
    if test ${FINISHED_SYNCS} -eq 16; then
        break
    fi
    sleep 20
done

# TODO Download the SLE 15SP5 ISO on the server and copy it in the container

# TODO Create the distro profile

# TODO Download the Ubuntu qcow2 image

# TODO Create the Ubuntu VM

# TODO Bootstrap the Ubuntu VM

# TODO Change the grub settings of the Ubuntu VM

# TODO Create a snapshot of the Ubuntu VM

