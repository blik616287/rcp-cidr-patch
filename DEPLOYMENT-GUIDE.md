# Spectrum-X RCP Deployment with Configurable CIDR Patch

This guide documents the complete process of deploying NVIDIA Spectrum-X RCP with the configurable CIDR/subnet size patch on NVIDIA AIR.

## Overview

This deployment enables configurable subnet sizes (`/29`, `/30`, `/31`) for host IP allocation, allowing multiple IP addresses per host for Kubernetes pod networking.

## Prerequisites

- NVIDIA AIR account with API token
- `gust` CLI tool configured with credentials
- SSH key management via GitHub

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

[host]
hgx-su00-h00
hgx-su00-h01
hgx-su00-h02
hgx-su00-h03

[switch:children]
super_spine
spine
leaf

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

```bash
# Copy patched files into container
sudo docker cp ~/rcp-cidr-patch/patches/ipv4am.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py

sudo docker cp ~/rcp-cidr-patch/patches/system_config.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py

# Verify patch
sudo docker exec spectrum-x-rcp grep -c 'host_subnet_size' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
# Should output: 2

sudo docker exec spectrum-x-rcp grep -c '_set_host_subnet_size' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py
# Should output: 2
```

## Step 11: Verify IP Allocation

```bash
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.config_manager import ConfigManager
from spcx_core.configurator.ipv4am import IPv4AM
config = ConfigManager()
print("host_subnet_size:", config.get("host_subnet_size"))
subnet_size, addresses_per_block = IPv4AM._get_subnet_config()
print("addresses_per_block:", addresses_per_block)
for i in range(4):
    fourth = i * addresses_per_block
    print(f"Host {i}: 172.16.0.{fourth}/{subnet_size}")
    print(f"  - Switch IP: 172.16.0.{fourth+1}")
    print(f"  - Available for pods: .{fourth+2}-.{fourth+7} (6 IPs)")
'
```

**Expected Output:**
```
host_subnet_size: 29
addresses_per_block: 8

Host 0: 172.16.0.0/29
  - Switch IP: 172.16.0.1
  - Available for pods: .2-.7 (6 IPs)
Host 1: 172.16.0.8/29
  - Switch IP: 172.16.0.9
  - Available for pods: .10-.15 (6 IPs)
Host 2: 172.16.0.16/29
  - Switch IP: 172.16.0.17
  - Available for pods: .18-.23 (6 IPs)
Host 3: 172.16.0.24/29
  - Switch IP: 172.16.0.25
  - Available for pods: .26-.31 (6 IPs)
```

## Step 12: Run RCP Configuration (Switch-Only Mode)

This workflow configures switches without requiring hosts to be online. This is useful for pre-staging network configuration.

```bash
# Generate recommended topology
sudo docker exec spectrum-x-rcp rcp-tool topology recommended

# Verify the IP scheme shows correct subnet size
sudo docker exec spectrum-x-rcp rcp-tool host show --ip_scheme
```

**Expected Output (with /29 subnet):**
```
+--------------+------+----------------+------+
| host         | port | ip address     | rail |
+--------------+------+----------------+------+
| hgx-su00-h00 | eth1 | 172.16.0.0/29  | 0    |
| hgx-su00-h00 | eth2 | 172.18.0.0/29  | 1    |
| hgx-su00-h01 | eth1 | 172.16.0.8/29  | 0    |
| hgx-su00-h01 | eth2 | 172.18.0.8/29  | 1    |
...
```

```bash
# Generate netplan configs (saved to host/out/<hostname>.yaml)
sudo docker exec spectrum-x-rcp rcp-tool host configure --generate

# Configure switches
sudo docker exec spectrum-x-rcp rcp-tool switch prepare
sudo docker exec spectrum-x-rcp rcp-tool switch configure

# Copy netplan files to topology/out for access outside container
sudo docker exec spectrum-x-rcp cp -r /root/spectrum-x-rcp/host/out/. /root/spectrum-x-rcp/topology/out/
```

## Step 13: Generate Kubernetes CIDRPool YAMLs

Exit the RCP container context and generate NV-IPAM CIDRPool YAMLs from the netplan configs.

### Install Dependencies

```bash
# Install jq and yq (Mike Farah version)
sudo apt install -y jq
sudo snap install yq
```

### Run Conversion Script

```bash
# Set up directories
mkdir -p host/netplan host/cidrpool

# Copy netplan files from container output
sudo chown ubuntu:ubuntu ~/spectrum-x-rcp/topology/out/*.yaml
mv ~/spectrum-x-rcp/topology/out/hgx-*.yaml host/netplan/

# Run the conversion script (auto-detects subnet prefix)
chmod +x ~/rcp-cidr-patch/generate_rail_cidrpools.sh
~/rcp-cidr-patch/generate_rail_cidrpools.sh -i host/netplan -o host/cidrpool
```

**Expected Output:**
```
Auto-detected subnet prefix: /29
Wrote /home/ubuntu/host/cidrpool/rail-1-cidrpool.yaml
Wrote /home/ubuntu/host/cidrpool/rail-2-cidrpool.yaml
Wrote /home/ubuntu/host/cidrpool/rail-3-cidrpool.yaml
Wrote /home/ubuntu/host/cidrpool/rail-4-cidrpool.yaml
CIDRPool generation complete.
```

