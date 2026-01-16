#!/bin/bash
#
# RCP CIDR Patch Installation Script
#
# This script applies the configurable host_subnet_size patch to the
# NVIDIA Spectrum-X RCP tool, enabling support for /29, /30, and /31 subnets.
#
# Usage:
#   ./apply-cidr-patch.sh [OPTIONS]
#
# Options:
#   -c, --container NAME    Name of the RCP container (default: spectrum-x-rcp)
#   -h, --help              Show this help message
#   -v, --verify            Verify patch was applied correctly
#   -r, --rollback          Rollback to original files (requires backup)
#

set -e

# Default values
CONTAINER_NAME="spectrum-x-rcp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/patches"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# Target paths in the container
SPCX_CORE_PATH="/usr/local/lib/python3.12/dist-packages/spcx_core"
IPAM_PATH="${SPCX_CORE_PATH}/configurator/ipv4am.py"
CONFIG_PATH="${SPCX_CORE_PATH}/config/system_config.py"
NODES_INFO_PATH="${SPCX_CORE_PATH}/nodes_info_builder.py"
LEAF_TEMPLATE_PATH="${SPCX_CORE_PATH}/switch/cumulus/none/leaf_yaml.j2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
RCP CIDR Patch Installation Script

This script applies the configurable host_subnet_size patch to the
NVIDIA Spectrum-X RCP tool, enabling support for /29, /30, and /31 subnets.

Usage:
    $0 [OPTIONS]

Options:
    -c, --container NAME    Name of the RCP container (default: spectrum-x-rcp)
    -h, --help              Show this help message
    -v, --verify            Verify patch was applied correctly
    -r, --rollback          Rollback to original files (requires backup)

Examples:
    # Apply patch to default container
    $0

    # Apply patch to custom container name
    $0 -c my-rcp-container

    # Verify the patch
    $0 -v

    # Rollback changes
    $0 -r

After applying the patch, add 'host_subnet_size' to your config.yaml:
    host_subnet_size: 30  # Options: 29, 30, or 31 (default: 31)

EOF
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_error "Container '${CONTAINER_NAME}' is not running"
        echo "Available containers:"
        docker ps --format '  {{.Names}}'
        exit 1
    fi
    print_info "Found running container: ${CONTAINER_NAME}"
}

backup_files() {
    print_info "Creating backup of original files..."
    mkdir -p "${BACKUP_DIR}"

    # Backup ipv4am.py
    docker cp "${CONTAINER_NAME}:${IPAM_PATH}" "${BACKUP_DIR}/ipv4am.py.orig" 2>/dev/null || {
        print_warn "Could not backup ipv4am.py - file may not exist"
    }

    # Backup system_config.py
    docker cp "${CONTAINER_NAME}:${CONFIG_PATH}" "${BACKUP_DIR}/system_config.py.orig" 2>/dev/null || {
        print_warn "Could not backup system_config.py - file may not exist"
    }

    # Backup nodes_info_builder.py
    docker cp "${CONTAINER_NAME}:${NODES_INFO_PATH}" "${BACKUP_DIR}/nodes_info_builder.py.orig" 2>/dev/null || {
        print_warn "Could not backup nodes_info_builder.py - file may not exist"
    }

    # Backup leaf_yaml.j2
    docker cp "${CONTAINER_NAME}:${LEAF_TEMPLATE_PATH}" "${BACKUP_DIR}/leaf_yaml.j2.orig" 2>/dev/null || {
        print_warn "Could not backup leaf_yaml.j2 - file may not exist"
    }

    print_info "Backups saved to: ${BACKUP_DIR}"
}

apply_patch() {
    print_info "Applying CIDR patch to container: ${CONTAINER_NAME}"

    # Check if patch files exist
    if [[ ! -f "${PATCHES_DIR}/ipv4am.py" ]]; then
        print_error "Patch file not found: ${PATCHES_DIR}/ipv4am.py"
        exit 1
    fi

    if [[ ! -f "${PATCHES_DIR}/system_config.py" ]]; then
        print_error "Patch file not found: ${PATCHES_DIR}/system_config.py"
        exit 1
    fi

    if [[ ! -f "${PATCHES_DIR}/nodes_info_builder.py" ]]; then
        print_error "Patch file not found: ${PATCHES_DIR}/nodes_info_builder.py"
        exit 1
    fi

    if [[ ! -f "${PATCHES_DIR}/leaf_yaml.j2" ]]; then
        print_error "Patch file not found: ${PATCHES_DIR}/leaf_yaml.j2"
        exit 1
    fi

    # Copy patched ipv4am.py
    print_info "Patching ipv4am.py..."
    docker cp "${PATCHES_DIR}/ipv4am.py" "${CONTAINER_NAME}:${IPAM_PATH}"

    # Copy patched system_config.py
    print_info "Patching system_config.py..."
    docker cp "${PATCHES_DIR}/system_config.py" "${CONTAINER_NAME}:${CONFIG_PATH}"

    # Copy patched nodes_info_builder.py
    print_info "Patching nodes_info_builder.py..."
    docker cp "${PATCHES_DIR}/nodes_info_builder.py" "${CONTAINER_NAME}:${NODES_INFO_PATH}"

    # Copy patched leaf_yaml.j2
    print_info "Patching leaf_yaml.j2..."
    docker cp "${PATCHES_DIR}/leaf_yaml.j2" "${CONTAINER_NAME}:${LEAF_TEMPLATE_PATH}"

    print_info "Patch applied successfully!"
}

