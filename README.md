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

| Subnet | Addresses/Block | Host IPs | Switch IP | Use Case |
|--------|-----------------|----------|-----------|----------|
| `/31` (default) | 2 | 1 | 1 | Host-level only |
| `/30` | 4 | 3 | 1 | 2 GPUs, 1 pod each |
| `/29` | 8 | 7 | 1 | 4+ GPUs, 1 pod each |

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
```

### Verify Installation

```bash
./apply-cidr-patch.sh -v
```

### Rollback

```bash
./apply-cidr-patch.sh -r
```

## Configuration

After applying the patch, add the `host_subnet_size` parameter to your `config.yaml`:

```yaml
# config.yaml
is_simulation: true
pod_num: 1
pod_size: 1
topology: "2-tier-poc"
system_type: "h100"
hca_type: "BlueField-3"
host_interfaces: ["eth1", "eth2", "eth3", "eth4"]

# NEW: Configurable subnet size (29, 30, or 31)
host_subnet_size: 30
```

### Configuration Options

| Value | Subnet | Addresses | Description |
|-------|--------|-----------|-------------|
| `31` | /31 | 2 | Default. 1 IP for host, 1 for switch. Host-level only. |
| `30` | /30 | 4 | 1 IP for host, 1 for switch, 2 extra for pods. |
| `29` | /29 | 8 | 1 IP for host, 1 for switch, 6 extra for pods. |

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

## Re-applying Configuration

After modifying `config.yaml`, re-run the RCP configuration:

```bash
# Clean existing configuration
docker exec spectrum-x-rcp rcp-tool all clean

# Re-apply with new subnet size
docker exec spectrum-x-rcp rcp-tool all configure

# Validate
docker exec spectrum-x-rcp rcp-tool validation host-config
docker exec spectrum-x-rcp rcp-tool validation ping
```

## Kubernetes Integration

With larger subnets, you can configure:

### NV-IPAM CIDRPools

```yaml
apiVersion: nv-ipam.nvidia.com/v1alpha1
kind: CIDRPool
metadata:
  name: rail0-pool
spec:
  cidr: "172.16.0.0/16"
  perNodeBlockSize: 4  # For /30, use 4. For /29, use 8.
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
├── apply-cidr-patch.sh          # Installation script
├── sample-config.yaml           # Example configuration
├── patches/
│   ├── ipv4am.py               # Modified IP allocator
│   └── system_config.py        # Modified config validator
└── backups/                     # Created during installation
    ├── ipv4am.py.orig          # Original IP allocator
    └── system_config.py.orig   # Original config validator
```

## Version Compatibility

- **RCP Version:** V2.0.0-GA
- **Docker Image:** `gitlab-master.nvidia.com:5005/cloud-orchestration/spectrum-x-rcp:V2.0.0-GA.1`
- **Python Version:** 3.12
- **spcx_core Location:** `/usr/local/lib/python3.12/dist-packages/spcx_core/`

## License

This patch modifies NVIDIA proprietary software. Use in accordance with NVIDIA licensing terms.
