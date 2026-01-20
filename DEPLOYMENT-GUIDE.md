# Spectrum-X RCP Deployment with Configurable CIDR Patch

This guide documents the complete process of deploying NVIDIA Spectrum-X RCP with the configurable CIDR/subnet size patch on NVIDIA AIR.

## Overview

The NVIDIA RCP tool originally generates `/31` subnets for host IP allocation, providing only **1 usable IP per NIC per node**. This patch enables configurable subnet sizes (`/29`, `/30`, `/31`) to support multi-pod-per-node Kubernetes deployments.

### Use Cases

| Subnet | IPs/Block | Usable | Use Case |
|--------|-----------|--------|----------|
| `/31` | 2 | 1 host | Original design |
| `/30` | 4 | 3 (1 host + 2 pods) | 2 GPUs, 1 pod/GPU |
| `/29` | 8 | 7 (1 host + 6 pods) | 4+ GPUs, 1 pod/GPU |

## Quick Start (Automated)

For automated deployment on an NVIDIA AIR simulation, use the deployment script:

```bash
# Copy patch files to oob-mgmt-server
scp -r rcp-cidr-patch ubuntu@oob-mgmt-server:~/

# SSH to server and run
ssh ubuntu@oob-mgmt-server
cd ~/rcp-cidr-patch
./deploy-and-validate.sh -s 30   # Use /30 subnets
```

Options:
- `-s 29|30|31` - Subnet size (default: 30)
- `--validate-only` - Only run validation tests
- `--skip-docker` - Skip Docker installation

## Prerequisites

- NVIDIA AIR account with API token
- `gust` CLI tool configured with credentials
- SSH key management via GitHub
- RCP tar file: `spectrum-x-rcp-V2.0.0-GA.tar`

## Step 1: Delete Existing Simulation (if any)

```bash
# List all simulations
gust --list

# Delete simulation by ID
gust --delete <SIMULATION_ID>
```

**Example:**
```bash
gust --delete 6d82a5a2-168a-4941-ae91-3d8be838881b
```

**Output:**
```
[INFO] Deleting simulation: marty-1768497661-my-test (6d82a5a2-168a-4941-ae91-3d8be838881b)
[INFO] Successfully deleted simulation: 6d82a5a2-168a-4941-ae91-3d8be838881b
[INFO] Deleted GitHub SSH key: marty-1768497661-my-test
[INFO] Deleted local SSH key: /home/blik/.ssh/marty-1768497661-my-test
```

## Step 2: Create New Simulation

```bash
gust -l "cidr-test"
```

**Output:**
```
[INFO] Using default Spectrum-X topology
[INFO] Simulation name: marty-1768500127-cidr-test
[INFO] Created simulation: marty-1768500127-cidr-test (2e369f08-a99f-4b77-84ef-f7168f54ad56)

==================================================
Simulation Created!
==================================================

Simulation: marty-1768500127-cidr-test
Simulation ID: 2e369f08-a99f-4b77-84ef-f7168f54ad56

Next steps:
  gust --start 2e369f08-a99f-4b77-84ef-f7168f54ad56
  gust --connect 2e369f08-a99f-4b77-84ef-f7168f54ad56
```

## Step 3: Start Simulation

```bash
gust --start <SIMULATION_ID>
```

**Example:**
```bash
gust --start 2e369f08-a99f-4b77-84ef-f7168f54ad56
```

**Output:**
```
[INFO] Starting simulation: 2e369f08-a99f-4b77-84ef-f7168f54ad56
[INFO] Simulation state: LOADING (waited 0s)
[INFO] Simulation state: LOADING (waited 10s)
[INFO] Simulation state: LOADING (waited 20s)
[INFO] Simulation state: LOADED (waited 30s)
[INFO] Simulation is ready! State: LOADED
```

## Step 4: Connect and Copy Patch Files

```bash
# Copy patch files and connect
gust --connect <SIMULATION_ID> --copy /path/to/rcp-cidr-patch
```

**Example:**
```bash
gust --connect 2e369f08-a99f-4b77-84ef-f7168f54ad56 --copy ~/rcp-cidr-patch
```

## Step 5: Download RCP Tar on OOB Server

Get SSH connection details from gust output, then:

```bash
# Download RCP tar
wget https://kevin-s3-public.s3.eu-west-3.amazonaws.com/rcp/spectrum-x-rcp-V2.0.0-GA.tar
```

