# RCP Configurable CIDR/Subnet Size Patch

This patch modifies the NVIDIA Spectrum-X RCP (Reference Configuration Platform) tool to support configurable subnet sizes for host IP allocation, enabling multi-pod-per-node Kubernetes deployments.

## Problem Statement

The original RCP tool hardcodes `/31` subnets for host-to-switch IP allocation. With `/31`, each host only gets a single IP address per rail, which is insufficient for Kubernetes deployments where multiple pods per node need unique RDMA-capable IP addresses.

### Original Behavior

```
Host 0, eth1: 172.16.0.0/31  (only 1 usable IP for host)
Host 0, eth2: 172.18.0.0/31
Host 1, eth1: 172.16.0.2/31
Host 1, eth2: 172.18.0.2/31
```

### Desired Behavior

With configurable subnet sizes:

| Subnet | Addresses/Block | Host | Gateway | Pods | Use Case |
|--------|-----------------|------|---------|------|----------|
| `/31` (default) | 2 | 1 | 1 | 0 | Host-level only |
| `/30` | 4 | 1 | 1 | 0 | Not recommended (same as /31) |
| `/29` | 8 | 1 | 1 | 4 | Multi-pod: 4 GPUs, 1 pod each |

**Note:** `/30` subnets are effectively useless for multi-pod scenarios because the .0 (network) and .3 (broadcast) addresses are not usable, leaving no room for pods. Use `/29` for multi-pod deployments.

## Files Modified

### 1. `spcx_core/configurator/ipv4am.py`

**Location in container:** `/usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py`

**Changes:**
- Added `_get_subnet_config()` method to retrieve configurable subnet size
- Added `_calculate_host_fourth_octet()` method for flexible IP calculation
- Modified `set_host_ip()` in `IPv4AM` class to use configurable subnet
- Modified `set_host_ip()` in `IPv4AM3TierTopology` class to use configurable subnet
- Changed hardcoded `port.subnet = "31"` to use config value

**Key Code Changes:**

```python
# NEW: Helper method to get subnet configuration
@classmethod
def _get_subnet_config(cls) -> tuple[int, int]:
    config_manager = ConfigManager()
    subnet_size = config_manager.get("host_subnet_size", 31)
    addresses_per_block = 2 ** (32 - subnet_size)
    return subnet_size, addresses_per_block

# NEW: Calculate fourth octet based on subnet size
@classmethod
def _calculate_host_fourth_octet(cls, index_in_su: int, addresses_per_block: int) -> int:
    return index_in_su * addresses_per_block

# MODIFIED: In set_host_ip()
# OLD: fourth_octet = port.node.index_in_su << 1
#      port.subnet = "31"
# NEW:
subnet_size, addresses_per_block = cls._get_subnet_config()
fourth_octet = cls._calculate_host_fourth_octet(port.node.index_in_su, addresses_per_block)
port.subnet = str(subnet_size)
```

### 2. `spcx_core/config/system_config.py`

**Location in container:** `/usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py`

**Changes:**
- Added `host_subnet_size` to `SUPPORTED_VALUES` for validation
- Added `_set_host_subnet_size()` method to set default value
- Added `_verify_host_subnet_size()` method for validation
- Updated `validate_config()` to call new verification
- Updated `update_config()` to set default subnet size

### 3. `spcx_core/nodes_info_builder.py`

**Location in container:** `/usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py`

**Changes:**
- Added `subnet` field to leaf port info for host connections
- This exposes the configurable subnet value to Jinja2 templates

### 4. `spcx_core/switch/cumulus/none/leaf_yaml.j2`

**Location in container:** `/usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2`

**Changes:**
- Modified IPv4 address rendering to use dynamic subnet for host connections
- Host-facing ports use configurable subnet (`/29`, `/30`, or `/31`)
- Spine-facing ports remain fixed at `/31`

## Installation

### Prerequisites

- Running RCP Docker container (typically named `spectrum-x-rcp`)
- Docker CLI access
- Bash shell

