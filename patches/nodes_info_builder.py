# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NvidiaProprietary
#
# NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
# property and proprietary rights in and to this material, related
# documentation and any modifications thereto. Any use, reproduction,
# disclosure or distribution of this material and related documentation
# without an express license agreement from NVIDIA CORPORATION or
# its affiliates is strictly prohibited.

from __future__ import annotations

from collections import defaultdict
from typing import TYPE_CHECKING, Dict

from . import config_utils
from .inventory import PortFactory

if TYPE_CHECKING:
    from .topology.base_topology import BaseTopology

IP_ADDRESS_FORMAT = "{}.{}.{}.{}"
LEVEL_2_IP_FORMAT = "10.254.{}.{}"
LEVEL_3_IP_FORMAT = "100.{}.{}.{}"


class NodesInfoBuilder:
    """Class for build nodes information."""

    @classmethod
    def build(cls, topology: BaseTopology) -> Dict[str, dict]:
        """
        Build map of nodes info per port.

        :param topology: Object of BaseTopology, contains nodes and their ports (Port objects).
        :return: Dictionary of {<node_name>: {"ports": {<port>: {"role": "host", ...}}}}
        """
        config = topology.config
        overlay = config.get("overlay")
        num_of_su = config.get("pod_size")
        num_of_pod = config.get("pod_num")
        topology_type = config.get("topology")
        host_interfaces = config.get("host_interfaces")
        num_of_rails_group = config.get("num_of_rails_group")
        num_of_planes = config.get("planes_num", 1)
        rails = config_utils.get_rails(config.get("leaf_rails"))
        nodes_info = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(dict))))
        for host_name, host in topology.hosts.items():
            pod_index = host.pod_index if host.pod_index is not None else "XX"
            for rail_group_index, rail_group in enumerate(rails):
                for rail_index in rail_group:
                    for plane_index in range(num_of_planes):
                        # hosts --> leaf
                        interface_index = (rail_index * num_of_planes) + plane_index
                        if interface_index >= len(host_interfaces):
                            break
                        nic_name = host_interfaces[interface_index]
                        if nic_name not in host.ports:
                            continue
                        host_port = host.ports[nic_name]
                        leaf_port = host_port.peer_port
                        leaf_port_name = host_port.peer_port.name
                        nodes_info[host_name]["ports"][nic_name]["traffic_direction"] = "east-west"
                        nodes_info[host_name]["ports"][nic_name]["ip_address"] = host_port.ip_address
                        nodes_info[host_name]["ports"][nic_name]["peer_node"] = leaf_port.node.name
                        nodes_info[host_name]["ports"][nic_name]["peer_port"] = leaf_port_name
                        nodes_info[host_name]["ports"][nic_name]["peer_role"] = host_port.peer_port.node.role
                        nodes_info[host_name]["ports"][nic_name]["peer_ip_address"] = leaf_port.ip_address
                        nodes_info[host_name]["ports"][nic_name]["rail_subnet"] = host_port.rail_subnet
                        nodes_info[host_name]["ports"][nic_name]["subnet"] = host_port.subnet
                        nodes_info[host_name]["ports"][nic_name]["pod"] = pod_index
                        nodes_info[host_name]["ports"][nic_name]["su"] = host.su_index
                        nodes_info[host_name]["ports"][nic_name]["rail"] = host.ports[nic_name].rail_index
                        nodes_info[host_name]["ports"][nic_name]["host"] = host.index_in_su
                        nodes_info[host_name]["ports"][nic_name]["rail_group_index"] = rail_group_index
                        nodes_info[host_name]["ports"][nic_name]["role"] = host_port.node.role
                        nodes_info[host_name]["ports"][nic_name]["plane"] = host_port.plane_index

                        # leaf --> host
                        leaf = leaf_port.node
                        leaf_name = leaf.name
                        nodes_info[leaf_name]["ports"][leaf_port_name]["ip_address"] = leaf_port.ip_address
                        nodes_info[leaf_name]["ports"][leaf_port_name]["peer_node"] = host_name
                        nodes_info[leaf_name]["ports"][leaf_port_name]["peer_port"] = nic_name
                        nodes_info[leaf_name]["ports"][leaf_port_name]["peer_role"] = host.role
                        nodes_info[leaf_name]["ports"][leaf_port_name]["peer_ip_address"] = host_port.ip_address
                        nodes_info[leaf_name]["ports"][leaf_port_name]["link_type"] = leaf_port.direction
                        nodes_info[leaf_name]["ports"][leaf_port_name]["role"] = leaf.role
                        nodes_info[leaf_name]["ports"][leaf_port_name]["rail_group_index"] = leaf.rail_group_index
                        nodes_info[leaf_name]["ports"][leaf_port_name]["su"] = host.su_index
                        nodes_info[leaf_name]["ports"][leaf_port_name]["pod"] = pod_index
                        nodes_info[leaf_name]["ports"][leaf_port_name]["plane"] = leaf_port.plane_index
                        nodes_info[leaf_name]["ports"][leaf_port_name]["subnet"] = leaf_port.subnet

        for spine_name, spine in topology.spines.items():
            pod_index = spine.pod_index if spine.pod_index is not None else "XX"
            for port_index in range(config.get("spine_max_ports")):
                switch_port_class = PortFactory.get_port_cls(config.get("switch_nos"))
                port_name = switch_port_class.port_index_to_name(port_index)
                if port_name in spine.ports:
                    # spine --> leaf
                    spine_port = spine.ports[port_name]
                    peer_port = spine_port.peer_port
                    # skip port which connect spine to super spine
                    if peer_port.node.name not in topology.leafs:
                        break
                    leaf_port = peer_port
                    leaf = leaf_port.node
                    # 10.254.<spine index in pod>
                    nodes_info[spine_name]["ports"][port_name]["ip_address"] = spine_port.ip_address
                    nodes_info[spine_name]["ports"][port_name]["peer_node"] = leaf.name
                    nodes_info[spine_name]["ports"][port_name]["peer_port"] = leaf_port.name
                    nodes_info[spine_name]["ports"][port_name]["peer_role"] = leaf.role
                    nodes_info[spine_name]["ports"][port_name]["peer_ip_address"] = leaf_port.ip_address
                    nodes_info[spine_name]["ports"][port_name]["rail_group_index"] = leaf.rail_group_index
                    nodes_info[spine_name]["ports"][port_name]["link_type"] = spine_port.direction
                    nodes_info[spine_name]["ports"][port_name]["role"] = spine.role
                    nodes_info[spine_name]["ports"][port_name]["su"] = leaf.su_index
                    nodes_info[spine_name]["ports"][port_name]["pod"] = pod_index
                    nodes_info[spine_name]["ports"][port_name]["plane"] = spine_port.plane_index

                    # leaf --> spine
                    leaf_name = leaf.name
                    leaf_port_name = leaf_port.name
                    nodes_info[leaf_name]["ports"][leaf_port_name]["ip_address"] = leaf_port.ip_address
                    nodes_info[leaf_name]["ports"][leaf_port_name]["peer_node"] = spine_name
                    nodes_info[leaf_name]["ports"][leaf_port_name]["peer_port"] = port_name
                    nodes_info[leaf_name]["ports"][leaf_port_name]["peer_role"] = spine.role
                    nodes_info[leaf_name]["ports"][leaf_port_name]["peer_ip_address"] = spine_port.ip_address
                    nodes_info[leaf_name]["ports"][leaf_port_name]["link_type"] = leaf_port.direction
                    nodes_info[leaf_name]["ports"][leaf_port_name]["role"] = leaf.role
                    nodes_info[leaf_name]["ports"][leaf_port_name]["pod"] = pod_index
                    nodes_info[leaf_name]["ports"][leaf_port_name]["su"] = leaf.su_index
                    nodes_info[leaf_name]["ports"][leaf_port_name]["rail_group_index"] = leaf.rail_group_index
                    nodes_info[leaf_name]["ports"][leaf_port_name]["plane"] = leaf_port.plane_index

        if topology_type == "3-tier":
            if overlay == "l3evpn":
                sspine_group_num = len(topology.spines) // num_of_rails_group // num_of_pod
                sspine_group_size = len(topology.sspines) // sspine_group_num

            for sspine_name in topology.sspines:
                for port_index in range(config.get("ssp_max_ports")):
                    # super spine --> spine
                    switch_port_class = PortFactory.get_port_cls(config.get("switch_nos"))
                    port_name = switch_port_class.port_index_to_name(port_index)
                    sspine = topology.sspines[sspine_name]
                    if port_name not in sspine.ports:
                        continue

                    sspine_port = sspine.ports[port_name]
                    spine_port = sspine_port.peer_port
                    spine = spine_port.node
                    pod_index = spine.pod_index if spine.pod_index is not None else "XX"
                    nodes_info[sspine_name]["ports"][port_name] = {}
                    nodes_info[sspine_name]["ports"][port_name]["ip_address"] = sspine_port.ip_address
                    nodes_info[sspine_name]["ports"][port_name]["peer_node"] = spine.name
                    nodes_info[sspine_name]["ports"][port_name]["peer_port"] = spine_port.name
                    nodes_info[sspine_name]["ports"][port_name]["peer_role"] = spine.role
                    nodes_info[sspine_name]["ports"][port_name]["peer_ip_address"] = spine_port.ip_address
                    nodes_info[sspine_name]["ports"][port_name]["role"] = "sspine"
                    nodes_info[sspine_name]["ports"][port_name]["pod"] = pod_index
                    nodes_info[sspine_name]["ports"][port_name]["link_type"] = sspine_port.direction
                    nodes_info[sspine_name]["ports"][port_name]["rail_group_index"] = spine.rail_group_index
                    nodes_info[sspine_name]["ports"][port_name]["plane"] = sspine_port.plane_index

                    # spine --> super spine
                    spine_name = spine.name
                    spine_port_name = spine_port.name
                    nodes_info[spine_name]["ports"][spine_port_name]["ip_address"] = spine_port.ip_address
                    nodes_info[spine_name]["ports"][spine_port_name]["peer_node"] = sspine_name
                    nodes_info[spine_name]["ports"][spine_port_name]["peer_port"] = port_name
                    nodes_info[spine_name]["ports"][spine_port_name]["peer_role"] = "sspine"
                    nodes_info[spine_name]["ports"][spine_port_name]["peer_ip_address"] = sspine_port.ip_address
                    nodes_info[spine_name]["ports"][spine_port_name]["role"] = spine.role
                    nodes_info[spine_name]["ports"][spine_port_name]["pod"] = pod_index
                    nodes_info[spine_name]["ports"][spine_port_name]["link_type"] = spine_port.direction
                    nodes_info[spine_name]["ports"][spine_port_name]["rail_group_index"] = spine.rail_group_index
                    nodes_info[spine_name]["ports"][spine_port_name]["plane"] = spine_port.plane_index

        # set ASN for leaf row and loopback ip address

        # currently each 2 row belong to the same 4 of leaf row switches
        for leaf_index, leaf in enumerate(topology.leafs.values()):  # noqa: B007
            leaf_name = leaf.name
            if leaf_name not in nodes_info:
                continue
            nodes_info[leaf_name]["asn"] = leaf.asn
            nodes_info[leaf_name]["loopback_ip"] = leaf.loopback_ip
            nodes_info[leaf_name]["loopback_ipv6_ip"] = leaf.loopback_ipv6_ip
            nodes_info[leaf_name]["rail_subnets"] = leaf.rail_subnets
            nodes_info[leaf_name]["switch_index"] = leaf.index

            if overlay == "l3evpn":
                evpn_rs = []
                for ssp_index, ssp in enumerate(topology.sspines):
                    # add 2 super spine per group to evpn_rs when we have one super spine group
                    # add 1 super spine per group to evpn_rs when we have more than one super spine group
                    if ssp_index % sspine_group_size == 0:
                        evpn_rs.append(ssp)
                    if num_of_su == 1 and ssp_index % sspine_group_size == 1:
                        evpn_rs.append(ssp)
                nodes_info[leaf_name]["evpn_rs"] = evpn_rs

        # set ASN and loopback ip for spine
        for spine in topology.spines.values():
            spine_name = spine.name
            if spine_name not in nodes_info:
                continue
            nodes_info[spine_name]["asn"] = spine.asn
            nodes_info[spine_name]["loopback_ip"] = spine.loopback_ip
            nodes_info[spine_name]["loopback_ipv6_ip"] = spine.loopback_ipv6_ip
            nodes_info[spine_name]["switch_index"] = spine.index

        if topology_type == "3-tier":
            # set ASN and loopback ip for super spine
            for sspine in topology.sspines.values():
                sspine_name = sspine.name
                if sspine_name not in nodes_info:
                    continue
                nodes_info[sspine_name]["asn"] = sspine.asn
                nodes_info[sspine_name]["loopback_ip"] = sspine.loopback_ip
                nodes_info[sspine_name]["loopback_ipv6_ip"] = sspine.loopback_ipv6_ip
                nodes_info[sspine_name]["switch_index"] = sspine.index
        return nodes_info
