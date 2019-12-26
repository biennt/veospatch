#!/bin/bash

# 2019 Bien <bien@bienlab.com>

function get_dev() {
    ls -l /dev/vg-db-hda | grep $1 | cut -d'>' -f2 | cut -d'/' -f2-
}

function inject_files() {
    if [ -f $startup_pkg ]; then
        tar -xf $startup_pkg -C /mnt/bigip-config/
    fi

    if $firstboot_file; then
        touch /mnt/bigip-config/firstboot > /dev/null 2>&1
    fi
    if [ -f $userdata_file ]; then
        cp $userdata_file /mnt/bigip-config
    fi
}

function load_nbd() {
    is_nbd_loaded=`lsmod|grep nbd|wc -l`

    if [ $is_nbd_loaded == 0 ]; then
        modprobe nbd max_part=32
    fi
}


echo "******** Starting patching script ********"
temp_dir="$HOME/patchtmp"
userdata_file='none'
firstboot_file=true
startup_pkg='startup.tar'

if [ $UID -ne 0 ]; then
    echo You must run patch-image with sudo.
fi

oldfile="${@: -1}"
echo "File to patch $oldfile"

# There needs to be a file parameter.  
if [ $# -lt 1 ]; then
    echo You must specify a qcow2 image to patch.
else
  # The file parameter must end with .qcow2
  echo $oldfile | grep -e'\(.*\)\.qcow2'
  if [ $? -ne 0 ]; then
      echo You must specify a qcow2 image to patch.
  fi
fi


echo "Creating $temp_dir directory"
rm -rf $temp_dir
mkdir -p $temp_dir
echo "Copying $oldfile to $temp_dir/$oldfile"

echo "Loading nbd module"
load_nbd
echo "User-Data file = $userdata_file"
echo "Firstboot file = $firstboot_file"
echov"Startup file = $startup_pkg"

# exit on error
set -x

sleep 2
echo "Disconnect nbd0"
qemu-nbd -d /dev/nbd0
sleep 2
echo "Connect nbd0 to $$temp_dir/$oldfile"

qemu-nbd --connect=/dev/nbd0 $temp_dir/$oldfile
sleep 2
echo "Running pvscan"
pvscan
sleep 2
echo "Running vgchange -ay"
vgchange -ay
sleep 2
echo "Umount /mnt/bigip-config if mounted, delete and recreate /mnt/bigip-config"
rm -rf /mnt/bigip-config
mkdir -p /mnt/bigip-config

echo "Waiting 15 seconds"
sleep 15

echo "Mount /dev/vg-db-hdaset.1._config to /mnt/bigip-config"
mount /dev/vg-db-hda/set.1._config /mnt/bigip-config

echo "Injecting files..."
inject_files

sleep 2
echo "Umount /mnt/bigip-config"
umount /mnt/bigip-config

echo "Running vgchange -an"
vgchange -an
sleep 2

echo "Disconnect nbd0"
qemu-nbd -d /dev/nbd0
echo "Patched image located at $temp_dir/$oldfile"

set +x
