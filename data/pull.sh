#!/bin/sh

mkdir -p mirror/isos vms

# Pull VM images
SUMA_IMAGE_URL=https://download.suse.de/ibs/home:/oholecek:/SUMA5-VM/images_head/SUSE-Manager-Server.x86_64-5.0.0-Qcow-Build16.3.qcow2
UBUNTU2204_IMAGE_URL=https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

for IMAGE_URL in $SUMA_IMAGE_URL $UBUNTU2204_IMAGE_URL
do
    VM_IMAGE=`basename ${IMAGE_URL}`
    if test ! -e "vms/${VM_IMAGE}"; then
        curl -L -o "vms/${VM_IMAGE}" ${IMAGE_URL}
    fi
done

# Pull ISO
SLE15SP5_URL=https://download.suse.de/install/SLE-15-SP5-Full-GM/SLE-15-SP5-Full-x86_64-GM-Media1.iso

for ISO_URL in $SLE15SP5_URL
do
    ISO=`basename ${ISO_URL}`
    if test ! -e "mirror/isos/${ISO}"; then
        curl -L -o "mirror/isos/${ISO}" ${ISO_URL}
    fi
done

. ${PWD}/../scc_conf

mkdir -p tmp

# Mirror the repositories
cat >tmp/minima.yaml <<EOF
storage:
  type: file
  path: ${PWD}/mirror
scc:
  username: ${UYUNI_SCC_USER}
  password: ${UYUNI_SCC_PASSWORD}
  archs: [x86_64, amd64]
  repo_names:
    - SUSE-Manager-Server-5.0-Pool
    - SUSE-Manager-Server-5.0-Updates
    - SUSE-Manager-Proxy-5.0-Pool
    - SUSE-Manager-Proxy-5.0-Updates
    - SUSE-Manager-Retail-Branch-Server-5.0-Pool
    - SUSE-Manager-Retail-Branch-Server-5.0-Updates
    # SLE 15-SP5 Products
    - SLE-Product-SLES15-SP5-Pool
    - SLE-Product-SLES15-SP5-Updates
    # SLE 15-SP5 Basic Modules
    - SLE-Module-Basesystem15-SP5-Pool
    - SLE-Module-Basesystem15-SP5-Updates
    - SLE-Module-Server-Applications15-SP5-Pool
    - SLE-Module-Server-Applications15-SP5-Updates
    - SLE-Module-Python3-15-SP5-Pool
    - SLE-Module-Python3-15-SP5-Updates
    - SLE15-SP5-Installer-Updates
    # Manager Tools
    - SLE-Manager-Tools15-Pool
    - SLE-Manager-Tools15-Updates
    - SLE-Manager-Tools15-BETA-Pool
    - SLE-Manager-Tools15-BETA-Updates
    # Ubuntu
    - Ubuntu-22.04-SUSE-Manager-Tools
    - Ubuntu-22.04-SUSE-Manager-Tools-Beta
EOF

MINIMA_URL=https://github.com/uyuni-project/minima/releases/download/v0.13/minima_0.13_linux_amd64.tar.gz
pushd tmp
curl -LO $MINIMA_URL
tar xf `basename $MINIMA_URL`
popd
./tmp/minima -c ${PWD}/tmp/minima.yaml sync

# Mirror the SCC data
curl -L -o tmp/refresh_scc_data.py https://raw.githubusercontent.com/uyuni-project/sumaform/master/salt/mirror/utils/refresh_scc_data.py

pushd mirror
python3 ../tmp/refresh_scc_data.py $UYUNI_SCC_USER:$UYUNI_SCC_PASSWORD
popd

# Mirror Ubuntu repositories
cat >tmp/apt-mirror.list <<EOF
set mirror_path    /srv/mirror/
set defaultarch    amd64
set nthreads       20

##
## Sources
##

deb http://archive.ubuntu.com/ubuntu jammy main
deb http://archive.ubuntu.com/ubuntu jammy-updates main
deb http://archive.ubuntu.com/ubuntu jammy-security main

deb http://archive.ubuntu.com/ubuntu jammy main
deb http://archive.ubuntu.com/ubuntu jammy-updates main
deb http://security.ubuntu.com/ubuntu jammy-security main

clean http://archive.ubuntu.com/ubuntu
clean http://security.ubuntu.com/ubuntu
EOF
podman run -it --rm -v $PWD:/srv docker.io/aptmirror/apt-mirror2 /srv/tmp/apt-mirror.list
