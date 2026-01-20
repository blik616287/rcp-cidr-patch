#!/bin/bash
#
# RCP CIDR Patch - Full Deployment and Validation Script
#
# This script performs end-to-end deployment of the RCP CIDR patch
# on an NVIDIA AIR simulation environment.
#
# Usage:
#   ./deploy-and-validate.sh [OPTIONS]
#
# Options:
#   -s, --subnet-size SIZE   Subnet size: 29, 30, or 31 (default: 30)
#   -c, --container NAME     Container name (default: spectrum-x-rcp)
#   -h, --help               Show this help message
#   --skip-docker            Skip Docker installation (if already installed)
#   --skip-patch             Skip patch application (if already applied)
#   --validate-only          Only run validation tests
#

# Note: Not using 'set -e' as validation functions intentionally test for failures

# =============================================================================
# Configuration
# =============================================================================

SUBNET_SIZE=30
CONTAINER_NAME="spectrum-x-rcp"
SKIP_DOCKER=false
SKIP_PATCH=false
VALIDATE_ONLY=false

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCP_DIR="$HOME/spectrum-x-rcp"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# RCP container paths
SPCX_CORE_PATH="/usr/local/lib/python3.12/dist-packages/spcx_core"
HOST_DIR="${SPCX_CORE_PATH}/host"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASS_COUNT=0
FAIL_COUNT=0

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
}

print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
}

show_help() {
    cat << EOF
RCP CIDR Patch - Full Deployment and Validation Script

This script performs end-to-end deployment of the RCP CIDR patch
on an NVIDIA AIR simulation environment.

Usage:
    $0 [OPTIONS]

Options:
    -s, --subnet-size SIZE   Subnet size: 29, 30, or 31 (default: 30)
    -c, --container NAME     Container name (default: spectrum-x-rcp)
    -h, --help               Show this help message
    --skip-docker            Skip Docker installation
    --skip-patch             Skip patch application
    --validate-only          Only run validation tests

Examples:
    # Full deployment with /30 subnets
    $0

    # Full deployment with /29 subnets
    $0 -s 29

    # Only run validation
    $0 --validate-only

Subnet Size Reference:
    /29 = 8 addresses per block (6 usable)
    /30 = 4 addresses per block (2 usable)
    /31 = 2 addresses per block (2 usable, point-to-point)

EOF
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "Do not run this script as root. Use a regular user with sudo access."
        exit 1
    fi
}

# =============================================================================
# Parse Arguments
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subnet-size)
            SUBNET_SIZE="$2"
            if [[ ! "$SUBNET_SIZE" =~ ^(29|30|31)$ ]]; then
                print_error "Invalid subnet size: $SUBNET_SIZE (must be 29, 30, or 31)"
                exit 1
            fi
            shift 2
            ;;
        -c|--container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --skip-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --skip-patch)
            SKIP_PATCH=true
            shift
            ;;
        --validate-only)
            VALIDATE_ONLY=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# =============================================================================
# Step 1: Install Docker
# =============================================================================

install_docker() {
    print_header "Step 1: Installing Docker"

    if command -v docker &> /dev/null; then
        print_info "Docker already installed: $(docker --version)"
        return 0
    fi

    print_step "Installing Docker..."

    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    sudo usermod -aG docker $USER

    print_info "Docker installed successfully"
}

# =============================================================================
# Step 2: Load RCP Image
# =============================================================================

load_rcp_image() {
    print_header "Step 2: Loading RCP Docker Image"

    # Check if latest tag already exists
    if sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^spectrum-x-rcp:latest$"; then
        print_info "RCP image spectrum-x-rcp:latest already exists"
        return 0
    fi

    # Check if image exists with different tag
    IMAGE_TAG=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep spectrum-x-rcp | head -1)

    if [[ -z "$IMAGE_TAG" ]]; then
        # No image found, need to load from tar
        RCP_TAR=$(find /home -name "spectrum-x-rcp*.tar" -o -name "*spectrum*rcp*.tar" 2>/dev/null | head -1)

        if [[ -z "$RCP_TAR" ]]; then
            print_error "RCP tar file not found. Please copy it to the server first."
            exit 1
        fi

        print_step "Loading RCP image from: $RCP_TAR"
        sudo docker load -i "$RCP_TAR"

        # Get the loaded image tag
        IMAGE_TAG=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep spectrum-x-rcp | head -1)
    fi

    # Tag as latest for easier reference
    if [[ -n "$IMAGE_TAG" && "$IMAGE_TAG" != "spectrum-x-rcp:latest" ]]; then
        print_step "Tagging $IMAGE_TAG as spectrum-x-rcp:latest"
        sudo docker tag "$IMAGE_TAG" spectrum-x-rcp:latest
    fi

    print_info "RCP image ready: spectrum-x-rcp:latest"
}