## Step 6: Install Docker CE

```bash
# Install prerequisites
sudo apt update && sudo apt install -y ca-certificates curl

# Add Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: jammy
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc" | sudo tee /etc/apt/sources.list.d/docker.sources

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## Step 7: Set Up RCP

```bash
# Create directories
mkdir -p ~/spectrum-x-rcp/topology/out ~/spectrum-x-rcp/var/log ~/spectrum-x-rcp/inventory ~/spectrum-x-rcp/config

# Load Docker image
sudo docker image load < ~/spectrum-x-rcp-V2.0.0-GA.tar
```

## Step 8: Create Configuration Files

### config.yaml (with /29 subnet)

```bash
cat > ~/spectrum-x-rcp/config/config.yaml << 'EOF'
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

# CIDR PATCH: Using /29 for 8 addresses per block (6 extra for pods)
host_subnet_size: 29
EOF
```

### inventory/hosts

**IMPORTANT:** The `[switch:children]` section is required for Ansible to properly group switches.

```bash
cat > ~/spectrum-x-rcp/inventory/hosts << 'EOF'
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
```

## Step 9: Start RCP Container

```bash
sudo docker run -itd --network host \
  -v ~/spectrum-x-rcp/config:/root/spectrum-x-rcp/config \
  -v ~/spectrum-x-rcp/inventory:/root/spectrum-x-rcp/inventory:rw \
  -v ~/spectrum-x-rcp/topology/out:/root/spectrum-x-rcp/topology/out:rw \
  -v ~/spectrum-x-rcp/var/log:/var/log:rw \
  -v /etc/hosts:/etc/hosts:ro \
  -v /etc/resolv.conf:/etc/resolv.conf:ro \
  --name spectrum-x-rcp \
  gitlab-master.nvidia.com:5005/cloud-orchestration/spectrum-x-rcp:V2.0.0-GA.1
```

## Step 10: Apply CIDR Patch

**IMPORTANT:** All 4 patch files must be applied, plus symlinks for missing scripts.

### 10.1 Copy Patch Files

```bash
# Copy ALL 4 patched files into container
sudo docker cp ~/rcp-cidr-patch/patches/ipv4am.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py

sudo docker cp ~/rcp-cidr-patch/patches/system_config.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py

sudo docker cp ~/rcp-cidr-patch/patches/nodes_info_builder.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py

sudo docker cp ~/rcp-cidr-patch/patches/leaf_yaml.j2 \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2
```

### 10.2 Netplan Script Symlinks (Automatic)

**Note:** The `apply-cidr-patch.sh` script now automatically creates the required netplan symlinks. If you applied the patch using the script, you can skip to Step 10.3.

**Manual creation (if needed):** RCP V2.0.0-GA is missing netplan scripts. Create symlinks:

```bash
HOST_DIR="/usr/local/lib/python3.12/dist-packages/spcx_core/host"

sudo docker exec spectrum-x-rcp ln -sf \
  ${HOST_DIR}/linux_spectrum-x.sh \
  ${HOST_DIR}/netplan_spectrum-x.sh

sudo docker exec spectrum-x-rcp ln -sf \
  ${HOST_DIR}/linux_networkd_spectrum-x.sh \
  ${HOST_DIR}/netplan_networkd_spectrum-x.sh
```

### 10.3 Clean Cached Configs

```bash
# CRITICAL: Clean any cached configs from previous runs
sudo docker exec spectrum-x-rcp rcp-tool all clean
```

### 10.4 Verify Patch Installation

```bash
# Verify ipv4am.py (should output: 4)
sudo docker exec spectrum-x-rcp grep -c '_get_subnet_config' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py

# Verify IP offset fix (CRITICAL - must show "return base + 2")
sudo docker exec spectrum-x-rcp grep "return base + 2" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py

# Verify nodes_info_builder.py getattr fix
sudo docker exec spectrum-x-rcp grep 'getattr.*subnet' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py

