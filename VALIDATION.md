# RCP CIDR Patch Validation Guide

This document provides comprehensive validation procedures for the RCP CIDR patch, addressing all known issues and ensuring correct functionality.

## Problem Statement

The NVIDIA RCP tool originally generates `/31` subnets for host IP allocation, which only provides **1 usable IP address per NIC per node** (designed for host-level use only). This limitation prevents multi-pod-per-node Kubernetes deployments.

### Use Cases for Larger Subnets

| Subnet | Addresses | Usable for Pods | Use Case |
|--------|-----------|-----------------|----------|
| `/31` | 2 | 0 (host only) | Original design - host-level networking |
| `/30` | 4 | 0 (host only) | Not recommended - same as /31 due to network/broadcast |
| `/29` | 8 | 4 pods + 1 host | Multi-pod: 4 GPUs with 1 pod per GPU |

**Note:** `/30` provides no additional pod IPs over `/31` because the .0 (network) and .3 (broadcast) addresses are unusable. For multi-pod scenarios, use `/29`.

---

## Issues Addressed by This Patch

### Issue 1: Fixed /31 Subnet Size
**Original Problem:** RCP hardcoded `/31` subnets in multiple locations.

**Solution:** Added `host_subnet_size` configuration parameter that accepts `29`, `30`, or `31`.

**Validation:**
```bash
# Check config parameter is recognized
sudo docker exec spectrum-x-rcp python3 -c '
from spcx_core.config_manager import ConfigManager
config = ConfigManager()
print("host_subnet_size:", config.get("host_subnet_size"))
'
```

### Issue 2: Switch Configs Still Using /31
**Original Problem:** Even after patching, switch YAML configs showed `/31` for host-facing ports.

**Root Cause:** The `leaf_yaml.j2` template hardcoded the subnet mask.

**Solution:** Modified `leaf_yaml.j2` to use dynamic `port_info["subnet"]` value.

**Validation:**
```bash
# After running 'rcp-tool all configure', check switch configs
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml | grep -A3 "swp1s0:"
```
**Expected:** Shows `172.16.0.1/29` (not `/31`)

### Issue 3: Leaf-Spine Connections Must Remain /31
**Original Problem:** Initial patches incorrectly changed ALL connections to configurable subnet.

**Solution:** Only host-facing ports use configurable subnet; spine connections remain `/31`.

**Validation:**
```bash
# Check spine connections still use /31
sudo docker exec spectrum-x-rcp grep -A3 'peer_role == "spine"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```
**Expected:** Shows `port.subnet = "31"` (fixed)

### Issue 4: Host IP Assignment Bug (.0 instead of .2)
**Original Problem:** Hosts were assigned network addresses (`.0`) instead of usable addresses (`.2`).

**Root Cause:** `_calculate_host_fourth_octet()` returned `base` instead of `base + 2`.

**Solution:** Fixed calculation to return correct offset:
- `/31`: host at `.0`, switch at `.1` (point-to-point)
- `/30` and `/29`: host at `.2`, switch at `.1`

**Validation:**
```bash
# Check the critical fix is present
sudo docker exec spectrum-x-rcp grep -A5 "_calculate_host_fourth_octet" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep "return base"
```
**Expected:** Shows `return base + 2` for non-/31 case

### Issue 5: Rail Assignment Bug
**Original Problem:** Patched version assigned NICs incorrectly to switches:
- **Broken:** All 4 NICs of hosts 1-2 → switch 0, hosts 3-4 → switch 1
- **Correct:** 2 NICs per host per switch (rail-optimized)

**Root Cause:** Topology parsing or custom topology file not matching actual wiring.

**Solution:** Ensure topology file matches actual AIR physical connections. Use LLDP discovery and MAC address mapping.

**Validation:**
```bash
# Verify rail assignment in generated configs
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml | grep -E "swp[1-4]s[0-1]:" | head -8

# Should show connections from ALL 4 hosts (not just 2)
# swp1s0, swp1s1 → h00
# swp2s0, swp2s1 → h01
# swp3s0, swp3s1 → h02
# swp4s0, swp4s1 → h03
```

### Issue 6: Missing netplan_spectrum-x.sh Script
**Original Problem:** RCP V2.0.0-GA container missing `netplan_spectrum-x.sh` script.

