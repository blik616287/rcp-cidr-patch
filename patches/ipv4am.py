# SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NvidiaProprietary
#
# NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
# property and proprietary rights in and to this material, related
# documentation and any modifications thereto. Any use, reproduction,
# disclosure or distribution of this material and related documentation
# without an express license agreement from NVIDIA CORPORATION or
# its affiliates is strictly prohibited.

# MODIFIED: Added configurable host_subnet_size support
# Original hardcoded /31 subnets, now supports /29, /30, /31

from __future__ import annotations

import ipaddress
from typing import TYPE_CHECKING

from .. import config_utils
from ..config_manager import ConfigManager
from .ipam import IPAM

if TYPE_CHECKING:
    from ..inventory import Leaf, Port, Switch


class IPv4AM(IPAM):
    """Base class for IPv4 address management."""

    MAX_NUMS_IN_OCTET = 256
    IP_ADDRESS_FORMAT: str = "{}.{}.{}.{}"
    LEVEL_2_IP_FORMAT: str = "10.254.{}.{}"
    LEVEL_3_IP_FORMAT: str = "100.{}.{}.{}"

    # MODIFIED: Added subnet size configuration helpers
    @classmethod
    def _get_subnet_config(cls) -> tuple[int, int]:
        """
        Get subnet size and calculate addresses per subnet block.

        Returns:
            tuple: (subnet_size, addresses_per_block)
            - subnet_size: The CIDR prefix length (29, 30, or 31)
            - addresses_per_block: Number of addresses per subnet (8, 4, or 2)
        """
        config_manager = ConfigManager()
        subnet_size = config_manager.get("host_subnet_size", 31)
        addresses_per_block = 2 ** (32 - subnet_size)
        return subnet_size, addresses_per_block

    @classmethod
    def _calculate_host_fourth_octet(cls, index_in_su: int, addresses_per_block: int) -> int:
        """
        Calculate the fourth octet for a host IP address.

        For each subnet block:
        - /31: 2 addresses (0=host, 1=switch)
        - /30: 4 addresses (0=network, 1=host, 2=switch, 3=broadcast)
               But we use: 0=host_base, 1=switch, 2-3=extra host IPs
        - /29: 8 addresses (0=host_base, 1=switch, 2-7=extra host IPs)

        Args:
            index_in_su: The host's index within the SU (0, 1, 2, ...)
            addresses_per_block: Number of addresses per subnet block

        Returns:
            The fourth octet value for the host's base IP
        """
        # Each host gets a block of addresses; host base IP is at start of block
        return index_in_su * addresses_per_block

    @classmethod
    def set_host_ip(cls, port: Port) -> None:
        """Allocate ip address and rail_subnet to host's port."""
        config_manager = ConfigManager()
        system_type = config_manager.get("system_type")
        first_octet = config_manager.get("host_first_octet")

        # MODIFIED: Get configurable subnet size
        subnet_size, addresses_per_block = cls._get_subnet_config()

        if "gb" in system_type:
            second_octet = (1 << 4) + (port.plane_index << 2) + (port.rail_index // 4)
            third_octet = ((port.rail_index % 4) << 6) + port.node.su_index
            rail_subnet_third_octet = third_octet & 0b11000000
            rail_mask = "/18"
            port.rail_subnet = cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, rail_subnet_third_octet, 0) + rail_mask
        else:
            second_octet = (1 << 4) + (port.rail_index << 1)
            third_octet = port.node.su_index
            rail_subnet_second_octet = second_octet & 0b11111110
            rail_mask = "/15"
            port.rail_subnet = cls.IP_ADDRESS_FORMAT.format(first_octet, rail_subnet_second_octet, 0, 0) + rail_mask

        # MODIFIED: Use configurable subnet size for fourth octet calculation
        fourth_octet = cls._calculate_host_fourth_octet(port.node.index_in_su, addresses_per_block)

        # MODIFIED: Use configurable subnet size instead of hardcoded "31"
        port.subnet = str(subnet_size)
        port.ip_address = cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, fourth_octet)

    @classmethod
    def set_leaf_ip(cls, port: Port) -> None:
        """Allocate ip address to leaf's port."""
        peer_port_ip_address = port.peer_port.ip_address

        if peer_port_ip_address is None:
            err_msg = "ERROR: Peer port is None."
            raise RuntimeError(err_msg)

        peer_role = port.peer_port.node.role

        if peer_role == "host":
            # MODIFIED: Switch gets IP at offset 1 within the host's subnet block
            # This works for all subnet sizes: host=.0, switch=.1, extra=.2+
            port_ip_address = cls.modify_last_octet(peer_port_ip_address, 1)
            port.ip_address = port_ip_address

        elif peer_role == "spine":
            port_ip_address = cls.modify_last_octet(peer_port_ip_address, -1)
            port.ip_address = port_ip_address

    @classmethod
    def set_spine_ip(cls, port: Port, ip_index: int) -> None:
        """Allocate ip to spine's ports and to its peer port."""
        peer_role = port.peer_port.node.role

        if peer_role == "leaf":
            port.ip_address = cls.LEVEL_2_IP_FORMAT.format(port.node.index_in_pod, ip_index + 1)

        elif peer_role == "super_spine":
            peer_port_ip_address = port.peer_port.ip_address
            if peer_port_ip_address is None:
                err_msg = "ERROR: Peer port is None."
                raise RuntimeError(err_msg)
            port_ip_address = cls.modify_last_octet(peer_port_ip_address, -1)
            port.ip_address = port_ip_address

    @classmethod
    def set_leaf_rail_subnets(cls, leaf: Leaf) -> None:
        """Build rails subnets to leaf."""
        config_manager = ConfigManager()
        first_octet = config_manager.get("host_first_octet")
        leaf_rails = config_manager.get("leaf_rails")

        if "gb" in config_manager.get("system_type"):
            rail_subnets = []
            for rail in leaf.rail_group:
                second_octet = (1 << 4) + (leaf.plane_index << 2) + (rail // 4)
                third_octet = ((rail % 4) << 6) + leaf.su_index
                rail_subnets.append(
                    cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, 0)
                    + config_utils.get_bgp_summary_subnet(leaf_rails))
        else:
            third_octet = leaf.su_index
            rail_subnets = []
            for rail in leaf.rail_group:
                second_octet = (1 << 4) + (rail << 1)
                rail_subnets.append(
                    cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, 0)
                    + config_utils.get_bgp_summary_subnet(leaf_rails))

        leaf.rail_subnets = rail_subnets

    @classmethod
    def modify_last_octet(cls, peer_port_ip_address: str, sign: int) -> str:
        """
        Add/Substitute 1 from the last octet according to 'sign' value.

        :param peer_port_ip_address: ip address of the peer port.
        :param sign: 1 for addition and -1 for subtraction.
        :return: modified ip address.
        """
        peer_port_ip_address = peer_port_ip_address.split(".")
        last_octet = int(peer_port_ip_address[-1]) + sign
        peer_port_ip_address[-1] = str(last_octet)
        return ".".join(peer_port_ip_address)


