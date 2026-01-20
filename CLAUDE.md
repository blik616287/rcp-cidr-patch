# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a patch for the NVIDIA Spectrum-X RCP (Reference Configuration Platform) tool that enables configurable subnet sizes (`/29`, `/30`, `/31`) for host IP allocation. The original RCP hardcodes `/31` subnets, limiting hosts to a single IP per rail. This patch enables multi-pod-per-node Kubernetes deployments requiring multiple RDMA-capable IP addresses.

## Key Commands

### Apply/Verify/Rollback Patch
```bash
./apply-cidr-patch.sh           # Apply patch to container
./apply-cidr-patch.sh -v        # Verify patch installation
./apply-cidr-patch.sh -r        # Rollback to original
./apply-cidr-patch.sh -c NAME   # Use custom container name
```

### RCP Configuration Workflow
```bash
docker exec spectrum-x-rcp rcp-tool topology recommended
docker exec spectrum-x-rcp rcp-tool host configure --generate
docker exec spectrum-x-rcp rcp-tool switch prepare
docker exec spectrum-x-rcp rcp-tool switch configure
docker exec spectrum-x-rcp rcp-tool all clean  # Reset configuration
```

### CIDRPool Generation
```bash
./generate_rail_cidrpools.sh -i host/netplan -o host/cidrpool [-n namespace] [-p subnet]
```

## Architecture

The patch modifies four files inside the `spectrum-x-rcp` Docker container at `/usr/local/lib/python3.12/dist-packages/spcx_core/`:

| Patch File | Target | Purpose |
|------------|--------|---------|
| `patches/ipv4am.py` | `configurator/ipv4am.py` | IP allocation logic with `_get_subnet_config()` and `_calculate_host_fourth_octet()` |
| `patches/system_config.py` | `config/system_config.py` | Validates `host_subnet_size` parameter (29, 30, 31) |
| `patches/nodes_info_builder.py` | `nodes_info_builder.py` | Exposes `subnet` field to Jinja2 templates |
| `patches/leaf_yaml.j2` | `switch/cumulus/none/leaf_yaml.j2` | Dynamic subnet for host ports, fixed `/31` for spine |

### IP Allocation Formula
```python
addresses_per_block = 2 ** (32 - subnet_size)  # /29=8, /30=4, /31=2
fourth_octet = host_index * addresses_per_block
```

### Topology-Aware Design
- `IPv4AM` base class handles 2-tier topology
- `IPv4AM3TierTopology` subclass overrides `set_host_ip()` for 3-tier
- Host connections use configurable subnet; spine connections always `/31`

## Version Compatibility

- RCP Version: V2.0.0-GA
- Python: 3.12
- Container: `gitlab-master.nvidia.com:5005/cloud-orchestration/spectrum-x-rcp:V2.0.0-GA.1`

## Dependencies

- Docker CLI
- Bash shell
- For CIDRPool generation: `jq`, `yq` (Mike Farah version via snap)
- For NVIDIA AIR deployment: `gust` CLI
