// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITriplexRegistry, ILeveragedToken, IProjectTokenHooks} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title FeeCollector
/// @notice Receives mint/redeem fees (quote stablecoin) and streaming management fees (product shares).
///         `harvest` converts fee shares to quote (fee-free redeem, operator only, with min-out).
///         `distribute` (permissionless) sends `stakerShareBps` of the quote balance to $TRPX stakers through
///         ProjectTokenHooks when the token is live and has stakers, and the rest to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_STAKER_SHARE_BPS = 10_000;

    ITriplexRegistry public immutable registry;
    IERC20 public immutable quote;
    address public treasury;
    uint256 public stakerShareBps;

    event TreasurySet(address indexed treasury);
    event StakerShareSet(uint256 bps);
    event Harvested(address indexed product, uint256 shares, uint256 quoteOut);
    event Distributed(uint256 toStakers, uint256 toTreasury);

    error BadConfig();

    constructor(address admin, address operator, ITriplexRegistry registry_, IERC20 quote_, address treasury_) {
        if (treasury_ == address(0)) revert BadConfig();
        registry = registry_;
        quote = quote_;
        treasury = treasury_;
        stakerShareBps = 5_000;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.OPERATOR_ROLE, operator);
    }

    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert BadConfig();
        treasury = t;
        emit TreasurySet(t);
    }

    function setStakerShareBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert BadConfig();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }

    /// @notice Redeems accumulated management-fee shares of `product` into quote.
    function harvest(address product, uint256 minQuoteOut, uint256 deadline)
        external
        nonReentrant
        onlyRole(Constants.OPERATOR_ROLE)
        returns (uint256 quoteOut)
    {
        if (!registry.isProduct(product)) revert BadConfig();
        uint256 shares = IERC20(product).balanceOf(address(this));
        if (shares == 0) return 0;
        quoteOut = ILeveragedToken(product).redeem(shares, minQuoteOut, deadline);
        emit Harvested(product, shares, quoteOut);
    }

    /// @notice Splits the quote balance between $TRPX stakers (if live) and the treasury. Permissionless.
    function distribute() external nonReentrant returns (uint256 toStakers, uint256 toTreasury) {
        uint256 bal = quote.balanceOf(address(this));
        if (bal == 0) return (0, 0);
        IProjectTokenHooks hooks = registry.projectTokenHooks();
        if (address(hooks) != address(0) && hooks.isActive() && hooks.totalStaked() != 0) {
            toStakers = bal * stakerShareBps / Constants.BPS;
        }
        toTreasury = bal - toStakers;
        if (toStakers != 0) {
            quote.forceApprove(address(hooks), toStakers);
            hooks.notifyReward(toStakers);
        }
        if (toTreasury != 0) quote.safeTransfer(treasury, toTreasury);
        emit Distributed(toStakers, toTreasury);
    }
}
