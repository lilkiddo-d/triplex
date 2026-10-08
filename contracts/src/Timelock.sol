// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title Timelock
/// @notice Owns every admin role in Triplex. Enforces a minimum 48h delay that can never be lowered below the floor,
///         even by a self-governed `updateDelay` proposal.
contract Timelock is TimelockController {
    uint256 public constant MIN_DELAY_FLOOR = 48 hours;

    error DelayBelowFloor(uint256 delay);

    /// @param minDelay initial delay (>= 48h)
    /// @param proposers accounts allowed to schedule (and cancel) operations
    /// @param executors accounts allowed to execute; include address(0) to let anyone execute
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY_FLOOR) revert DelayBelowFloor(minDelay);
    }

    /// @notice Effective delay used by `schedule`: never below the 48h floor.
    function getMinDelay() public view virtual override returns (uint256) {
        uint256 d = super.getMinDelay();
        return d < MIN_DELAY_FLOOR ? MIN_DELAY_FLOOR : d;
    }
}