### View Generated CIDRPool YAMLs

```bash
cd host/cidrpool
for i in $(ls *-cidrpool.yaml); do echo "---" && cat $i; done
```

**Example Output (rail-1):**
```yaml
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: CIDRPool
metadata:
  name: rail-1
  namespace: nvidia-network-operator
spec:
  cidr: 172.16.0.0/15
  gatewayIndex: 0
  perNodeNetworkPrefix: 29
  routes:
    - dst: 172.16.0.0/15
    - dst: 172.16.0.0/12
  staticAllocations:
    - gateway: 172.16.0.1
      nodeName: hgx-su00-h00
      prefix: 172.16.0.0/29
    - gateway: 172.16.0.9
      nodeName: hgx-su00-h01
      prefix: 172.16.0.8/29
    - gateway: 172.16.0.17
      nodeName: hgx-su00-h02
      prefix: 172.16.0.16/29
    - gateway: 172.16.0.25
      nodeName: hgx-su00-h03
      prefix: 172.16.0.24/29
```

## Step 14: Apply CIDRPools to Kubernetes (Optional)

If you have a Kubernetes cluster with NV-IPAM installed:

```bash
kubectl apply -f host/cidrpool/
```

## Alternative: Full Configuration with Hosts Online

If hosts are online and you want full end-to-end configuration:

```bash
# Clean any existing configuration
sudo docker exec spectrum-x-rcp rcp-tool all clean

# Full configuration workflow
sudo docker exec spectrum-x-rcp rcp-tool topology recommended
sudo docker exec spectrum-x-rcp rcp-tool host prepare
sudo docker exec spectrum-x-rcp rcp-tool switch prepare
sudo docker exec spectrum-x-rcp rcp-tool topology discover --mode full
sudo docker exec spectrum-x-rcp rcp-tool all configure

# Validate
sudo docker exec spectrum-x-rcp rcp-tool validation switch-config
sudo docker exec spectrum-x-rcp rcp-tool validation host-config
sudo docker exec spectrum-x-rcp rcp-tool validation ping
```

## IP Allocation Summary

| Subnet Size | Addresses/Block | Host IPs | Switch IP | Extra for Pods |
|-------------|-----------------|----------|-----------|----------------|
| `/31` (default) | 2 | 1 | 1 | 0 |
| `/30` | 4 | 1 | 1 | 2 |
| `/29` | 8 | 1 | 1 | 6 |

### /29 IP Layout (per host, per rail)

```
Host 0, Rail 0: 172.16.0.0/29
  ├── 172.16.0.0 - Host base IP
  ├── 172.16.0.1 - Switch IP
  ├── 172.16.0.2 - Pod IP 1
  ├── 172.16.0.3 - Pod IP 2
  ├── 172.16.0.4 - Pod IP 3
  ├── 172.16.0.5 - Pod IP 4
  ├── 172.16.0.6 - Pod IP 5
  └── 172.16.0.7 - Pod IP 6

Host 1, Rail 0: 172.16.0.8/29
  ├── 172.16.0.8 - Host base IP
  ├── 172.16.0.9 - Switch IP
  └── 172.16.0.10-15 - Pod IPs (6 available)

... and so on for each host and rail
```

## Files Modified by Patch

| File | Location | Changes |
|------|----------|---------|
| `ipv4am.py` | `spcx_core/configurator/` | Added `_get_subnet_config()`, `_calculate_host_fourth_octet()`, configurable subnet in `set_host_ip()` |
| `system_config.py` | `spcx_core/config/` | Added `host_subnet_size` validation and defaults |

## Troubleshooting

### Connection Refused
Wait 30-60 seconds after starting simulation for SSH to become available.

### Missing Config Parameters
Ensure all required parameters are in `config.yaml`. Check RCP logs:
```bash
sudo docker logs spectrum-x-rcp
```

### Patch Not Applied
Verify patch with:
```bash
sudo docker exec spectrum-x-rcp grep "host_subnet_size" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```

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
- `rcp-cidr-patch/sample-config.yaml` - Sample configuration
- `rcp-cidr-patch/apply-cidr-patch.sh` - Patch installation script
- `rcp-cidr-patch/generate_rail_cidrpools.sh` - Netplan to CIDRPool converter

## Changelog

### v1.1.0 (2026-01-16)
- **Changed**: `hca_type` in config examples from `BlueField-3` to `ConnectX-7`
- **Changed**: Step 12 rewritten as "Switch-Only Mode" workflow (hosts not required)
- **Added**: Step 13 - Generate Kubernetes CIDRPool YAMLs using conversion script
- **Added**: Step 14 - Apply CIDRPools to Kubernetes
- **Added**: Alternative section for full configuration with hosts online
- **Added**: Expected output examples for IP scheme and CIDRPool generation
- **Added**: `generate_rail_cidrpools.sh` to Related Files

### v1.0.0 (2026-01-15)
- Initial deployment guide
- NVIDIA AIR simulation setup steps
- RCP container installation
- CIDR patch application
- IP allocation verification
