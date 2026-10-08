// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Constants {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    /// @notice Hard cap on the streaming management fee: 3% per year.
    uint256 internal constant MAX_MGMT_FEE_BPS = 300;
    /// @notice Hard cap on mint / redeem fees: 1%.
    uint256 internal constant MAX_MINT_REDEEM_FEE_BPS = 100;

    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    bytes32 internal constant ACTION_MINT = keccak256("MINT");
    bytes32 internal constant ACTION_REDEEM = keccak256("REDEEM");
}