**Solution:** Create symlink to `linux_spectrum-x.sh`:
```bash
sudo docker exec spectrum-x-rcp ln -sf \
  /usr/local/lib/python3.12/dist-packages/spcx_core/host/linux_spectrum-x.sh \
  /usr/local/lib/python3.12/dist-packages/spcx_core/host/netplan_spectrum-x.sh

sudo docker exec spectrum-x-rcp ln -sf \
  /usr/local/lib/python3.12/dist-packages/spcx_core/host/linux_networkd_spectrum-x.sh \
  /usr/local/lib/python3.12/dist-packages/spcx_core/host/netplan_networkd_spectrum-x.sh
```

---

## Complete Validation Test Suite

### Test 1: Patch Installation Verification

```bash
echo "=== Test 1: Patch Installation ==="

# Check ipv4am.py
COUNT=$(sudo docker exec spectrum-x-rcp grep -c '_get_subnet_config' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py 2>/dev/null || echo 0)
[ "$COUNT" -ge 4 ] && echo "✅ ipv4am.py: PASS ($COUNT references)" || echo "❌ ipv4am.py: FAIL"

# Check system_config.py
COUNT=$(sudo docker exec spectrum-x-rcp grep -c '_set_host_subnet_size' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/config/system_config.py 2>/dev/null || echo 0)
[ "$COUNT" -ge 2 ] && echo "✅ system_config.py: PASS" || echo "❌ system_config.py: FAIL"

# Check nodes_info_builder.py
COUNT=$(sudo docker exec spectrum-x-rcp grep -c 'getattr.*subnet' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py 2>/dev/null || echo 0)
[ "$COUNT" -ge 1 ] && echo "✅ nodes_info_builder.py: PASS" || echo "❌ nodes_info_builder.py: FAIL"

# Check leaf_yaml.j2
COUNT=$(sudo docker exec spectrum-x-rcp grep -c 'port_info\["subnet"\]' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2 2>/dev/null || echo 0)
[ "$COUNT" -ge 1 ] && echo "✅ leaf_yaml.j2: PASS" || echo "❌ leaf_yaml.j2: FAIL"

# Check critical IP offset fix
FIX=$(sudo docker exec spectrum-x-rcp grep "return base + 2" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py 2>/dev/null || echo "")
[ -n "$FIX" ] && echo "✅ IP offset fix: PASS" || echo "❌ IP offset fix: FAIL (hosts will get .0)"
```

### Test 2: Subnet Configuration Logic

```bash
echo "=== Test 2: Subnet Configuration ==="

sudo docker exec spectrum-x-rcp python3 << 'EOF'
from spcx_core.configurator.ipv4am import IPv4AM

subnet_size, addresses_per_block = IPv4AM._get_subnet_config()
print(f"Configured subnet: /{subnet_size}")
print(f"Addresses per block: {addresses_per_block}")

# Verify calculation
expected = 2 ** (32 - subnet_size)
if addresses_per_block == expected:
    print("✅ Calculation: PASS")
else:
    print(f"❌ Calculation: FAIL (expected {expected}, got {addresses_per_block})")

# Test IP allocation for 4 hosts
print("\nIP Allocation Pattern:")
for i in range(4):
    fourth_octet = IPv4AM._calculate_host_fourth_octet(i, addresses_per_block)
    base = i * addresses_per_block
    print(f"  Host {i}: .{fourth_octet} (block {base}-{base+addresses_per_block-1})")
EOF
```

### Test 3: Switch Subnet Behavior

```bash
echo "=== Test 3: Switch Subnet Behavior ==="

# Host-facing ports should use configurable subnet
HOST_DYNAMIC=$(sudo docker exec spectrum-x-rcp grep -A3 'peer_role == "host"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -c 'subnet_size' || echo 0)
[ "$HOST_DYNAMIC" -ge 1 ] && echo "✅ Leaf-to-Host: Configurable subnet" || echo "❌ Leaf-to-Host: Still hardcoded"

# Spine-facing ports should use /31
SPINE_31=$(sudo docker exec spectrum-x-rcp grep -A2 'peer_role == "spine"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -c '"31"' || echo 0)
[ "$SPINE_31" -ge 1 ] && echo "✅ Leaf-to-Spine: Fixed /31" || echo "❌ Leaf-to-Spine: Not /31"
```

### Test 4: Gateway Connectivity (Requires Running Simulation)