### Quick Install

```bash
# Clone or copy the patch files to your server
cd /path/to/rcp-cidr-patch

# Make the script executable
chmod +x apply-cidr-patch.sh

# Apply the patch
./apply-cidr-patch.sh
```

### Manual Install

```bash
# Copy patched files into the container
docker cp patches/ipv4am.py spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
docker cp patches/system_config.py spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py
docker cp patches/nodes_info_builder.py spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py
docker cp patches/leaf_yaml.j2 spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2
```

### Verify Installation

```bash
./apply-cidr-patch.sh -v
```

### Rollback

```bash
./apply-cidr-patch.sh -r
```

### Full Automated Deployment (NVIDIA AIR)

For end-to-end deployment on NVIDIA AIR simulation environments, use the `deploy-and-validate.sh` script:

```bash
chmod +x deploy-and-validate.sh
./deploy-and-validate.sh [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-s, --subnet-size SIZE` | Subnet size: 29, 30, or 31 (default: 30) |
| `-c, --container NAME` | Container name (default: spectrum-x-rcp) |
| `-h, --help` | Show help message |
| `--skip-docker` | Skip Docker installation (if already installed) |
| `--skip-patch` | Skip patch application (if already applied) |
| `--validate-only` | Only run validation tests |

**Examples:**

```bash
# Full deployment with /30 subnets (default)
./deploy-and-validate.sh

# Full deployment with /29 subnets
./deploy-and-validate.sh -s 29

# Only run validation tests
./deploy-and-validate.sh --validate-only

# Skip Docker install and use custom container name
./deploy-and-validate.sh --skip-docker -c my-rcp-container
```

The script performs: Docker installation, RCP image loading, topology discovery via LLDP, patch application, RCP configuration, and comprehensive validation tests.

## Configuration

After applying the patch, add the `host_subnet_size` parameter to your `config.yaml`:

```yaml
# config.yaml
is_simulation: true
pod_num: 1
pod_size: 1
topology: "2-tier-poc"
system_type: "h100"
hca_type: "ConnectX-7"
host_interfaces: ["eth1", "eth2", "eth3", "eth4"]

# NEW: Configurable subnet size (29, 30, or 31)
host_subnet_size: 30
```

### Configuration Options

| Value | Subnet | Addresses | Usable for Pods | Description |
|-------|--------|-----------|-----------------|-------------|
| `31` | /31 | 2 | 0 | Default. 1 IP for host, 1 for switch. Host-level only. |
| `30` | /30 | 4 | 0 | Not recommended. Same as /31 due to network/broadcast addresses. |
| `29` | /29 | 8 | 4 | 1 host (.2), 1 gateway (.1), 4 pods (.3-.6), network (.0) and broadcast (.7) unusable. |

## IP Address Allocation

### Example: 4 Hosts, 4 Rails, `/30` Subnet

```
Rail 0 (eth1):
  Host 0: 172.16.0.0/30  (switch: 172.16.0.1, extra: .2, .3)
  Host 1: 172.16.0.4/30  (switch: 172.16.0.5, extra: .6, .7)
  Host 2: 172.16.0.8/30  (switch: 172.16.0.9, extra: .10, .11)
  Host 3: 172.16.0.12/30 (switch: 172.16.0.13, extra: .14, .15)

Rail 1 (eth2):
  Host 0: 172.18.0.0/30  (switch: 172.18.0.1, extra: .2, .3)
  Host 1: 172.18.0.4/30  (switch: 172.18.0.5, extra: .6, .7)
  ...
```

### Example: 4 Hosts, 4 Rails, `/29` Subnet

```
Rail 0 (eth1):
  Host 0: 172.16.0.0/29  (switch: .1, extra: .2-.7)
  Host 1: 172.16.0.8/29  (switch: .9, extra: .10-.15)
  Host 2: 172.16.0.16/29 (switch: .17, extra: .18-.23)
  Host 3: 172.16.0.24/29 (switch: .25, extra: .26-.31)
```

