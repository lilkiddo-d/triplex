// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist gate for key actions (mint, redeem). OFF by default: while `enabled` is false every
///         account is allowed. Enabling is an admin (Timelock) action; the allowlist is managed by COMPLIANCE_ROLE.
///         Redeem gating is separately switchable so holders can always exit unless explicitly required otherwise.
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    bool public enabled;
    bool public gateRedeem;
    mapping(address account => bool) public allowed;

    event EnabledSet(bool enabled, bool gateRedeem);
    event AllowedSet(address indexed account, bool allowed);

    constructor(address admin, address complianceManager) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.COMPLIANCE_ROLE, complianceManager);
    }

    function setEnabled(bool enabled_, bool gateRedeem_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        gateRedeem = gateRedeem_;
        emit EnabledSet(enabled_, gateRedeem_);
    }

    function setAllowed(address account, bool isAllowed_) external onlyRole(Constants.COMPLIANCE_ROLE) {
        allowed[account] = isAllowed_;
        emit AllowedSet(account, isAllowed_);
    }

    /// @inheritdoc IComplianceRegistry
    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled) return true;
        if (action == Constants.ACTION_REDEEM && !gateRedeem) return true;
        return allowed[account];
    }
}
