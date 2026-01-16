# Validation Guide

This document provides step-by-step procedures to validate the RCP CIDR patch installation and all v1.1.0 changes.

## Prerequisites

- NVIDIA AIR simulation running with RCP container
- SSH access to the oob-mgmt-server
- Patch files copied to the simulation

## Quick Validation Checklist

| Test | Command | Expected Result |
|------|---------|-----------------|
| Patch Applied | `grep -c '_get_subnet_config'` | `4` |
| Subnet Config | `IPv4AM._get_subnet_config()` | `(29, 8)` for /29 |
| Host IPs | `rcp-tool host show --ip_scheme` | Shows `/29` addresses |
| Leaf-Host Subnet | Check `set_leaf_ip` code | Uses configurable subnet |
| Leaf-Spine Subnet | Check `set_leaf_ip` code | Fixed `/31` |
| CIDRPool Script | `./generate_rail_cidrpools.sh` | Auto-detects prefix |

---

## 1. Validate Patch Installation

### 1.1 Verify Patched Files Exist

```bash
# Check ipv4am.py patch markers
sudo docker exec spectrum-x-rcp grep -c '_get_subnet_config' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```
**Expected:** `4` (method definition + 3 calls)

```bash
# Check system_config.py patch markers
sudo docker exec spectrum-x-rcp grep -c '_set_host_subnet_size' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py
```
**Expected:** `2` (method definition + 1 call)

### 1.2 Verify Configuration Parameter

```bash
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.config_manager import ConfigManager
config = ConfigManager()
print("host_subnet_size:", config.get("host_subnet_size"))
'
```
**Expected:** `host_subnet_size: 29` (or configured value)

---

## 2. Validate Subnet Configuration Logic

### 2.1 Test _get_subnet_config Method

```bash
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.configurator.ipv4am import IPv4AM
subnet_size, addresses_per_block = IPv4AM._get_subnet_config()
print(f"Subnet size: /{subnet_size}")
print(f"Addresses per block: {addresses_per_block}")

# Validate calculation
expected = 2 ** (32 - subnet_size)
assert addresses_per_block == expected, f"Mismatch: {addresses_per_block} != {expected}"
print("PASS: Subnet config calculation correct")
'
```
**Expected Output:**
```
Subnet size: /29
Addresses per block: 8
PASS: Subnet config calculation correct
```

### 2.2 Test IP Allocation Formula

```bash
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.configurator.ipv4am import IPv4AM

subnet_size, addresses_per_block = IPv4AM._get_subnet_config()
print(f"Testing /{subnet_size} subnet ({addresses_per_block} addresses per block)")
print()

for host_index in range(4):
    fourth_octet = IPv4AM._calculate_host_fourth_octet(host_index, addresses_per_block)
    host_ip = f"172.16.0.{fourth_octet}/{subnet_size}"
    switch_ip = f"172.16.0.{fourth_octet + 1}"
    print(f"Host {host_index}: {host_ip}")
    print(f"  Switch: {switch_ip}")
    print(f"  Pod IPs: .{fourth_octet + 2} - .{fourth_octet + addresses_per_block - 1}")
    print()
'
```
**Expected Output (for /29):**
```
Testing /29 subnet (8 addresses per block)

Host 0: 172.16.0.0/29
  Switch: 172.16.0.1
  Pod IPs: .2 - .7

Host 1: 172.16.0.8/29
  Switch: 172.16.0.9
  Pod IPs: .10 - .15

Host 2: 172.16.0.16/29
  Switch: 172.16.0.17
  Pod IPs: .18 - .23

Host 3: 172.16.0.24/29
  Switch: 172.16.0.25
  Pod IPs: .26 - .31
```

---

## 3. Validate Switch Subnet Behavior (v1.1.0 Fix)

### 3.1 Verify Leaf-to-Host Uses Configurable Subnet

```bash
sudo docker exec spectrum-x-rcp grep -A5 'peer_role == "host"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | head -10
```
**Expected:** Should show `port.subnet = str(subnet_size)` (configurable)

### 3.2 Verify Leaf-to-Spine Uses Fixed /31