verify_patch() {
    print_info "Verifying patch installation..."

    # Check if ipv4am.py contains the patch marker
    if docker exec "${CONTAINER_NAME}" grep -q "host_subnet_size" "${IPAM_PATH}" 2>/dev/null; then
        print_info "ipv4am.py: PATCHED"
    else
        print_error "ipv4am.py: NOT PATCHED or file missing"
        return 1
    fi

    # Check if system_config.py contains the patch marker
    if docker exec "${CONTAINER_NAME}" grep -q "_set_host_subnet_size" "${CONFIG_PATH}" 2>/dev/null; then
        print_info "system_config.py: PATCHED"
    else
        print_error "system_config.py: NOT PATCHED or file missing"
        return 1
    fi

    # Check if _get_subnet_config method exists
    if docker exec "${CONTAINER_NAME}" grep -q "_get_subnet_config" "${IPAM_PATH}" 2>/dev/null; then
        print_info "_get_subnet_config method: PRESENT"
    else
        print_error "_get_subnet_config method: MISSING"
        return 1
    fi

    # Check if nodes_info_builder.py contains the subnet field for leaf ports
    if docker exec "${CONTAINER_NAME}" grep -q '"subnet".*leaf_port.subnet' "${NODES_INFO_PATH}" 2>/dev/null; then
        print_info "nodes_info_builder.py: PATCHED"
    else
        print_error "nodes_info_builder.py: NOT PATCHED or file missing"
        return 1
    fi

    # Check if leaf_yaml.j2 contains dynamic subnet logic
    if docker exec "${CONTAINER_NAME}" grep -q 'port_info\["subnet"\]' "${LEAF_TEMPLATE_PATH}" 2>/dev/null; then
        print_info "leaf_yaml.j2: PATCHED"
    else
        print_error "leaf_yaml.j2: NOT PATCHED or file missing"
        return 1
    fi

    print_info "Patch verification: SUCCESS"
    return 0
}

rollback() {
    print_info "Rolling back to original files..."

    if [[ ! -d "${BACKUP_DIR}" ]]; then
        print_error "Backup directory not found: ${BACKUP_DIR}"
        print_error "Cannot rollback without backup files"
        exit 1
    fi

    # Restore ipv4am.py
    if [[ -f "${BACKUP_DIR}/ipv4am.py.orig" ]]; then
        docker cp "${BACKUP_DIR}/ipv4am.py.orig" "${CONTAINER_NAME}:${IPAM_PATH}"
        print_info "Restored: ipv4am.py"
    else
        print_warn "Original ipv4am.py backup not found"
    fi

    # Restore system_config.py
    if [[ -f "${BACKUP_DIR}/system_config.py.orig" ]]; then
        docker cp "${BACKUP_DIR}/system_config.py.orig" "${CONTAINER_NAME}:${CONFIG_PATH}"
        print_info "Restored: system_config.py"
    else
        print_warn "Original system_config.py backup not found"
    fi

    # Restore nodes_info_builder.py
    if [[ -f "${BACKUP_DIR}/nodes_info_builder.py.orig" ]]; then
        docker cp "${BACKUP_DIR}/nodes_info_builder.py.orig" "${CONTAINER_NAME}:${NODES_INFO_PATH}"
        print_info "Restored: nodes_info_builder.py"
    else
        print_warn "Original nodes_info_builder.py backup not found"
    fi

    # Restore leaf_yaml.j2
    if [[ -f "${BACKUP_DIR}/leaf_yaml.j2.orig" ]]; then
        docker cp "${BACKUP_DIR}/leaf_yaml.j2.orig" "${CONTAINER_NAME}:${LEAF_TEMPLATE_PATH}"
        print_info "Restored: leaf_yaml.j2"
    else
        print_warn "Original leaf_yaml.j2 backup not found"
    fi

    print_info "Rollback complete!"
}

# Parse command line arguments
ACTION="apply"
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--verify)
            ACTION="verify"
            shift
            ;;
        -r|--rollback)
            ACTION="rollback"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
echo "=============================================="
echo "  RCP CIDR Patch Installation Script"
echo "=============================================="
echo ""

check_container

case $ACTION in
    apply)
        backup_files
        apply_patch
        echo ""
        verify_patch
        echo ""
        echo "=============================================="
        echo "  NEXT STEPS"
        echo "=============================================="
        echo ""
        echo "1. Add 'host_subnet_size' to your config.yaml:"
        echo ""
        echo "   host_subnet_size: 30  # Options: 29, 30, 31"
        echo ""
        echo "2. Re-run RCP configuration:"
        echo ""
        echo "   docker exec spectrum-x-rcp rcp-tool all clean"
        echo "   docker exec spectrum-x-rcp rcp-tool all configure"
        echo ""
        ;;
    verify)
        verify_patch
        ;;
    rollback)
        rollback
        ;;
esac

echo ""
print_info "Done!"