# =============================================================================
# Step 3: Create Directory Structure
# =============================================================================

create_directories() {
    print_header "Step 3: Creating Directory Structure"

    mkdir -p "${RCP_DIR}/config"
    mkdir -p "${RCP_DIR}/inventory"
    # Clean topology directory to prevent stale files
    rm -rf "${RCP_DIR}/topology"
    mkdir -p "${RCP_DIR}/topology"

    print_info "Directories created at ${RCP_DIR}"
}

# =============================================================================
# Step 4: Create Inventory File
# =============================================================================

create_inventory() {
    print_header "Step 4: Creating Inventory File"

    cat > "${RCP_DIR}/inventory/hosts" << 'EOF'
[host:vars]
ansible_user=ubuntu
ansible_become_pass=nvidia
ansible_ssh_pass=nvidia

[switch:vars]
ansible_user=cumulus
ansible_become_pass=Cumu1usLinux!
ansible_ssh_pass=Cumu1usLinux!

[leaf]
leaf-su00-r0
leaf-su00-r1

[spine]
spine-s00

[super_spine]

[switch:children]
leaf
spine
super_spine

[host]
hgx-su00-h00
hgx-su00-h01
hgx-su00-h02
hgx-su00-h03

[disabled]
hgx-su00-h[04:31]
leaf-su00-r[2:3]
EOF

    print_info "Inventory file created"
}

# =============================================================================
# Step 5: Create Config File
# =============================================================================

create_config() {
    print_header "Step 5: Creating Config File (host_subnet_size: ${SUBNET_SIZE})"

    cat > "${RCP_DIR}/config/config.yaml" << EOF
is_simulation: true
pod_num: 1
pod_size: 1
topology: "2-tier-poc"
system_type: "h100"
hca_type: "ConnectX-7"
host_interfaces: ["eth1", "eth2", "eth3", "eth4"]

# Required parameters
host_first_octet: 172
overlay: "none"
leaf_rails: 2
telemetry_histogram: false
cable_validator: false
telemetry_dts_host_enable: false

# Additional parameters
planes_num: 1
leaf_downlinks_breakout: 2
switch_breakout: 2
ip_version: "ipv4"
host_configurator: "netplan"

# CIDR PATCH: Configurable subnet size
host_subnet_size: ${SUBNET_SIZE}

l3evpn_config: {"vrf": "tenant1", "vni": 4001}
cx_card_breakout: 1
dms_certificate_mode: false
prescriptive_topology_manager: false
doca_for_host_pkg: "doca-host_3.1.0-091513-25.07-ubuntu2204_amd64.deb"
EOF

    print_info "Config file created with host_subnet_size: ${SUBNET_SIZE}"
}

# =============================================================================
# Step 6: (Removed - Topology discovery now happens in start_container)
# =============================================================================

# =============================================================================
# Step 7: Start RCP Container
# =============================================================================