# Verify leaf_yaml.j2 dynamic subnet
sudo docker exec spectrum-x-rcp grep 'port_info\["subnet"\]' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2
```

**Or use the install script (recommended):**
```bash
cd ~/rcp-cidr-patch
sudo ./apply-cidr-patch.sh
```

## Step 11: Discover Topology and Create Custom Topology File

**CRITICAL FOR NVIDIA AIR:** The AIR simulation has a specific physical topology that may differ from RCP's recommended topology. You must create a topology file that matches the actual wiring.

### Port Format Requirements

**IMPORTANT:** Port names must use breakout notation matching your `leaf_downlinks_breakout` config:
- If `leaf_downlinks_breakout: 2`, use `swp1s0`, `swp1s1` (not `swp1`)
- If `leaf_downlinks_breakout: 1`, use `swp1` (no suffix)

### Run Topology Discovery (Optional)

```bash
sudo docker exec spectrum-x-rcp rcp-tool topology discover
```

**NOTE:** LLDP discovery in AIR often shows hosts as "ubuntu" instead of hostnames. You may need to map MAC addresses to hostnames manually.

### Create Custom Topology File

Create a topology file that matches the actual AIR wiring:

```bash
cat > ~/spectrum-x-rcp/config/config_network.dot << 'EOF'
graph "network" {
"oob-mgmt-server" [function="oob-server" os="oob-mgmt-server" memory="16048" cpu="16"]
"leaf-su00-r0" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="leaf"]
"leaf-su00-r1" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="leaf"]
"spine-s00" [os="cumulus-vx-5.13.0.0023" cpu="2" memory="4096" model="SN5600" role="spine"]
"hgx-su00-h00" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h01" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h02" [os="generic/ubuntu2204" role="host"]
"hgx-su00-h03" [os="generic/ubuntu2204" role="host"]

"hgx-su00-h00":"eth1"--"leaf-su00-r0":"swp1s0"
"hgx-su00-h01":"eth1"--"leaf-su00-r0":"swp2s0"
"hgx-su00-h02":"eth1"--"leaf-su00-r0":"swp3s0"
"hgx-su00-h03":"eth1"--"leaf-su00-r0":"swp4s0"

"hgx-su00-h00":"eth2"--"leaf-su00-r1":"swp1s0"
"hgx-su00-h01":"eth2"--"leaf-su00-r1":"swp2s0"
"hgx-su00-h02":"eth2"--"leaf-su00-r1":"swp3s0"
"hgx-su00-h03":"eth2"--"leaf-su00-r1":"swp4s0"

"leaf-su00-r0":"swp5s0"--"spine-s00":"swp1s0"
"leaf-su00-r1":"swp5s0"--"spine-s00":"swp2s0"
}
EOF
```

**Also copy to topology/out directory:**
```bash
sudo docker exec spectrum-x-rcp cp /root/spectrum-x-rcp/config/config_network.dot \
  /root/spectrum-x-rcp/topology/out/config_network.dot
```

### Rail Assignment Logic

**CRITICAL:** Preserve correct rail assignment with `leaf_rails: 2`:
- **leaf-su00-r0** handles rail 0 (eth1, eth3 from ALL hosts)
- **leaf-su00-r1** handles rail 1 (eth2, eth4 from ALL hosts)

Each leaf must connect to **ALL 4 hosts**, not a subset. Incorrect assignment breaks connectivity.

Verify rail assignment:
```bash
# Should show connections to all 4 hosts (h00-h03)
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml | \
  grep -E "to_hgx-su00-h0[0-3]" | sort -u
```

## Step 12: Generate and Apply Configurations

### Run Full Configuration

```bash
# Generate and apply all configs (switches and hosts)
sudo docker exec spectrum-x-rcp rcp-tool all configure
```

This will:
1. Generate switch YAML configs
2. Apply configs to switches (leafs will reboot)
3. Generate host netplan configs
4. Apply netplan to hosts

**Note:** You may see `networkd-dispatcher timeout` errors on hosts in simulation - this is expected without real NVIDIA hardware and does not affect network functionality.

### Verify Switch Configs

```bash
# Check switch configs have correct subnet (should show /29, not /31)
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml | grep -E "172\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"
```

**Expected:** Shows `/29` for host-facing ports, `/31` for spine-facing ports.

### Verify Host IPs

```bash
# Check hosts got correct IPs
for host in hgx-su00-h00 hgx-su00-h01 hgx-su00-h02 hgx-su00-h03; do
    echo "=== $host ==="
    sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@$host \
        "ip -4 addr show eth1 | grep inet; ip -4 addr show eth2 | grep inet" 2>/dev/null
