# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a patch for NVIDIA Spectrum-X RCP (Reference Configuration Platform) V2.0.0-GA that enables configurable CIDR subnet sizes (`/29`, `/30`, `/31`) for host-to-switch IP allocation. The original RCP hardcodes `/31` subnets; this patch allows larger subnets to support multiple pod IP addresses per host in Kubernetes multi-pod-per-node deployments.

## Commands

### Apply Patches to RCP Container
```bash
./apply-cidr-patch.sh                  # Apply patches to spectrum-x-rcp container
./apply-cidr-patch.sh -c <name>        # Specify different container name
./apply-cidr-patch.sh -v               # Verify installation
./apply-cidr-patch.sh -r               # Rollback to original files
```

### Full Deployment with Validation (NVIDIA AIR)
```bash
./deploy-and-validate.sh                   # Full deployment with /30 subnets (default)
./deploy-and-validate.sh -s 29             # Deploy with /29 subnets
./deploy-and-validate.sh -s 31             # Deploy with /31 subnets
./deploy-and-validate.sh -c <name>         # Specify different container name
./deploy-and-validate.sh --skip-docker     # Skip Docker installation
./deploy-and-validate.sh --skip-patch      # Skip patch application
./deploy-and-validate.sh --validate-only   # Run validation tests only
```

The deployment script:
1. Brings up host interfaces (eth1-eth4) before LLDP discovery
2. Installs lldpd and queries topology from host side
3. Falls back to default AIR topology if LLDP fails:
   - h00→swp1s0, h01→swp2s0, h02→swp3s0, h03→swp4s0 on both leaf switches

### RCP Commands (inside container)
```bash
docker exec spectrum-x-rcp rcp-tool topology recommended
docker exec spectrum-x-rcp rcp-tool host configure --generate
docker exec spectrum-x-rcp rcp-tool switch prepare
docker exec spectrum-x-rcp rcp-tool switch configure
```

### Generate Kubernetes CIDRPool Manifests
```bash
./generate_rail_cidrpools.sh           # Convert netplan YAML to K8s NV-IPAM CIDRPools
```

## Architecture

### Patch Files (`patches/`)

Four files are patched inside the RCP container at `/usr/local/lib/python3.12/dist-packages/spcx_core/`:

1. **`ipv4am.py`** → `configurator/ipv4am.py`
   - Core IP calculation logic
   - `_get_subnet_config()`: retrieves `host_subnet_size` from ConfigManager
   - `_calculate_host_fourth_octet()`: calculates IP offsets based on subnet size
   - `set_host_ip()`: modified to use configurable subnet for host-facing ports

2. **`system_config.py`** → `config/system_config.py`
   - Configuration validation
   - Adds `host_subnet_size` to `SUPPORTED_VALUES` with valid options [29, 30, 31]
   - `_set_host_subnet_size()`: sets default value
   - `_verify_host_subnet_size()`: validates user input

3. **`nodes_info_builder.py`** → `nodes_info_builder.py`
   - Exposes `subnet` field from port info to Jinja2 templates
   - Uses `getattr()` for graceful handling when subnet attribute is missing

4. **`leaf_yaml.j2`** → `switch/cumulus/none/leaf_yaml.j2`
   - Jinja2 template for leaf switch configuration
   - Uses dynamic `port_info["subnet"]` for host-facing ports
   - Spine-facing ports remain hardcoded at `/31`

### Subnet Allocation Logic

| Subnet | Addresses | Host IP | Switch IP | Pod IPs | Broadcast |
|--------|-----------|---------|-----------|---------|-----------|
| /31    | 2         | .0      | .1        | none    | none      |
| /30    | 4         | .2      | .1        | none    | .3        |
| /29    | 8         | .2      | .1        | .3-.6   | .7        |

### Key Design Decisions

- Host-to-switch connections use configurable subnet (`host_subnet_size`)
- Spine-to-leaf connections remain `/31` (standard for point-to-point links)
- Default is `/31` for backward compatibility if `host_subnet_size` not specified
- All 4 patch files must be applied together; missing any breaks configuration

## Configuration

Add to RCP `config.yaml`:
```yaml
host_subnet_size: 30  # Options: 29, 30, or 31 (default: 31)
```

## Dependencies

- NVIDIA Spectrum-X RCP V2.0.0-GA (running in Docker container named `spectrum-x-rcp`)
- Python 3.12 (inside container)
- For validation scripts: `jq`, `yq` (Mike Farah v4+), `sshpass`