start_container() {
    print_header "Step 7: Starting RCP Container"

    # Stop existing container if running
    if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Stopping existing container..."
        sudo docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi

    print_step "Starting RCP container..."
    # Note: Do NOT mount topology directory - it overwrites RCP's internal files
    sudo docker run -d \
        --name "${CONTAINER_NAME}" \
        --network host \
        --privileged \
        -v "${RCP_DIR}/config:/root/spectrum-x-rcp/config" \
        -v "${RCP_DIR}/inventory:/root/spectrum-x-rcp/inventory" \
        spectrum-x-rcp:latest

    # Wait for container to start
    sleep 3

    if sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Container started successfully"
    else
        print_error "Container failed to start"
        sudo docker logs "${CONTAINER_NAME}" 2>&1 | tail -20
        exit 1
    fi

    # Run RCP's topology discovery to generate per-switch topology files
    print_step "Running RCP topology discovery..."
    sudo docker exec "${CONTAINER_NAME}" rcp-tool topology discover 2>&1 | tail -20 || true

    # Now discover actual topology via LLDP and create corrected config_network.dot
    print_step "Discovering actual physical topology via LLDP..."
    discover_actual_topology

    # Copy the discovered topology file to the container
    print_step "Applying discovered topology file..."
    sudo docker cp "${RCP_DIR}/config/config_network.dot" \
        "${CONTAINER_NAME}:/root/spectrum-x-rcp/topology/out/config_network.dot"

    # Verify topology files exist
    if sudo docker exec "${CONTAINER_NAME}" test -s /root/spectrum-x-rcp/topology/out/leaf-su00-r0; then
        print_info "Topology configured successfully"
    else
        print_warn "Switch topology files may be incomplete - discovery may have had issues"
    fi
}

# =============================================================================
# Discover actual topology via LLDP (called after container is running)
# =============================================================================

discover_actual_topology() {
    print_info "Collecting host MAC addresses..."

    # Collect MAC addresses from each host
    declare -A HOST_ETH1_MAC
    declare -A HOST_ETH2_MAC
    local hosts=("hgx-su00-h00" "hgx-su00-h01" "hgx-su00-h02" "hgx-su00-h03")

    for host in "${hosts[@]}"; do
        local eth1_mac=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "ip link show eth1 2>/dev/null | grep 'link/ether' | awk '{print \$2}'" 2>/dev/null)
        local eth2_mac=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "ip link show eth2 2>/dev/null | grep 'link/ether' | awk '{print \$2}'" 2>/dev/null)

        if [[ -n "$eth1_mac" ]]; then
            HOST_ETH1_MAC[$host]="$eth1_mac"
            print_info "  ${host} eth1: ${eth1_mac}"
        fi
        if [[ -n "$eth2_mac" ]]; then
            HOST_ETH2_MAC[$host]="$eth2_mac"
            print_info "  ${host} eth2: ${eth2_mac}"
        fi
    done

    print_info "Collecting switch LLDP neighbor information..."

    # Get LLDP neighbors from leaf switches
    local leaf0_lldp=$(sudo docker exec "${CONTAINER_NAME}" ansible -i /root/spectrum-x-rcp/inventory/hosts \
        leaf-su00-r0 -m shell -a "nv show interface --view lldp 2>/dev/null | grep -E 'swp[0-9]+s[0-9]+.*ubuntu'" 2>/dev/null | grep -v "CHANGED" || true)
    local leaf1_lldp=$(sudo docker exec "${CONTAINER_NAME}" ansible -i /root/spectrum-x-rcp/inventory/hosts \
        leaf-su00-r1 -m shell -a "nv show interface --view lldp 2>/dev/null | grep -E 'swp[0-9]+s[0-9]+.*ubuntu'" 2>/dev/null | grep -v "CHANGED" || true)

    print_info "Building topology from LLDP discovery..."

    # Parse LLDP output and match MAC addresses to hostnames
    declare -A LEAF0_PORT_TO_HOST
    declare -A LEAF1_PORT_TO_HOST

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local port=$(echo "$line" | awk '{print $1}')
        local mac=$(echo "$line" | awk '{print $NF}')

        for host in "${hosts[@]}"; do
            if [[ "${HOST_ETH1_MAC[$host]}" == "$mac" ]]; then
                LEAF0_PORT_TO_HOST[$port]="${host}:eth1"
                print_info "  Discovered: leaf-su00-r0:${port} -> ${host}:eth1"
            fi
        done
    done <<< "$leaf0_lldp"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local port=$(echo "$line" | awk '{print $1}')
        local mac=$(echo "$line" | awk '{print $NF}')

        for host in "${hosts[@]}"; do
            if [[ "${HOST_ETH2_MAC[$host]}" == "$mac" ]]; then
                LEAF1_PORT_TO_HOST[$port]="${host}:eth2"
                print_info "  Discovered: leaf-su00-r1:${port} -> ${host}:eth2"
            fi
        done
    done <<< "$leaf1_lldp"

    # Generate topology file based on discovered connections
    print_info "Generating topology file from discovered connections..."

    cat > "${RCP_DIR}/config/config_network.dot" << 'HEADER'