## RCP Configuration Workflow

The patched RCP can configure switches without requiring hosts to be online. This is useful for pre-staging network configuration.

### Step 1: Generate Topology and IP Scheme

```bash
# Generate recommended topology
docker exec spectrum-x-rcp rcp-tool topology recommended

# Verify IP scheme (should show /29 or configured subnet)
docker exec spectrum-x-rcp rcp-tool host show --ip_scheme
```

### Step 2: Generate Host Netplan Configs

```bash
# Generate netplan configs (saved to host/out/<hostname>.yaml)
docker exec spectrum-x-rcp rcp-tool host configure --generate
```

### Step 3: Configure Switches

```bash
# Prepare and configure switches
docker exec spectrum-x-rcp rcp-tool switch prepare
docker exec spectrum-x-rcp rcp-tool switch configure
```

### Step 4: Export Netplan Files

```bash
# Copy netplan files to topology/out for access outside container
docker exec spectrum-x-rcp cp -r /root/spectrum-x-rcp/host/out/. /root/spectrum-x-rcp/topology/out/
```

### Re-applying Configuration

After modifying `config.yaml`, clean and re-run:

```bash
# Clean existing configuration
docker exec spectrum-x-rcp rcp-tool all clean

# Re-apply with new subnet size
docker exec spectrum-x-rcp rcp-tool topology recommended
docker exec spectrum-x-rcp rcp-tool host configure --generate
docker exec spectrum-x-rcp rcp-tool switch prepare
docker exec spectrum-x-rcp rcp-tool switch configure
```

## Kubernetes Integration

With larger subnets, you can configure:

### NV-IPAM CIDRPools

```yaml
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: CIDRPool
metadata:
  name: rail-1
  namespace: nvidia-network-operator
spec:
  cidr: 172.16.0.0/15
  gatewayIndex: 1          # Gateway at .1 position within each block
  perNodeNetworkPrefix: 29
  routes:
    - dst: 172.16.0.0/15
    - dst: 172.16.0.0/12
  staticAllocations:
    - gateway: 172.16.0.1
      nodeName: hgx-su00-h00
      prefix: 172.16.0.0/29   # Network address, NOT host address
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

**Important CIDRPool requirements:**
- `gatewayIndex: 1` - Gateway is at the .1 position within each subnet block
- `prefix` in staticAllocations must be the **network address** (e.g., `172.16.0.0/29`), not the host address (`172.16.0.2/29`)
- First pod IP assigned will be `.2` (the host address), then `.3`, `.4`, etc.

### Generating CIDRPool YAMLs from Netplan

The included `generate_rail_cidrpools.sh` script converts RCP-generated netplan configs into NV-IPAM CIDRPool YAMLs.

**Prerequisites:**
```bash
# Install jq and yq (Mike Farah version)
sudo apt install -y jq
sudo snap install yq
```

**Usage:**
```bash
# Exit the RCP container first, then set up directories
mkdir -p host/netplan host/cidrpool