class IPv4AM3TierTopology(IPv4AM):
    """IP allocator for 3-tier topology."""

    @classmethod
    def set_host_ip(cls, port: Port) -> None:
        """Allocate ip address and rail_subnet to host's port."""
        config_manager = ConfigManager()
        system_type = config_manager.get("system_type")
        first_octet = config_manager.get("host_first_octet")

        # MODIFIED: Get configurable subnet size
        subnet_size, addresses_per_block = cls._get_subnet_config()

        if "gb" in system_type:
            second_octet = (port.plane_index << 6) + (port.rail_index << 3) + (port.node.pod_index // 4)
            third_octet = ((port.node.pod_index % 4) << 6) + port.node.su_index
            rail_subnet_second_octet = second_octet & 0b11111000
            rail_mask = "/13"
        else:
            second_octet = (port.rail_index << 5) + (port.node.pod_index or 0)
            third_octet = port.node.su_index
            rail_subnet_second_octet = second_octet & 0b11100000
            rail_mask = "/11"

        # MODIFIED: Use configurable subnet size for fourth octet calculation
        fourth_octet = cls._calculate_host_fourth_octet(port.node.index_in_su, addresses_per_block)
        rail_subnet_second_octet = (port.rail_index << 5)

        # MODIFIED: Use configurable subnet size instead of hardcoded "31"
        port.subnet = str(subnet_size)
        port.ip_address = cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, fourth_octet)
        port.rail_subnet = cls.IP_ADDRESS_FORMAT.format(first_octet, rail_subnet_second_octet, 0, 0) + rail_mask

    @classmethod
    def set_leaf_ip(cls, port: Port) -> None:
        """Allocate ip address to leaf's port."""
        super().set_leaf_ip(port)

    @classmethod
    def set_spine_ip(cls, port: Port, ip_index: int) -> None:
        """Allocate ip to spine's ports."""
        super().set_spine_ip(port, ip_index)

    @classmethod
    def set_sspine_ip(cls, port: Port, sspine_group_index: int, sspine_index_in_group: int,
                      ip_start_index: int) -> None:
        """Allocate ip address to super-spine's port."""
        config = ConfigManager()
        third_octet = sspine_index_in_group
        if "gb" in config.get("system_type"):
            second_octet = (1 << 6) + sspine_group_index
            third_octet = (sspine_index_in_group << 2) + (ip_start_index >> 8)
            fourth_octet = (ip_start_index % cls.MAX_NUMS_IN_OCTET) + 1
        else:
            second_octet = sspine_group_index
            third_octet = sspine_index_in_group
            fourth_octet = ip_start_index + 1

        port.ip_address = cls.LEVEL_3_IP_FORMAT.format(second_octet, third_octet, fourth_octet)

    @classmethod
    def set_leaf_rail_subnets(cls, leaf: Leaf) -> None:
        """Build rails subnets to leaf."""
        config_manager = ConfigManager()
        first_octet = config_manager.get("host_first_octet")
        leaf_rails = config_manager.get("leaf_rails")

        if "gb" in config_manager.get("system_type"):
            third_octet = ((leaf.pod_index % 4) << 6) + leaf.su_index

            rail_subnets = []
            for rail in leaf.rail_group:
                second_octet = (leaf.plane_index << 6) + (rail << 3) + (leaf.pod_index // 4)
                rail_subnets.append(
                    cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, 0)
                    + config_utils.get_bgp_summary_subnet(leaf_rails))
        else:
            third_octet = leaf.su_index

            rail_subnets = []
            for rail in leaf.rail_group:
                second_octet = (rail << 5) + leaf.pod_index
                rail_subnets.append(
                    cls.IP_ADDRESS_FORMAT.format(first_octet, second_octet, third_octet, 0)
                    + config_utils.get_bgp_summary_subnet(leaf_rails))

        leaf.rail_subnets = rail_subnets


