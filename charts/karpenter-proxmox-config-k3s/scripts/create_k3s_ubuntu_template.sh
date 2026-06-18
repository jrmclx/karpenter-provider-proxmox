#!/bin/bash

# ----------------------------------------------------------------------------------
# create_k3s_ubuntu_template.sh
#
# Builds a Proxmox VM template for K3s worker nodes based on an Ubuntu cloud image.
# The K3s agent is installed but not started — cluster join is handled
# at provisioning time via Cloud-Init (e.g. by Karpenter).
#
# Forked from the kproximate project template building example.
# Source: https://github.com/jedrw/kproximate/tree/main/examples
#
# Usage (on a PVE Host):
#   ./create_k3s_ubuntu_template.sh <codename> <vmid> [options]
#
# Options:
#   -c, --codename   NAME   Ubuntu release codename, e.g. noble, jammy
#   -i, --vmid       ID     Proxmox VM ID for the template, e.g. 9000
#   -t, --template   NAME   Template name            (default: ubuntu24-k3s-worker)
#   -s, --storage    NAME   Proxmox storage name     (default: auto-detected)
#   -v, --vlan       TAG    VLAN tag for the NIC     (default: none)
#   -d, --disk       SIZE   Disk size, e.g. 30G      (default: 30G)
#   -b, --bridge     NAME   Network bridge           (default: vmbr0)
#   -k, --k3sversion VER    K3s version, e.g. v1.35.2+k3s1  (default: latest stable)
#
# Examples:
#   ./create_k3s_ubuntu_template.sh -c noble -i 9000
#   ./create_k3s_ubuntu_template.sh -c noble -i 9000 -s ssd-pool -d 50G
#   ./create_k3s_ubuntu_template.sh -c jammy -i 5000 -t jammy-k3s-worker -v 10 -b vmbr1
# ----------------------------------------------------------------------------------

set -euo pipefail

# Privilege check (this script requires elevation)
if [[ "$EUID" -ne 0 ]]; then
    echo "Root privileges required — restarting with sudo..." >&2
    exec sudo "$0" "$@"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--codename)    CODENAME="$2";     shift 2 ;;
        -i|--vmid)        VMID="$2";         shift 2 ;;    
        -t|--template)    TPL_NAME="$2";     shift 2 ;;
        -s|--storage)     STORAGE="$2";      shift 2 ;;
        -v|--vlan)        VLAN="$2";         shift 2 ;;
        -d|--disk)        DISKSIZE="$2";     shift 2 ;;
        -b|--bridge)      BRIDGE="$2";       shift 2 ;;
        -k|--k3sversion)  K3S_VERSION="$2";  shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Default values (used only if not set via arguments)
TPL_NAME="${TPL_NAME:-ubuntu24-k3s-worker}" # The name of the resulting template
VLAN="${VLAN:-}" # The vlan tag for the template network interface, leave as empty string for no tag
DISKSIZE="${DISKSIZE:-30G}"
BRIDGE="${BRIDGE:-vmbr0}"
K3S_VERSION="${K3S_VERSION:-}"  # empty = latest stable