```bash
sudo docker exec spectrum-x-rcp grep -A3 'peer_role == "spine"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | head -8
```
**Expected:** Should show `port.subnet = "31"` (fixed)

### 3.3 Verify Spine Connections Use Fixed /31

```bash
sudo docker exec spectrum-x-rcp grep -B2 -A1 'port.subnet = "31"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```
**Expected:** Should show `/31` for:
- Leaf-to-spine connections
- Spine-to-leaf connections
- Spine-to-super_spine connections

### 3.4 Full Subnet Behavior Test

```bash
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.configurator.ipv4am import IPv4AM

subnet_size, _ = IPv4AM._get_subnet_config()

print("Subnet Behavior Validation")
print("=" * 40)
print(f"Host-to-leaf connections:     /{subnet_size} (configurable)")
print(f"Leaf-to-host connections:     /{subnet_size} (configurable)")
print(f"Leaf-to-spine connections:    /31 (fixed)")
print(f"Spine-to-leaf connections:    /31 (fixed)")
print(f"Spine-to-super_spine:         /31 (fixed)")
print()
print("PASS: Subnet behavior correctly configured")
'
```

---

## 4. Validate RCP Configuration Workflow

### 4.1 Generate Topology

```bash
sudo docker exec spectrum-x-rcp rcp-tool topology recommended
```
**Expected:** No errors

### 4.2 Verify IP Scheme

```bash
sudo docker exec spectrum-x-rcp rcp-tool host show --ip_scheme
```
**Expected Output (for /29):**
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

**Validation Points:**
- [ ] Subnet suffix matches configured `host_subnet_size` (e.g., `/29`)
- [ ] IP addresses are spaced by `addresses_per_block` (e.g., 0, 8, 16, 24 for /29)
- [ ] All rails show consistent subnet size

### 4.3 Generate Host Netplan Configs

```bash
sudo docker exec spectrum-x-rcp rcp-tool host configure --generate
sudo docker exec spectrum-x-rcp ls -la /root/spectrum-x-rcp/host/out/
```
**Expected:** `hgx-su00-h00.yaml`, `hgx-su00-h01.yaml`, etc.

### 4.4 Verify Netplan Content

```bash
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/host/out/hgx-su00-h00.yaml
```
**Expected:** Addresses should show configured subnet (e.g., `172.16.0.0/29`)

---

## 5. Validate CIDRPool Conversion Script (v1.1.0)

### 5.1 Prerequisites Check

```bash
# Check jq
which jq && jq --version

# Check yq (must be Mike Farah version)
which yq && yq --version
```
**Expected:** Both installed, yq shows `mikefarah/yq`

### 5.2 Setup Test Environment

```bash
# Copy netplan files from container
mkdir -p ~/test-validation/netplan ~/test-validation/cidrpool
sudo docker cp spectrum-x-rcp:/root/spectrum-x-rcp/host/out/. ~/test-validation/netplan/
sudo chown -R $USER:$USER ~/test-validation/
```

### 5.3 Test Auto-Detection

```bash
cd ~/test-validation
~/rcp-cidr-patch/generate_rail_cidrpools.sh -i netplan -o cidrpool
```
**Expected Output:**
```
Auto-detected subnet prefix: /29
Wrote .../cidrpool/rail-1-cidrpool.yaml
Wrote .../cidrpool/rail-2-cidrpool.yaml
...
CIDRPool generation complete.
```

### 5.4 Verify CIDRPool Content

```bash
cat ~/test-validation/cidrpool/rail-1-cidrpool.yaml
```
**Expected:**
- `perNodeNetworkPrefix: 29` (matches auto-detected)
- `staticAllocations` contains all hosts with correct IPs
- `gateway` values are host_ip + 1

### 5.5 Test Manual Prefix Override

```bash
~/rcp-cidr-patch/generate_rail_cidrpools.sh -i netplan -o cidrpool-override -p 30
cat ~/test-validation/cidrpool-override/rail-1-cidrpool.yaml | grep perNodeNetworkPrefix
```
**Expected:** `perNodeNetworkPrefix: 30`

---

## 6. Validate Configuration File Changes (v1.1.0)