class IPv4AM2TierTopology(IPv4AM):
    """IP allocator for 2-tier topology."""

    @classmethod
    def set_host_ip(cls, port: Port) -> None:
        """Allocate ip address and rail_subnet to host's port."""
        super().set_host_ip(port)

    @classmethod
    def set_leaf_ip(cls, port: Port) -> None:
        """Allocate ip address to leaf's port."""
        super().set_leaf_ip(port)

    @classmethod
    def set_spine_ip(cls, port: Port, ip_index: int) -> None:
        """Allocate ip to spine's ports."""
        super().set_spine_ip(port, ip_index)


class IPv4AM2TierPOCTopology(IPv4AM):
    """IP allocator for 2-tier-poc topology."""

    @classmethod
    def set_host_ip(cls, port: Port) -> None:
        """Allocate ip address and rail_subnet to host's port."""
        super().set_host_ip(port)

    @classmethod
    def set_leaf_ip(cls, port: Port) -> None:
        """Allocate ip address to leaf's port."""
        super().set_leaf_ip(port)

    @classmethod
    def set_spine_ip(cls, port: Port, ip_index: int) -> None:
        """Allocate ip to spine's ports."""
        super().set_spine_ip(port, ip_index)


class IPv4LoopBackIP:
    """Loopback ip allocator."""

    @classmethod
    def set_loopback_ip(cls, switch: Switch, loopback_index: int) -> None:
        """Set loopback ip address."""
        loopback_range = list(ipaddress.ip_network("10.253.128.0/18").hosts())
        switch.loopback_ip = format(loopback_range[loopback_index])