```bash
echo "=== Test 4: Gateway Ping Test ==="

# SSH to OOB server and run this on hosts
for host in hgx-su00-h00 hgx-su00-h01 hgx-su00-h02 hgx-su00-h03; do
    echo "--- $host ---"
    sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@$host '
        for eth in eth1 eth2; do
            ip=$(ip -4 addr show $eth 2>/dev/null | grep -oP "(?<=inet )\d+\.\d+\.\d+\.\d+")
            # Calculate gateway (.1 in same block)
            gw=$(echo $ip | sed "s/\.[0-9]*$//" | xargs -I{} echo "{}.1")
            if [ -n "$ip" ]; then
                ping -c 1 -W 2 $gw -I $eth >/dev/null 2>&1 && echo "$eth: $ip -> $gw ✅" || echo "$eth: $ip -> $gw ❌"
            fi
        done
    ' 2>/dev/null || echo "Could not connect to $host"
done
```

### Test 5: Cross-Host Connectivity

```bash
echo "=== Test 5: Cross-Host Ping Test ==="

# From h00, ping all other hosts
sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@hgx-su00-h00 '
    for target_ip in 172.16.0.10 172.16.0.18 172.16.0.26; do
        ping -c 1 -W 2 $target_ip -I eth1 >/dev/null 2>&1 && echo "-> $target_ip ✅" || echo "-> $target_ip ❌"
    done
' 2>/dev/null
```

---

## IP Allocation Verification

### Expected IP Layout for /29 (8 addresses per block)

| Host | eth1 IP | eth1 Gateway | eth2 IP | eth2 Gateway |
|------|---------|--------------|---------|--------------|
| h00 | 172.16.0.2/29 | 172.16.0.1 | 172.18.0.2/29 | 172.18.0.1 |
| h01 | 172.16.0.10/29 | 172.16.0.9 | 172.18.0.10/29 | 172.18.0.9 |
| h02 | 172.16.0.18/29 | 172.16.0.17 | 172.18.0.18/29 | 172.18.0.17 |
| h03 | 172.16.0.26/29 | 172.16.0.25 | 172.18.0.26/29 | 172.18.0.25 |

**Key Points:**
- Host IP at `.2` position (not `.0` which is network address)
- Gateway at `.1` position
- Addresses `.3-.6` available for pods (4 total)
- `.0` is network address (unusable)
- `.7` is broadcast address (unusable)

### Verify on Running Hosts

```bash
# Check actual assigned IPs
for host in hgx-su00-h00 hgx-su00-h01 hgx-su00-h02 hgx-su00-h03; do
    echo "=== $host ==="
    sshpass -p "nvidia" ssh -o StrictHostKeyChecking=no ubuntu@$host \
        "ip -4 addr show eth1 | grep inet; ip -4 addr show eth2 | grep inet" 2>/dev/null
done
```

---

## Rail Assignment Verification

### Expected Rail Configuration

With `leaf_rails: 2` configuration:
- **leaf-su00-r0** handles rail 0 (eth1, eth3 from all hosts)
- **leaf-su00-r1** handles rail 1 (eth2, eth4 from all hosts)

Each leaf should connect to **ALL** hosts, not a subset.

### Verify Rail Assignment

```bash
# Check switch config for leaf-su00-r0
echo "=== leaf-su00-r0 connections ==="
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r0.yaml 2>/dev/null | \
    grep -E "to_hgx-su00-h0[0-3]" | sort -u

# Should show ALL hosts: h00, h01, h02, h03
# NOT just h00 and h01

# Check leaf-su00-r1
echo "=== leaf-su00-r1 connections ==="
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/switch/out/leaf-su00-r1.yaml 2>/dev/null | \
    grep -E "to_hgx-su00-h0[0-3]" | sort -u

# Should also show ALL hosts
```

---

## Automated Validation Script

Save as `validate-all.sh`:

```bash
#!/bin/bash
# RCP CIDR Patch Complete Validation Suite

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ PASS:${NC} $1"; }
fail() { echo -e "${RED}❌ FAIL:${NC} $1"; exit 1; }

echo "============================================"
echo "  RCP CIDR Patch Validation Suite"
echo "============================================"
echo

# Test 1: Patch files
echo "[1/6] Checking patch installation..."
docker exec spectrum-x-rcp grep -q '_get_subnet_config' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py && \
  pass "ipv4am.py patched" || fail "ipv4am.py not patched"

docker exec spectrum-x-rcp grep -q 'return base + 2' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py && \
  pass "IP offset fix present" || fail "IP offset fix missing"

# Test 2: Configuration
echo "[2/6] Checking configuration..."
SUBNET=$(docker exec spectrum-x-rcp python3 -c \
  'from spcx_core.config_manager import ConfigManager; print(ConfigManager().get("host_subnet_size"))' 2>/dev/null)
[ "$SUBNET" == "29" -o "$SUBNET" == "30" -o "$SUBNET" == "31" ] && \
  pass "host_subnet_size=$SUBNET" || fail "Invalid subnet size: $SUBNET"

# Test 3: Switch subnet behavior
echo "[3/6] Checking subnet behavior..."
docker exec spectrum-x-rcp grep -A3 'peer_role == "host"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -q 'subnet_size' && \
  pass "Host connections use configurable subnet" || fail "Host connections hardcoded"

docker exec spectrum-x-rcp grep -A2 'peer_role == "spine"' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py | grep -q '"31"' && \
  pass "Spine connections use /31" || fail "Spine connections not /31"

# Test 4: nodes_info_builder fix
echo "[4/6] Checking nodes_info_builder..."
docker exec spectrum-x-rcp grep -q 'getattr.*subnet' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/nodes_info_builder.py && \
  pass "getattr fix present" || fail "getattr fix missing"

# Test 5: leaf_yaml.j2 template
echo "[5/6] Checking leaf template..."
docker exec spectrum-x-rcp grep -q 'port_info\["subnet"\]' \
  /usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2 && \
  pass "Dynamic subnet in template" || fail "Template hardcoded"

# Test 6: netplan scripts
echo "[6/6] Checking netplan scripts..."
docker exec spectrum-x-rcp test -L \
  /usr/local/lib/python3.12/dist-packages/spcx_core/host/netplan_spectrum-x.sh && \
  pass "netplan_spectrum-x.sh exists" || echo "⚠️  netplan_spectrum-x.sh missing (create symlink)"

echo
echo "============================================"
echo "  All Core Validations Passed!"
echo "============================================"
```

---

## Troubleshooting

### Hosts Get .0 Instead of .2
The `_calculate_host_fourth_octet` function is missing the `+ 2` offset.
```bash
sudo docker exec spectrum-x-rcp grep -A10 "_calculate_host_fourth_octet" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/configurator/ipv4am.py
```
Fix: Ensure `return base + 2` is present for non-/31 case.

### Switch Configs Show /31 for Host Ports
The `leaf_yaml.j2` template is not updated.
```bash
sudo docker exec spectrum-x-rcp grep "subnet" \
  /usr/local/lib/python3.12/dist-packages/spcx_core/switch/cumulus/none/leaf_yaml.j2
```
Fix: Replace hardcoded `/31` with `{{ port_info["subnet"] }}`.

### Rail Assignment Wrong
Topology file doesn't match physical wiring.
```bash
# Check discovered vs configured topology
sudo docker exec spectrum-x-rcp cat /root/spectrum-x-rcp/topology/out/config_network.dot
```
Fix: Create custom topology file matching actual AIR wiring.

### Gateway Ping Fails
1. Check switch config applied: `nv config show` on switch
2. Check host netplan applied: `ip addr show eth1` on host
3. Verify ARP: `arp -n` on host

---

## Validation Results Summary (2026-01-20)

| Test | Status | Notes |
|------|--------|-------|
| Patch Installation | ✅ PASS | All 4 files applied |
| IP Offset Fix | ✅ PASS | `return base + 2` present |
| Host Subnet Configurable | ✅ PASS | Uses `host_subnet_size` |
| Spine Connections /31 | ✅ PASS | Fixed at /31 |
| Gateway Pings | ✅ PASS | 8/8 hosts×interfaces |
| Cross-Host Pings | ✅ PASS | 6/6 host pairs |

**Test Environment:**
- NVIDIA AIR Simulation ID: `15f71fff-1ea8-4c07-b943-5a9b366cea5a`
- RCP Version: V2.0.0-GA
- Configuration: `host_subnet_size: 29`
- Topology: 4 hosts, 2 leafs, 1 spine

---

## Changelog

### v2.0.0 (2026-01-20)
- Complete rewrite addressing all reported issues
- Added Issue tracking section
- Added IP offset fix validation
- Added rail assignment verification
- Added automated validation script
- Documented actual test results from AIR simulation

### v1.0.0 (2026-01-16)
- Initial validation guide
