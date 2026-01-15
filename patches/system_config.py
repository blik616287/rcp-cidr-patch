# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NvidiaProprietary
#
# NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
# property and proprietary rights in and to this material, related
# documentation and any modifications thereto. Any use, reproduction,
# disclosure or distribution of this material and related documentation
# without an express license agreement from NVIDIA CORPORATION or
# its affiliates is strictly prohibited.

# MODIFIED: Added host_subnet_size validation and default value

import logging
import os
import sys
from typing import ClassVar

from spcx_core import utils

logger = logging.getLogger("system_config")


class BaseSystemConfig:
    """Class for validate and calculate topology's config params."""

    REQUIRED_PARAMETERS: ClassVar = [
        "pod_size",
        "pod_num",
        "host_first_octet",
        "overlay",
        "topology",
        "leaf_rails",
        "system_type",
        "hca_type",
        "telemetry_histogram",
        "cable_validator",
        "telemetry_dts_host_enable",
    ]
    REQUIRED_SPECIFIC_PARAMETERS: ClassVar = []
    SUPPORTED_VALUES = {
        "topology": ["2-tier", "3-tier", "2-tier-poc", "2-tier-custom"],
        # MODIFIED: Added host_subnet_size validation
        "host_subnet_size": [29, 30, 31],
    }
    SPECIFIC_SUPPORTED_VALUES: ClassVar = {}

    def __init__(self, config: dict, *, bcm_mode: bool = False) -> None:
        """Initialize BaseSystemConfig."""
        self._config = config
        self._bcm_mode = bcm_mode

    def _get_required_parameters(self) -> list:
        """Get the required parameters for the config."""
        return self.__class__.REQUIRED_PARAMETERS + self.__class__.REQUIRED_SPECIFIC_PARAMETERS

    def _get_supported_values(self) -> dict:
        """Get a dictionary of {config key: list of supported values}."""
        return self.__class__.SUPPORTED_VALUES | self.__class__.SPECIFIC_SUPPORTED_VALUES

    def verify_config_value(self, key: str, supported_values: list) -> None:
        """
        Validate that a given configuration value is supported.

        :param key: The name of the configuration parameter being validated.
        :param supported_values: A list of valid values for the configuration parameter.
        """
        value = self._config.get(key)
        # MODIFIED: Skip validation if value not provided (will use default)
        if value is None:
            return
        if value not in supported_values:
            logger.error(f"Unsupported value {value} for key {key}. Supported values: {supported_values}.")
            sys.exit(1)

    def validate_config(self) -> None:
        """Verify the configuration that the required parameters exist and correct values."""
        self._verify_required_params()
        self._verify_custom_topology_supported()
        self._verify_supported_values()
        self._verify_host_first_octet()
        self._verify_interfaces_params()
        self._verify_rail_to_pci_mapping()
        self.verify_telemetry_otlp_dest()
        self._verify_firmware_url()
        # MODIFIED: Validate host_subnet_size
        self._verify_host_subnet_size()

    def update_config(self) -> None:
        """Update the config parameters and to add new config parameters."""
        # MODIFIED: Set default host_subnet_size if not provided
        self._set_host_subnet_size()
        # Set defaults early - these are needed by other methods
        self._set_switch_breakout()
        self._set_cx_card_breakout()
        self._set_switch_nos()
        # Now proceed with other initialization
        self._set_host_interfaces()
        self._set_host_nics_interfaces()
        self._set_dms_servers_ports_params()
        self._set_num_of_rails_group()
        self._set_switch_max_ports()
        self._set_max_host_in_su()
        self._set_validation_data_parameters()
        self._set_packages_files_names()
        self._set_ports_rename_recipe()
        self._set_system_type()

    # MODIFIED: Added method to set default host_subnet_size
    def _set_host_subnet_size(self) -> None:
        """Set default host_subnet_size if not provided."""
        if "host_subnet_size" not in self._config:
            self._config["host_subnet_size"] = 31

    # MODIFIED: Added method to validate host_subnet_size
    def _verify_host_subnet_size(self) -> None:
        """Verify host_subnet_size value if provided."""
        subnet_size = self._config.get("host_subnet_size")
        if subnet_size is not None and subnet_size not in [29, 30, 31]:
            logger.error(f"Invalid host_subnet_size: {subnet_size}. Supported values: 29, 30, 31")
            sys.exit(1)

    def _set_switch_max_ports(self) -> None:
        """Set max_ports and max_downlinks parameters for switches."""
        # spine & sspine
        switch_max_ports = utils.SWITCH_PHYSICAL_PORTS * self._config["switch_breakout"]
        self._config["spine_max_ports"] = switch_max_ports
        self._config["spine_max_downlinks"] = switch_max_ports // 2
        if self._config["topology"] == "3-tier":
            self._config["ssp_max_ports"] = self._config["ssp_max_downlinks"] = switch_max_ports

        # leaf
        leaf_max_downlinks = (utils.SWITCH_PHYSICAL_PORTS // 2) * self._config["leaf_downlinks_breakout"]
        leaf_max_uplinks = (utils.SWITCH_PHYSICAL_PORTS // 2) * self._config["switch_breakout"]
        self._config["leaf_max_ports"] = leaf_max_downlinks + leaf_max_uplinks
        self._config["leaf_max_downlinks"] = leaf_max_downlinks

    def _set_host_interfaces(self) -> None:
        """Set the 'host_interfaces' in the config."""
        err_msg = f"Function _set_host_interfaces is not implemented in class {self.__class__.__name__}."
        raise NotImplementedError(err_msg)

    def _set_host_nics_interfaces(self) -> None:
        """Set list of host interfaces, contains single interface per network card."""
        host_interfaces = self._config["host_interfaces"]
        cx_card_breakout = self._config.get("cx_card_breakout", 1)
        if len(host_interfaces) % cx_card_breakout != 0:
            err_msg = (f"Invalid number of host_interfaces ({len(host_interfaces)} "
                       f"or cx_card_breakout ({cx_card_breakout}) was provided.")
            logger.error(err_msg)
            sys.exit(1)
        self._config["host_nics_interfaces"] = host_interfaces[::cx_card_breakout]

    def _set_dms_servers_ports_params(self) -> None:
        """
        Set DMS server-port's params.

        Function will add the following params:
        - Dictionary of {<interface>: <dms_server_port>}
        - List of DMS server ports duplicated according to cx_card_breakout (e.g., [9339, 9339, 9340, 9340, ...]).
        """
        first_port = 9339
        cx_card_breakout = self._config.get("cx_card_breakout", 1)
        all_interfaces = self._config["host_interfaces"]
        dms_ports = {ifc: first_port + (ifc_index // cx_card_breakout) for ifc_index, ifc in enumerate(all_interfaces)}
        self._config["dms_ports"] = dms_ports
        self._config["dms_ports_list"] = [dms_ports[ifc] for ifc in all_interfaces]

    def _set_num_of_rails_group(self) -> None:
        """Set the number of rails groups in topology."""
        if "num_of_rails_group" in self._config:
            return
        self._config["num_of_rails_group"] = len(self._config.get("host_interfaces")) // self._config.get(
            "planes_num") // self._config.get("leaf_rails")

    def _set_max_host_in_su(self) -> None:
        """Set the max hosts in SU."""
        if "max_host_in_su" in self._config:
            return
        self._config["max_host_in_su"] = self._config.get("leaf_max_downlinks") // self._config.get("leaf_rails")

    def _set_validation_data_parameters(self) -> None:
        """Add validation data parameters to config."""
        should_skip_bf3_fw_desired_version = self._config.get("firmware_url") not in {None, ""}
        should_skip_cx_fw_desired_version = (self._config.get("doca_for_host_pkg_url") not in {None, ""} or
                                             self._config.get("firmware_url") not in {None, ""})
        ignore_collectors_groups_bf3 = (
            ["fw_version"] if should_skip_bf3_fw_desired_version else []
        )
        ignore_collectors_groups_cx = (
            ["fw_version"] if should_skip_cx_fw_desired_version else []
        )
        ignore_ip_version_collector = "ipv4" if self._config.get("ip_version") == "ipv6" else "ipv6"
        ignore_collectors_groups_cx.append(ignore_ip_version_collector)
        ignore_collectors_groups_bf3.append(ignore_ip_version_collector)

        cx_default_nvconfig = ("ROCE_ADAPTIVE_ROUTING_EN USER_PROGRAMMABLE_CC TX_SCHEDULER_LOCALITY_MODE "
                               "MULTIPATH_DSCP ROCE_RTT_RESP_DSCP_P<port_index> ROCE_RTT_RESP_DSCP_MODE_P<port_index> "
                               "ROCE_CC_STEERING_EXT")

        bf_default_nvconfig = ("INTERNAL_CPU_OFFLOAD_ENGINE ROCE_ADAPTIVE_ROUTING_EN USER_PROGRAMMABLE_CC "
                               "TX_SCHEDULER_LOCALITY_MODE MULTIPATH_DSCP ROCE_RTT_RESP_DSCP_P<port_index> "
                               "ROCE_RTT_RESP_DSCP_MODE_P<port_index> ROCE_CC_STEERING_EXT")

        # TODO: return LINK_TYPE to normal when bug in mlxconfig query is resolved  # noqa: FIX002,TD002,TD003
        if self._config["cx_card_breakout"] == 1:
            cx_default_nvconfig += " LINK_TYPE_P<port_index>"
            bf_default_nvconfig += " LINK_TYPE_P<port_index>"
        self._config["validation_data"] = {
            "ConnectX-7": {
                "desired_fw_version": "28.46.3048" if not should_skip_cx_fw_desired_version else "",
                "nvconfig": cx_default_nvconfig,
                "ignore_collectors_groups": ignore_collectors_groups_cx,
            },
            "ConnectX-8": {
                "desired_fw_version": "40.46.3048" if not should_skip_cx_fw_desired_version else "",
                "nvconfig": cx_default_nvconfig,
                "ignore_collectors_groups": ignore_collectors_groups_cx,
            },
            "BlueField-3": {
                "desired_fw_version": "32.46.3048" if not should_skip_bf3_fw_desired_version else "",
                "nvconfig": bf_default_nvconfig,
                "ignore_collectors_groups": ignore_collectors_groups_bf3,
            },
        }

    def _set_packages_files_names(self) -> None:
        """Extract the package filename from the provided URL in the config or defaults to a predefined package name."""
        self._config["doca_for_host_pkg_name"] = (
            self._config.get("doca_for_host_pkg_url").strip().split("/")[-1]
            if self._config.get("doca_for_host_pkg_url") not in {None, ""}
            else self._config.get("doca_for_host_pkg")
        )
        self._config["firmware_name"] = (
            self._config.get("firmware_url").strip().split("/")[-1]
            if self._config.get("firmware_url") not in {None, ""}
            else self._config.get("firmware")
        )
        self._config["doca_spcx_cc_name"] = (
            self._config.get("doca_spcx_cc_url").strip().split("/")[-1]
            if self._config.get("doca_spcx_cc_url") not in {None, ""}
            else self._config.get("doca_spcx_cc")
        )

    def _set_system_type(self) -> None:
        """Set the system_type to lower case."""
        self._config["system_type"] = self._config["system_type"].lower()

    def _set_switch_nos(self) -> None:
        """Set default switch_breakout."""
        if not self._config.get("switch_nos"):
            self._config["switch_nos"] = "cumulus"

    def _set_switch_breakout(self) -> None:
        """Set default switch_breakout."""
        if not self._config.get("switch_breakout"):
            self._config["switch_breakout"] = 2

    def _set_cx_card_breakout(self) -> None:
        """Set default cx_card_breakout."""
        if not self._config.get("cx_card_breakout"):
            self._config["cx_card_breakout"] = 1

    def _verify_required_params(self) -> None:
        """Verify the configuration that the required parameters exist."""
        for param in self._get_required_parameters():
            if param not in self._config:
                logger.error(f"Missing {param} in the config file")
                sys.exit(1)

    def _verify_supported_values(self) -> None:
        """Verify that a given configuration values are supported."""
        for key, supported_values in self._get_supported_values().items():
            self.verify_config_value(key=key, supported_values=supported_values)

    def _verify_host_first_octet(self) -> None:
        """Verify the host first octet."""
        host_first_octet = self._config["host_first_octet"]
        if host_first_octet in {"10", "100"}:
            logger.error(f"Host_first_octet is not allowed to be {host_first_octet}")
            sys.exit(1)

    def _verify_interfaces_params(self) -> None:
        """
        Verify the "host_interfaces" and "ports_rename" sections.

        Function is making sure exactly one of them provided and the required keys for them.
        """
        if "host_interfaces" in self._config:
            if "ports_rename" in self._config:
                logger.error('Cannot provide both "host_interfaces" and "ports_rename" parameters.'
                             'Please make sure to provide only one of them.')
                sys.exit(1)
        elif "ports_rename" not in self._config:
            logger.error('must provide one of the parameters "host_interfaces" or "ports_rename"')
            sys.exit(1)
        else:
            for key in ["netdev_prefix", "rdma_prefix", "pci_addr"]:
                if key not in self._config["ports_rename"]:
                    logger.error(f'Missing key "{key}" for the ports_rename section.')
                    sys.exit(1)

    def _verify_rail_to_pci_mapping(self) -> None:
        """Verify ports-renaming (rail-to-pci) mapping."""
        key = "rail_to_pci_mapping" if self._bcm_mode else "ports_rename"
        vendor_to_pci_addresses = self._config.get(key, {}) if self._bcm_mode else self._config.get(key, {"pci_addr": {}}).get("pci_addr")

        existing_num_of_pcis = set()  # To make sure not provided different number of PCIs on different vendors
        for vendor, pci_list in vendor_to_pci_addresses.items():
            num_of_pcis = len(pci_list)
            if num_of_pcis not in {4, 8}:
                msg = (f"Invalid number of PCIs ({num_of_pcis}) for {key} of vendor {vendor}. "
                       f"Supported: 4 or 8.")
                raise ValueError(msg)
            existing_num_of_pcis.add(num_of_pcis)
        if len(existing_num_of_pcis) > 1:
            msg = "Different number of PCIs provided for different vendors."
            raise ValueError(msg)

    def verify_telemetry_otlp_dest(self) -> None:
        """
        Validate the telemetry_otlp_dest section.

        Verify that 'telemetry_otlp_dest' and 'telemetry_otlp_port' contain non-empty values.
        """
        destinations = self._config.get("telemetry_otlp_destinations", [])

        for dest in destinations:
            server = str(dest.get("telemetry_otlp_dest", "")).strip()
            port = str(dest.get("telemetry_otlp_port", "")).strip()

            if not server or not port:
                msg = "The telemetry_otlp_dest and telemetry_otlp_port values cannot be empty."
                raise ValueError(msg)

    def _verify_firmware_url(self) -> None:
        """Verify the firmware url."""
        hca_type = self._config["hca_type"]
        firmware_url = self._config.get("firmware_url")

        if firmware_url in {None, ""}:
            return
        if hca_type == "BlueField-3":
            if not firmware_url.endswith(".bfb"):
                logger.error(f"firmware_url must end with '.bfb', but firmware_url is {firmware_url}")
                sys.exit(1)
        elif not firmware_url.endswith(".bin"):
            logger.error(f"firmware_url must end with '.bin', but firmware_url is {firmware_url}")
            sys.exit(1)

    def _set_ports_rename_recipe(self) -> None:
        """Set the 'port_rename_recipe' in the config and add the breakout ports pci addresses if needed."""
        if "ports_rename" not in self._config:
            return
        err_msg = f"Function _set_ports_rename_recipe not implemented in class '{self.__class__.__name__}'"
        raise NotImplementedError(err_msg)

    def _verify_custom_topology_supported(self) -> None:
        """Verify custom_topology is not provided on EXTERNAL image."""
        is_external_image = os.environ["IS_EXTERNAL_IMAGE"].lower() == "true"
        using_custom_topology = self._config.get("custom_topology", "none") != "none"
        if is_external_image and using_custom_topology:
            err_msg = "Providing 'custom_topology' on EXTERNAL image is not supported."
            raise ValueError(err_msg)