done
```

**Expected IP Layout (/29):**
| Host | eth1 | eth2 |
|------|------|------|
| h00 | 172.16.0.2/29 | 172.18.0.2/29 |
| h01 | 172.16.0.10/29 | 172.18.0.10/29 |
| h02 | 172.16.0.18/29 | 172.18.0.18/29 |
| h03 | 172.16.0.26/29 | 172.18.0.26/29 |

**Key:** Host IPs are at `.2` position (not `.0` network address)

## Step 13: Validate Configuration

### Gateway Ping Test

Test that all hosts can ping their switch gateways:

```bash
for host in hgx-su00-h00 hgx-su00-h01 hgx-su00-h02 hgx-su00-h03; do
    echo "--- $host ---"
    sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@$host '
        for eth in eth1 eth2; do
            ip=$(ip -4 addr show $eth 2>/dev/null | grep -oP "(?<=inet )\d+\.\d+\.\d+\.\d+")
            # Gateway is always at .1 in the subnet
            gw=$(echo $ip | sed "s/\.[0-9]*$/.1/")
            if [ -n "$ip" ]; then
                ping -c 1 -W 2 $gw -I $eth >/dev/null 2>&1 && echo "$eth: $ip -> $gw OK" || echo "$eth: $ip -> $gw FAIL"
            fi
        done
    ' 2>/dev/null
done
```

**Expected output (all 8 tests pass):**
```
--- hgx-su00-h00 ---
eth1: 172.16.0.2 -> 172.16.0.1 OK
eth2: 172.18.0.2 -> 172.18.0.1 OK
--- hgx-su00-h01 ---
eth1: 172.16.0.10 -> 172.16.0.9 OK
eth2: 172.18.0.10 -> 172.18.0.9 OK
...
```

### Cross-Host Ping Test

Test connectivity between hosts through the spine:

```bash
echo "h00 -> h01, h02, h03"
sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@hgx-su00-h00 '
    for target in 172.16.0.10 172.16.0.18 172.16.0.26; do
        ping -c 1 -W 2 $target -I eth1 >/dev/null 2>&1 && echo "-> $target OK" || echo "-> $target FAIL"
    done
' 2>/dev/null
```

**Expected:** All cross-host pings succeed (TTL=63 indicates routing through spine).

## IP Allocation Summary

| Subnet Size | Addresses/Block | Network | Switch/GW | Host | Broadcast | Extra for Pods |
|-------------|-----------------|---------|-----------|------|-----------|----------------|
| `/31` (default) | 2 | N/A | .1 | .0 | N/A | 0 |
| `/30` | 4 | .0 | .1 | .2 | .3 | 0 |
| `/29` | 8 | .0 | .1 | .2 | .7 | 5 (.3-.6) |

### /29 IP Layout (per host, per rail)

```
Host 0, Rail 0: 172.16.0.0/29
  ├── 172.16.0.0 - Network address (unusable)
  ├── 172.16.0.1 - Switch/Gateway IP
  ├── 172.16.0.2 - Host IP
  ├── 172.16.0.3 - Pod IP 1
  ├── 172.16.0.4 - Pod IP 2
  ├── 172.16.0.5 - Pod IP 3
  ├── 172.16.0.6 - Pod IP 4
  └── 172.16.0.7 - Broadcast (unusable)

Host 1, Rail 0: 172.16.0.8/29
  ├── 172.16.0.8  - Network address (unusable)
  ├── 172.16.0.9  - Switch/Gateway IP
  ├── 172.16.0.10 - Host IP
  └── 172.16.0.11-14 - Pod IPs (4 available)

Host 2, Rail 0: 172.16.0.16/29
  ├── 172.16.0.16 - Network address (unusable)
  ├── 172.16.0.17 - Switch/Gateway IP
  ├── 172.16.0.18 - Host IP
  └── 172.16.0.19-22 - Pod IPs (4 available)

Host 3, Rail 0: 172.16.0.24/29
  ├── 172.16.0.24 - Network address (unusable)
  ├── 172.16.0.25 - Switch/Gateway IP
  ├── 172.16.0.26 - Host IP
  └── 172.16.0.27-30 - Pod IPs (4 available)