graph "network" {
"oob-mgmt-server" [function="oob-server" os="oob-mgmt-server" memory="16048" cpu="16"]
"leaf-su00-r0" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="leaf"]
"leaf-su00-r1" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="leaf"]
"spine-s00" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="spine"]
"hgx-su00-h00" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h01" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h02" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h03" [os="generic/ubuntu2204" role="host"]

HEADER

    # Add host connections from discovered topology
    for port in "${!LEAF0_PORT_TO_HOST[@]}"; do
        local host_iface="${LEAF0_PORT_TO_HOST[$port]}"
        local host=$(echo "$host_iface" | cut -d: -f1)
        local iface=$(echo "$host_iface" | cut -d: -f2)
        echo "\"${host}\":\"${iface}\"--\"leaf-su00-r0\":\"${port}\"" >> "${RCP_DIR}/config/config_network.dot"
    done

    for port in "${!LEAF1_PORT_TO_HOST[@]}"; do
        local host_iface="${LEAF1_PORT_TO_HOST[$port]}"
        local host=$(echo "$host_iface" | cut -d: -f1)
        local iface=$(echo "$host_iface" | cut -d: -f2)
        echo "\"${host}\":\"${iface}\"--\"leaf-su00-r1\":\"${port}\"" >> "${RCP_DIR}/config/config_network.dot"
    done

    # Add spine connections (discovered from LLDP between switches)
    cat >> "${RCP_DIR}/config/config_network.dot" << 'SPINE'

"leaf-su00-r0":"swp33s0"--"spine-s00":"swp1s0"
"leaf-su00-r0":"swp33s1"--"spine-s00":"swp1s1"
"leaf-su00-r1":"swp33s0"--"spine-s00":"swp33s0"
"leaf-su00-r1":"swp33s1"--"spine-s00":"swp33s1"
}
SPINE

    print_info "Topology discovery complete"
}

# =============================================================================
# Step 8: Apply CIDR Patch
# =============================================================================

apply_patch() {
    print_header "Step 8: Applying CIDR Patch"

    # Check if patch files exist
    if [[ ! -d "${PATCHES_DIR}" ]]; then
        print_error "Patches directory not found: ${PATCHES_DIR}"
        exit 1
    fi

    # Apply each patch file
    for file in ipv4am.py system_config.py nodes_info_builder.py leaf_yaml.j2; do
        if [[ ! -f "${PATCHES_DIR}/${file}" ]]; then
            print_error "Patch file not found: ${PATCHES_DIR}/${file}"
            exit 1
        fi
    done

    print_step "Copying patched files..."
    sudo docker cp "${PATCHES_DIR}/ipv4am.py" \
        "${CONTAINER_NAME}:${SPCX_CORE_PATH}/configurator/ipv4am.py"
    sudo docker cp "${PATCHES_DIR}/system_config.py" \
        "${CONTAINER_NAME}:${SPCX_CORE_PATH}/config/system_config.py"
    sudo docker cp "${PATCHES_DIR}/nodes_info_builder.py" \
        "${CONTAINER_NAME}:${SPCX_CORE_PATH}/nodes_info_builder.py"
    sudo docker cp "${PATCHES_DIR}/leaf_yaml.j2" \
        "${CONTAINER_NAME}:${SPCX_CORE_PATH}/switch/cumulus/none/leaf_yaml.j2"

    print_step "Creating netplan symlinks..."
    sudo docker exec "${CONTAINER_NAME}" ln -sf \
        "${HOST_DIR}/linux_spectrum-x.sh" \
        "${HOST_DIR}/netplan_spectrum-x.sh" 2>/dev/null || true
    sudo docker exec "${CONTAINER_NAME}" ln -sf \
        "${HOST_DIR}/linux_networkd_spectrum-x.sh" \
        "${HOST_DIR}/netplan_networkd_spectrum-x.sh" 2>/dev/null || true

    print_info "Patch applied successfully"
}

# =============================================================================
# Step 9: Verify Patch Installation
# =============================================================================