# Copy netplan files from container output
sudo chown $USER:$USER spectrum-x-rcp/topology/out/*.yaml
mv spectrum-x-rcp/topology/out/hgx-*.yaml host/netplan/

# Run the conversion script
chmod +x generate_rail_cidrpools.sh
./generate_rail_cidrpools.sh -i host/netplan -o host/cidrpool
```

**Options:**
```bash
./generate_rail_cidrpools.sh -i <input_dir> -o <output_dir> [-n <namespace>] [-p <subnet_prefix>]

  -i  Input directory containing netplan YAML files
  -o  Output directory for CIDRPool YAMLs
  -n  Kubernetes namespace (default: nvidia-network-operator)
  -p  Subnet prefix (29, 30, or 31). Auto-detected from netplan if not specified.
```

**View Generated YAMLs:**
```bash
cd host/cidrpool
for i in $(ls *-cidrpool.yaml); do echo "---" && cat $i; done
```

### MacvlanNetworks

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rail0-macvlan
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth1",
      "mode": "bridge",
      "ipam": {
        "type": "nv-ipam",
        "poolName": "rail0-pool"
      }
    }
```

## Troubleshooting

### Patch Not Applied

```bash
# Verify patch status
./apply-cidr-patch.sh -v

# Check if container is running
docker ps | grep spectrum-x-rcp

# Check file contents manually
docker exec spectrum-x-rcp grep "host_subnet_size" /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```

### Configuration Errors

```bash
# Check config.yaml syntax
docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/config/config.yaml

# Validate configuration
docker exec spectrum-x-rcp python3 -c "from spcx_core.config_manager import ConfigManager; c = ConfigManager(); print(c.get('host_subnet_size'))"
```

### IP Address Conflicts

If you change subnet sizes on an existing deployment:

1. Clean the existing configuration first
2. Re-run topology discovery
3. Re-apply configuration

```bash
docker exec spectrum-x-rcp rcp-tool all clean
docker exec spectrum-x-rcp rcp-tool topology discover --mode full
docker exec spectrum-x-rcp rcp-tool all configure
```

## Files in This Package

```
rcp-cidr-patch/
├── README.md                    # This documentation
├── CLAUDE.md                    # AI assistant guidance for Claude Code
├── DEPLOYMENT-GUIDE.md          # Step-by-step NVIDIA AIR deployment
├── VALIDATION.md                # Test procedures and validation guide
├── apply-cidr-patch.sh          # Installation script
├── deploy-and-validate.sh       # End-to-end automated deployment
├── generate_rail_cidrpools.sh   # Netplan to CIDRPool converter
├── sample-config.yaml           # Example configuration
├── patches/
│   ├── ipv4am.py               # Modified IP allocator
│   ├── system_config.py        # Modified config validator
│   ├── nodes_info_builder.py   # Modified node info builder (for template data)
│   └── leaf_yaml.j2            # Modified leaf switch Jinja2 template
```

## Version Compatibility

- **RCP Version:** V2.0.0-GA
- **Docker Image:** `gitlab-master.nvidia.com:5005/cloud-orchestration/spectrum-x-rcp:V2.0.0-GA.1`
- **Python Version:** 3.12
- **spcx_core Location:** `/usr/local/lib/python3.12/dist-packages/spcx_core/`

## Changelog

### v1.2.0 (2026-01-16)
- **Added**: `nodes_info_builder.py` patch to expose subnet value to Jinja2 templates
- **Added**: `leaf_yaml.j2` patch to use dynamic subnet for host-facing switch ports
- **Fixed**: Switch config YAML files now correctly show `/29` (or configured subnet) for host connections
- **Fixed**: Leaf-to-spine connections remain fixed at `/31` in switch config YAML
- **Validated**: Full end-to-end validation on NVIDIA AIR simulation

### v1.1.0 (2026-01-16)
- **Changed**: `hca_type` in examples from `BlueField-3` to `ConnectX-7`
- **Added**: `generate_rail_cidrpools.sh` script for converting netplan to CIDRPool YAMLs
- **Added**: RCP Configuration Workflow section with switch-only mode (no hosts required)
- **Added**: Generating CIDRPool YAMLs from Netplan section
- **Fixed**: Switch configs now use correct subnet sizes in `ipv4am.py`:
  - Host-to-leaf connections: configurable (`/29`, `/30`, `/31`)
  - Leaf-to-spine connections: fixed `/31`
  - Spine connections: fixed `/31`
- **Updated**: NV-IPAM CIDRPools example to use `perNodeNetworkPrefix` and `staticAllocations`

### v1.0.0 (2026-01-15)
- Initial release
- Added `host_subnet_size` configuration parameter (29, 30, 31)
- Modified `ipv4am.py` for configurable subnet sizing
- Modified `system_config.py` for parameter validation
- Created `apply-cidr-patch.sh` installation script

## License

This patch modifies NVIDIA proprietary software. Use in accordance with NVIDIA licensing terms.