```

## Files Modified by Patch

| File | Location | Changes |
|------|----------|---------|
| `ipv4am.py` | `spcx_core/configurator/` | Added `_get_subnet_config()`, `_calculate_host_fourth_octet()` with correct offset for /29 and /30, fixed `set_leaf_ip()` to calculate switch IP correctly |
| `system_config.py` | `spcx_core/config/` | Added `host_subnet_size` validation and defaults |
| `nodes_info_builder.py` | `spcx_core/` | Added `getattr()` for subnet field to handle missing attribute gracefully |
| `leaf_yaml.j2` | `spcx_core/switch/cumulus/none/` | Uses dynamic subnet for host-facing ports (spine ports remain /31) |

**All 4 files are required.** Missing any file will result in incorrect configs or errors.

## Troubleshooting

### Connection Refused
Wait 30-60 seconds after starting simulation for SSH to become available.

### Hosts Not In Inventory
Ensure the `[host]` section in `inventory/hosts` includes all hosts and the `[switch:children]` section exists.

### Switch Configure Skipping Hosts
Ensure `[switch:children]` is defined in inventory file:
```ini
[switch:children]
leaf
spine
super_spine
```

### Gateway Pings Failing
1. Verify the custom topology file matches actual physical connections
2. Check switch configs were applied: `nv config show` on switch
3. Verify host netplan was applied: `ip addr show eth1` on host

### Host IP Shows .0 Instead of .2
The patch file `ipv4am.py` is incorrect or not applied. Verify:
```bash
sudo docker exec spectrum-x-rcp grep -A5 "_calculate_host_fourth_octet" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```
Should show `return base + 2` for the non-/31 case.

### LLDP Shows "ubuntu" Instead of Hostnames
This is expected in AIR. Map MAC addresses to hostnames manually to create the custom topology file.

## Quick Reference Commands

```bash
# List simulations
gust --list

# Create simulation
gust -l "my-simulation"

# Start simulation
gust --start <SIM_ID>

# Connect to simulation
gust --connect <SIM_ID>

# Connect and copy files
gust --connect <SIM_ID> --copy /path/to/files

# Stop simulation
gust --stop <SIM_ID>

# Delete simulation
gust --delete <SIM_ID>
```

## Related Files

- `rcp-cidr-patch/README.md` - Detailed patch documentation
- `rcp-cidr-patch/VALIDATION.md` - Test procedures and validation guide
- `rcp-cidr-patch/patches/ipv4am.py` - Modified IP allocator
- `rcp-cidr-patch/patches/system_config.py` - Modified config validator
- `rcp-cidr-patch/patches/nodes_info_builder.py` - Modified nodes info builder
- `rcp-cidr-patch/patches/leaf_yaml.j2` - Modified leaf switch template
- `rcp-cidr-patch/sample-config.yaml` - Sample configuration
- `rcp-cidr-patch/apply-cidr-patch.sh` - Patch installation script
- `rcp-cidr-patch/deploy-and-validate.sh` - Full automated deployment script

## Changelog

### v2.1.0 (2026-01-20)
- **NEW**: `deploy-and-validate.sh` - Full end-to-end automated deployment script
- **FIXED**: Switch config output path corrected (`/switch/out/` not `/output/switch/`)
- **UPDATED**: Quick Start section added with automated deployment instructions

### v2.0.0 (2026-01-20)
- **CRITICAL FIX**: Fixed `ipv4am.py` host IP offset calculation
  - Host IPs now correctly at `.2` (not `.0` network address) for /29 and /30
  - Switch IPs at `.1` for all subnet sizes
- **NEW**: `apply-cidr-patch.sh` now automatically creates netplan symlinks
- **NEW**: Port format requirements documented (swp1s0 breakout notation)
- **UPDATED**: Step 10.2 - Netplan symlinks now automatic with manual fallback
- **UPDATED**: Step 11 - Simplified topology file creation
- **UPDATED**: Step 12 - Simplified to `rcp-tool all configure`
- **UPDATED**: Step 13 - Working validation tests from actual deployment
- **UPDATED**: Rail assignment verification added
- **FIXED**: All 4 patch files documented with verification steps
- **TESTED**: Full end-to-end deployment validated on AIR simulation

### v1.2.0 (2026-01-19)
- Added custom topology file requirement for NVIDIA AIR
- Added MAC address mapping instructions
- Updated IP Allocation Summary

### v1.1.0 (2026-01-16)
- Changed `hca_type` to `ConnectX-7`
- Added CIDRPool generation workflow
- Added `generate_rail_cidrpools.sh`

### v1.0.0 (2026-01-15)
- Initial deployment guide