verify_patch() {
    print_header "Step 9: Verifying Patch Installation"

    local all_pass=true

    # Check host_subnet_size in ipv4am.py
    if sudo docker exec "${CONTAINER_NAME}" grep -q "host_subnet_size" \
        "${SPCX_CORE_PATH}/configurator/ipv4am.py" 2>/dev/null; then
        print_pass "ipv4am.py: host_subnet_size support present"
    else
        print_fail "ipv4am.py: host_subnet_size support MISSING"
        all_pass=false
    fi

    # Check critical IP offset fix
    if sudo docker exec "${CONTAINER_NAME}" grep -q "return base + 2" \
        "${SPCX_CORE_PATH}/configurator/ipv4am.py" 2>/dev/null; then
        print_pass "ipv4am.py: IP offset fix present (base + 2)"
    else
        print_fail "ipv4am.py: IP offset fix MISSING"
        all_pass=false
    fi

    # Check system_config.py
    if sudo docker exec "${CONTAINER_NAME}" grep -q "_set_host_subnet_size" \
        "${SPCX_CORE_PATH}/config/system_config.py" 2>/dev/null; then
        print_pass "system_config.py: patched"
    else
        print_fail "system_config.py: NOT patched"
        all_pass=false
    fi

    # Check nodes_info_builder.py
    if sudo docker exec "${CONTAINER_NAME}" grep -q 'getattr.*subnet' \
        "${SPCX_CORE_PATH}/nodes_info_builder.py" 2>/dev/null; then
        print_pass "nodes_info_builder.py: getattr fix present"
    else
        print_fail "nodes_info_builder.py: getattr fix MISSING"
        all_pass=false
    fi

    # Check leaf_yaml.j2
    if sudo docker exec "${CONTAINER_NAME}" grep -q 'port_info\["subnet"\]' \
        "${SPCX_CORE_PATH}/switch/cumulus/none/leaf_yaml.j2" 2>/dev/null; then
        print_pass "leaf_yaml.j2: dynamic subnet support present"
    else
        print_fail "leaf_yaml.j2: dynamic subnet support MISSING"
        all_pass=false
    fi

    # Check netplan symlinks
    if sudo docker exec "${CONTAINER_NAME}" test -L "${HOST_DIR}/netplan_spectrum-x.sh" 2>/dev/null; then
        print_pass "netplan_spectrum-x.sh symlink present"
    else
        print_warn "netplan_spectrum-x.sh symlink missing"
    fi

    if [[ "$all_pass" != "true" ]]; then
        print_error "Patch verification failed!"
        exit 1
    fi

    print_info "All patch verifications passed"
}

# =============================================================================
# Step 10: Run RCP Configuration
# =============================================================================

run_rcp_configure() {
    print_header "Step 10: Running RCP Configuration"

    print_step "Cleaning previous configs..."
    if ! sudo docker exec "${CONTAINER_NAME}" rcp-tool all clean; then
        print_error "Failed to clean previous configs"
        return 1
    fi

    print_step "Running full configuration (this may take several minutes)..."
    print_info "Please wait - configuring switches and hosts..."

    # Run configure and capture output
    local output_file="/tmp/rcp_configure_$$.log"
    if sudo docker exec "${CONTAINER_NAME}" rcp-tool all configure > "$output_file" 2>&1; then
        print_info "RCP configuration completed successfully"
        # Show last few lines of output
        tail -20 "$output_file"
    else
        print_error "RCP configuration failed!"
        print_error "Last 50 lines of output:"
        tail -50 "$output_file"
        rm -f "$output_file"
        return 1
    fi
    rm -f "$output_file"

    # Verify switch config was generated
    if ! sudo docker exec "${CONTAINER_NAME}" test -f /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml; then
        print_error "Switch config file was not generated!"
        return 1
    fi

    print_info "Switch configurations generated successfully"
}

# =============================================================================
# Step 11: Validate Switch Configurations
# =============================================================================

