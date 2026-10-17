#!/bin/bash
# Script outline to install and build kernel.
# Author: Siddhant Jajoo.

set -e
set -u

# Check and install required build dependencies
echo "Checking for required build tools..."
REQUIRED_TOOLS="flex bison bc wget git"
for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        echo "Missing tool: $tool"
        echo "Installing required packages..."
        sudo apt-get update
        sudo apt-get install -y flex bison bc libssl-dev
        break
    fi
done

OUTDIR=/tmp/aeld
KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
KERNEL_VERSION=v5.15.163
BUSYBOX_VERSION=1_33_1
FINDER_APP_DIR=$(realpath $(dirname $0))
ARCH=arm64
CROSS_COMPILE=aarch64-none-linux-gnu-

if [ $# -lt 1 ]
then
	echo "Using default directory ${OUTDIR} for output"
else
	OUTDIR=$1
	echo "Using passed directory ${OUTDIR} for output"
fi

mkdir -p ${OUTDIR}

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/linux-stable" ]; then
    #Clone only if the repository does not exist.
	echo "CLONING GIT LINUX STABLE VERSION ${KERNEL_VERSION} IN ${OUTDIR}"
	if ! git clone ${KERNEL_REPO} --depth 1 --single-branch --branch ${KERNEL_VERSION} linux-stable; then
	    echo "Git clone failed, attempting to download tarball from kernel mirror..."
	    # Extract version number (e.g., 5.15.163 from v5.15.163)
	    VERSION_NUM=${KERNEL_VERSION#v}
	    MAJOR_MINOR=$(echo $VERSION_NUM | cut -d. -f1,2)
	    TARBALL_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/v${MAJOR_MINOR}.x/linux-${VERSION_NUM}.tar.gz"
	    echo "Downloading from ${TARBALL_URL}"
	    cd "$OUTDIR"
	    wget ${TARBALL_URL} -O linux.tar.gz
	    tar xzf linux.tar.gz
	    mv linux-${VERSION_NUM} linux-stable
	    rm linux.tar.gz
	fi
fi
if [ ! -e ${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image ]; then
    cd linux-stable
    echo "Checking out version ${KERNEL_VERSION}"
    if [ -d .git ]; then
        git checkout ${KERNEL_VERSION}
    fi

    # Configure kernel with defconfig for arm64
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    # Build the kernel
    make -j4 ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}
fi

echo "Adding the Image in outdir"
cp ${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image ${OUTDIR}/Image

echo "Creating the staging directory for the root filesystem"
cd "$OUTDIR"
if [ -d "${OUTDIR}/rootfs" ]
then
	echo "Deleting rootfs directory at ${OUTDIR}/rootfs and starting over"
    sudo rm  -rf ${OUTDIR}/rootfs
fi

# Create necessary base directories
mkdir -p ${OUTDIR}/rootfs
cd ${OUTDIR}/rootfs
mkdir -p bin sbin lib lib64 usr/bin usr/sbin usr/lib home proc sys dev etc tmp var/log

cd "$OUTDIR"
if [ ! -d "${OUTDIR}/busybox" ]
then
	if ! git clone git://busybox.net/busybox.git; then
	    echo "Git clone failed, attempting HTTPS..."
	    if ! git clone https://git.busybox.net/busybox busybox; then
	        echo "HTTPS clone failed, downloading tarball..."
	        # Extract version number (e.g., 1_33_1 -> 1.33.1)
	        BUSYBOX_VERSION_DOT=${BUSYBOX_VERSION//_/.}
	        TARBALL_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION_DOT}.tar.bz2"
	        echo "Downloading from ${TARBALL_URL}"
	        cd "$OUTDIR"
	        wget ${TARBALL_URL} -O busybox.tar.bz2
	        tar xjf busybox.tar.bz2
	        mv busybox-${BUSYBOX_VERSION_DOT} busybox
	        rm busybox.tar.bz2
	    fi
	fi
    cd busybox
    git checkout ${BUSYBOX_VERSION} 2>/dev/null || echo "Not a git repo, skipping checkout"
    # Configure busybox with defconfig and set install location
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
else
    cd busybox
fi

# Make and install busybox
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} CONFIG_PREFIX=${OUTDIR}/rootfs install

echo "Library dependencies"
cd ${OUTDIR}
${CROSS_COMPILE}readelf -a ${OUTDIR}/rootfs/bin/busybox | grep "program interpreter" || true
${CROSS_COMPILE}readelf -a ${OUTDIR}/rootfs/bin/busybox | grep "Shared library" || true

# Add library dependencies to rootfs
cd ${OUTDIR}
SYSROOT=$(${CROSS_COMPILE}gcc --print-sysroot)
cp -a ${SYSROOT}/lib64/* ${OUTDIR}/rootfs/lib64 2>/dev/null || true
cp -a ${SYSROOT}/lib/* ${OUTDIR}/rootfs/lib 2>/dev/null || true
# Make device nodes
sudo mknod -m 666 ${OUTDIR}/rootfs/dev/null c 1 3
sudo mknod -m 600 ${OUTDIR}/rootfs/dev/console c 5 1

# Ensure /tmp is writable
sudo chmod 777 ${OUTDIR}/rootfs/tmp
sudo chmod 777 ${OUTDIR}/rootfs/var/log
# Clean and build the writer utility
cd ${FINDER_APP_DIR}
make clean
make CROSS_COMPILE=${CROSS_COMPILE}

# Copy the finder related scripts and executables to the /home directory
# on the target rootfs
cp ${FINDER_APP_DIR}/writer ${OUTDIR}/rootfs/home/
cp ${FINDER_APP_DIR}/finder.sh ${OUTDIR}/rootfs/home/
cp ${FINDER_APP_DIR}/finder-test.sh ${OUTDIR}/rootfs/home/
cp -r ${FINDER_APP_DIR}/conf ${OUTDIR}/rootfs/home/
cp ${FINDER_APP_DIR}/autorun-qemu.sh ${OUTDIR}/rootfs/home/

# Fix shebang in finder.sh to use /bin/sh instead of /bin/bash (busybox doesn't have bash)
sed -i 's|#!/bin/bash|#!/bin/sh|g' ${OUTDIR}/rootfs/home/finder.sh
sed -i 's|#!/bin/bash|#!/bin/sh|g' ${OUTDIR}/rootfs/home/finder-test.sh

# Update assignment.txt for assignment3
echo "assignment3" > ${OUTDIR}/rootfs/home/conf/assignment.txt

# Modify finder-test.sh to reference conf/assignment.txt instead of ../conf/assignment.txt
sed -i 's|../conf/assignment.txt|conf/assignment.txt|g' ${OUTDIR}/rootfs/home/finder-test.sh

# Chown the root directory
sudo chown -R root:root ${OUTDIR}/rootfs

# Create initramfs.cpio.gz
cd ${OUTDIR}/rootfs
find . | cpio -H newc -o | gzip > ${OUTDIR}/initramfs.cpio.gz