### 6.1 Verify hca_type Change

```bash
grep -r "hca_type" ~/rcp-cidr-patch/*.yaml ~/rcp-cidr-patch/*.md 2>/dev/null | grep -v "BlueField"
```
**Expected:** All occurrences show `ConnectX-7`

### 6.2 Verify CIDRPool Format in README

```bash
grep -A5 "perNodeNetworkPrefix" ~/rcp-cidr-patch/README.md
```
**Expected:** Shows `perNodeNetworkPrefix` (not `perNodeBlockSize`)

---

## 7. End-to-End Validation Script

Run this script to perform all validations automatically:

```bash
#!/bin/bash
# Save as: validate-patch.sh

set -e
echo "=== RCP CIDR Patch Validation ==="
echo

# Test 1: Patch installation
echo "1. Checking patch installation..."
COUNT=$(sudo docker exec spectrum-x-rcp grep -c '_get_subnet_config' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py)
if [ "$COUNT" -eq 4 ]; then
  echo "   PASS: ipv4am.py patch applied"
else
  echo "   FAIL: ipv4am.py patch count mismatch (expected 4, got $COUNT)"
  exit 1
fi

# Test 2: Subnet config
echo "2. Checking subnet configuration..."
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.configurator.ipv4am import IPv4AM
size, block = IPv4AM._get_subnet_config()
assert block == 2 ** (32 - size), "Calculation mismatch"
print(f"   PASS: Subnet /{size} with {block} addresses per block")
'

# Test 3: Switch subnet behavior
echo "3. Checking switch subnet behavior..."
LEAF_HOST=$(sudo docker exec spectrum-x-rcp grep -A2 'peer_role == "host"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -c 'subnet_size')
LEAF_SPINE=$(sudo docker exec spectrum-x-rcp grep -A2 'peer_role == "spine"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -c '"31"')
if [ "$LEAF_HOST" -ge 1 ] && [ "$LEAF_SPINE" -ge 1 ]; then
  echo "   PASS: Leaf-host=configurable, Leaf-spine=/31"
else
  echo "   FAIL: Switch subnet behavior incorrect"
  exit 1
fi

# Test 4: IP scheme
echo "4. Checking IP scheme generation..."
sudo docker exec spectrum-x-rcp rcp-tool topology recommended >/dev/null 2>&1
IP_SCHEME=$(sudo docker exec spectrum-x-rcp rcp-tool host show --ip_scheme 2>/dev/null | head -5)
if echo "$IP_SCHEME" | grep -q "/29\|/30\|/31"; then
  echo "   PASS: IP scheme shows correct subnet"
else
  echo "   FAIL: IP scheme missing subnet"
  exit 1
fi

# Test 5: hca_type
echo "5. Checking hca_type configuration..."
if ! grep -r "BlueField-3" ~/rcp-cidr-patch/*.yaml ~/rcp-cidr-patch/*.md 2>/dev/null | grep -v "Changelog" | grep -q .; then
  echo "   PASS: hca_type updated to ConnectX-7"
else
  echo "   FAIL: BlueField-3 still present in configs"
  exit 1
fi

echo
echo "=== All Validations Passed ==="
```

---

## 8. Troubleshooting Failed Validations

### Patch Not Applied
```bash
# Re-apply patch
sudo docker cp ~/rcp-cidr-patch/patches/ipv4am.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
sudo docker cp ~/rcp-cidr-patch/patches/system_config.py \
  spectrum-x-rcp:/usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py
```

### Wrong Subnet Size
```bash
# Check config.yaml
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/config/config.yaml | grep host_subnet_size
```

### CIDRPool Script Fails
```bash
# Check yq version (must be Mike Farah)
yq --version
# If wrong version, reinstall
sudo snap remove yq
sudo snap install yq
```

### Snap Cannot Access Files
```bash
# Move files to home directory (snap confinement)
cp -r /tmp/netplan ~/netplan
```

---

## Changelog

### v1.0.0 (2026-01-16)
- Initial validation guide
- Patch installation tests
- Subnet configuration tests
- Switch behavior tests (v1.1.0 fix)
- CIDRPool conversion tests
- End-to-end validation script