# Find all active storages that can host VM images
detect_storage() {
    local preselect="${1:-}"

    mapfile -t STORAGES < <(
        pvesm status --content images 2>/dev/null \
            | awk 'NR>1 && $3=="active" {print $1, $4, $5}'
    )

    if [[ ${#STORAGES[@]} -eq 0 ]]; then
        echo "Error: no active storage found for VM images." >&2
        exit 1
    fi

    # Validate preselected value if provided
    if [[ -n "$preselect" ]]; then
        for entry in "${STORAGES[@]}"; do
            if [[ "${entry%% *}" == "$preselect" ]]; then
                echo "$preselect"
                return
            fi
        done
        echo "Warning: storage '$preselect' not found or inactive." >&2
        echo "" >&2
    fi

    # Single storage — no prompt needed
    if [[ ${#STORAGES[@]} -eq 1 ]]; then
        echo "${STORAGES[0]%% *}"
        return
    fi

    # Multiple storages — show a menu
    echo "Available storages:" >&2
    echo "" >&2
    local i=1
    for entry in "${STORAGES[@]}"; do
        local name used total
        name=$(echo "$entry"  | awk '{print $1}')
        used=$(echo "$entry"  | awk '{print $2}')
        total=$(echo "$entry" | awk '{print $3}')
        printf "  [%d] %-20s used: %s / %s\n" "$i" "$name" "$used" "$total" >&2
        ((i++))
    done
    echo "" >&2

    local choice
    while true; do
        read -rp "Select storage [1-${#STORAGES[@]}]: " choice >&2
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#STORAGES[@]} )); then
            echo "${STORAGES[$((choice-1))]%% *}"
            return
        fi
        echo "Invalid choice, please enter a number between 1 and ${#STORAGES[@]}." >&2
    done
}

STORAGE="$(detect_storage "${STORAGE:-}")"

if [[ -z "$STORAGE" ]]; then
    echo "Error: no active storage found for VM images. Use -s|--storage to specify one."
    exit 1
fi

# Check the required variables have been set
for var in CODENAME VMID TPL_NAME STORAGE DISKSIZE BRIDGE 
do
    if [[ -z "${!var}" ]]
    then
        echo "$var is not set"
        exit 1
    fi
done

# Check for libguestfs-tools
if [[ $(dpkg-query -W --showformat='${Status}\n' libguestfs-tools | grep "install ok installed") == "" ]]; then
    apt update -y
    apt install libguestfs-tools -y
fi

set -x

## If it doesn't already exist download a new $CODENAME image ie. https://cloud-images.ubuntu.com/kinetic/current/kinetic-server-cloudimg-amd64.img
## Links for newer/other images can be found here: https://cloud-images.ubuntu.com/, the .img you need should match the naming convention from the above line.
if [[ ! -f $CODENAME-server-cloudimg-amd64.img ]]; then
    wget https://cloud-images.ubuntu.com/${CODENAME}/current/${CODENAME}-server-cloudimg-amd64.img
fi

# Grab the name of the file
IMG=$(ls | grep ^${CODENAME}-server-cloudimg-amd64.img$)

NEWDISK=${CODENAME}.img

# Expand the image
virt-filesystems --long -h --all --format=raw -a $IMG
truncate -r $IMG $NEWDISK
truncate -s $DISKSIZE $NEWDISK
virt-resize --format raw --expand /dev/sda1 $IMG $NEWDISK

# Configure the new img with K3s agent service installed with dummy values, disabled and not started.
# Cluster join operation will be initiated by Cloud-Init.
virt-customize \
    -a $NEWDISK \
    --install qemu-guest-agent,nfs-common,containerd,runc,curl \
    --firstboot-command "curl -sfL https://get.k3s.io | K3S_URL=https://dummy:6443 K3S_TOKEN=dummy INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_VERSION=$K3S_VERSION sh -" \
    --truncate /etc/machine-id

# Build a vm from which to create a proxmox template with Qemu Guest Agent enabled
qm create $VMID \
    --name $TPL_NAME\
    --memory 2048 --balloon 2048 \
    --cpu cputype=host --cores 2 \
    --bios ovmf \
    --agent enabled=1

if [[ -n "$VLAN" ]]
then
    qm set $VMID --net0 virtio,bridge=$BRIDGE,firewall=1,tag=$VLAN
else
    qm set $VMID --net0 virtio,bridge=$BRIDGE,firewall=1
fi

# System disk
qm set $VMID \
    --efidisk0 $STORAGE:0 \
    --scsihw virtio-scsi-single \
    --scsi0 ${STORAGE}:0,import-from=$(realpath ${NEWDISK}),cache=writeback,discard=on,iothread=1,ssd=1 \
    --boot order=scsi0

# # Cloud-Init drive to inject dhcp configuration - if not using Cloud-Init network-config section
# qm set $VMID \
#     --scsi1 $STORAGE:cloudinit \
#     --ipconfig0 ip=dhcp

# Convert the VM into template
qm template $VMID

# Remove the image
rm $NEWDISK

echo "✓ Template $TPL_NAME ($VMID) successfully created."