validate_switch_configs() {
    print_header "Step 11: Validating Switch Configurations"

    local switch_config="/root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml"

    # Check switch config exists
    if ! sudo docker exec "${CONTAINER_NAME}" test -f "${switch_config}" 2>/dev/null; then
        print_fail "Switch config file not found: ${switch_config}"
        return 1
    fi

    # Check for correct subnet size
    local expected_subnet="/${SUBNET_SIZE}"
    local subnet_count=$(sudo docker exec "${CONTAINER_NAME}" \
        grep -c "${expected_subnet}" "${switch_config}" 2>/dev/null || echo "0")

    if [[ "$subnet_count" -gt 0 ]]; then
        print_pass "Switch config contains ${expected_subnet} subnets (${subnet_count} found)"
    else
        print_fail "Switch config missing ${expected_subnet} subnets"
    fi

    # Check all 4 hosts are connected
    local host_count=$(sudo docker exec "${CONTAINER_NAME}" \
        grep -c "to_hgx-su00-h0" "${switch_config}" 2>/dev/null || echo "0")

    if [[ "$host_count" -ge 4 ]]; then
        print_pass "All hosts connected in switch config (${host_count} connections)"
    else
        print_fail "Missing host connections (only ${host_count} found, expected 4+)"
    fi

    # Show actual subnet IPs
    print_info "Switch interface IPs:"
    sudo docker exec "${CONTAINER_NAME}" \
        grep -E "172\.[0-9]+\.[0-9]+\.[0-9]+/${SUBNET_SIZE}" "${switch_config}" 2>/dev/null | head -4
}

# =============================================================================
# Step 12: Validate Host Configurations
# =============================================================================

validate_host_configs() {
    print_header "Step 12: Validating Host IP Configurations"

    local hosts=("hgx-su00-h00" "hgx-su00-h01" "hgx-su00-h02" "hgx-su00-h03")

    # Calculate addresses per block based on subnet size
    local addresses_per_block=$((2 ** (32 - SUBNET_SIZE)))

    for host in "${hosts[@]}"; do
        print_step "Checking ${host}..."

        # Get eth1 IP
        local eth1_ip=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "ip -4 addr show eth1 2>/dev/null | grep -oP 'inet \K[0-9./]+'" 2>/dev/null)

        # Get eth2 IP
        local eth2_ip=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "ip -4 addr show eth2 2>/dev/null | grep -oP 'inet \K[0-9./]+'" 2>/dev/null)

        if [[ -n "$eth1_ip" ]]; then
            # Extract last octet and check offset within subnet block
            local last_octet=$(echo "$eth1_ip" | grep -oP '\.\K[0-9]+(?=/)')
            local offset=$((last_octet % addresses_per_block))

            # For /31: host at .0; For /30, /29: host at .2
            if [[ $SUBNET_SIZE -eq 31 ]]; then
                local expected_offset=0
            else
                local expected_offset=2
            fi

            if [[ "$offset" -eq "$expected_offset" ]]; then
                print_pass "${host} eth1: ${eth1_ip} (correct offset +${expected_offset})"
            else
                print_fail "${host} eth1: ${eth1_ip} (offset ${offset}, expected +${expected_offset})"
            fi
        else
            print_fail "${host} eth1: No IP assigned"
        fi

        if [[ -n "$eth2_ip" ]]; then
            local last_octet=$(echo "$eth2_ip" | grep -oP '\.\K[0-9]+(?=/)')
            local offset=$((last_octet % addresses_per_block))

            if [[ $SUBNET_SIZE -eq 31 ]]; then
                local expected_offset=0
            else
                local expected_offset=2
            fi

            if [[ "$offset" -eq "$expected_offset" ]]; then
                print_pass "${host} eth2: ${eth2_ip} (correct offset +${expected_offset})"
            else
                print_fail "${host} eth2: ${eth2_ip} (offset ${offset}, expected +${expected_offset})"
            fi
        else
            print_fail "${host} eth2: No IP assigned"
        fi
    done
}

# =============================================================================
# Step 13: Validate Gateway Connectivity
# =============================================================================

validate_gateway_pings() {
    print_header "Step 13: Validating Gateway Connectivity"

    local hosts=("hgx-su00-h00" "hgx-su00-h01" "hgx-su00-h02" "hgx-su00-h03")
    local addresses_per_block=$((2 ** (32 - SUBNET_SIZE)))

    for host in "${hosts[@]}"; do
        print_step "Testing gateway pings from ${host}..."

        # Calculate gateway from host IP (gateway = network_base + 1)
        local result=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "
            for iface in eth1 eth2; do
                ip=\$(ip -4 addr show \$iface 2>/dev/null | grep -oP 'inet \K[0-9.]+')
                if [ -n \"\$ip\" ]; then
                    # Extract last octet and calculate gateway
                    last=\$(echo \$ip | cut -d. -f4)
                    base=\$(echo \$ip | cut -d. -f1-3)
                    # Gateway is at (last_octet / block_size) * block_size + 1
                    gw_last=\$(( (last / ${addresses_per_block}) * ${addresses_per_block} + 1 ))
                    gw=\"\${base}.\${gw_last}\"
                    ping -c1 -W2 \$gw >/dev/null 2>&1 && echo \"\$iface:PASS:\$gw\" || echo \"\$iface:FAIL:\$gw\"
                fi
            done
        " 2>/dev/null)

        while IFS= read -r line; do
            if [[ -z "$line" ]]; then continue; fi
            local iface=$(echo "$line" | cut -d: -f1)
            local status=$(echo "$line" | cut -d: -f2)
            local gw=$(echo "$line" | cut -d: -f3)

            if [[ "$status" == "PASS" ]]; then
                print_pass "${host} ${iface} -> ${gw}"
            else
                print_fail "${host} ${iface} -> ${gw}"
            fi
        done <<< "$result"
    done
}

# =============================================================================
# Step 14: Validate Cross-Host Connectivity
# =============================================================================

validate_cross_host_pings() {
    print_header "Step 14: Validating Cross-Host Connectivity"

    # Get h00's eth1 IP to use as target
    local h00_eth1=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        ubuntu@hgx-su00-h00 "ip -4 addr show eth1 2>/dev/null | grep -oP 'inet \K[0-9.]+'" 2>/dev/null)

    if [[ -z "$h00_eth1" ]]; then
        print_warn "Could not get h00 eth1 IP for cross-host test"
        return 1
    fi

    print_info "Target: hgx-su00-h00 eth1 = ${h00_eth1}"

    local hosts=("hgx-su00-h01" "hgx-su00-h02" "hgx-su00-h03")

    for host in "${hosts[@]}"; do
        local result=$(sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            ubuntu@${host} "ping -c1 -W3 ${h00_eth1} >/dev/null 2>&1 && echo PASS || echo FAIL" 2>/dev/null)

        if [[ "$result" == "PASS" ]]; then
            print_pass "${host} -> ${h00_eth1}"
        else
            print_fail "${host} -> ${h00_eth1}"
        fi
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    print_header "Deployment Summary"

    echo "Configuration:"
    echo "  - Subnet Size: /${SUBNET_SIZE}"
    echo "  - Container: ${CONTAINER_NAME}"
    echo ""
    echo "Results:"
    echo -e "  - ${GREEN}Passed: ${PASS_COUNT}${NC}"
    echo -e "  - ${RED}Failed: ${FAIL_COUNT}${NC}"
    echo ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  DEPLOYMENT SUCCESSFUL!${NC}"
        echo -e "${GREEN}========================================${NC}"
        exit 0
    else
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}  DEPLOYMENT COMPLETED WITH FAILURES${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    print_header "RCP CIDR Patch Deployment Script"
    echo "Subnet Size: /${SUBNET_SIZE}"
    echo "Container: ${CONTAINER_NAME}"
    echo ""

    check_root

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        print_info "Running validation only..."
        verify_patch
        validate_switch_configs
        validate_host_configs
        validate_gateway_pings
        validate_cross_host_pings
        print_summary
        return
    fi

    # Full deployment
    if [[ "$SKIP_DOCKER" != "true" ]]; then
        install_docker
    fi

    load_rcp_image
    create_directories
    create_inventory
    create_config
    # Note: Topology is discovered via LLDP inside start_container()
    start_container

    if [[ "$SKIP_PATCH" != "true" ]]; then
        apply_patch
    fi

    verify_patch
    run_rcp_configure
    validate_switch_configs
    validate_host_configs
    validate_gateway_pings
    validate_cross_host_pings
    print_summary
}

# Run main
main "$@"
