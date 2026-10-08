// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IProjectTokenHooks} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title ProjectTokenHooks
/// @notice All $TRPX integration lives here. Triplex never deploys the token: its address is provided once through
///         `setProjectToken`, which only the admin (the 48h Timelock) can call. Until then every token feature is
///         disabled: staking reverts, fee discounts are 0 and FeeCollector routes 100% of fees to the treasury.
///         Features: (1) stakers earn a share of protocol fees (paid in the quote stablecoin),
///                   (2) stakers get a discount on mint/redeem fees (two tiers).
contract ProjectTokenHooks is IProjectTokenHooks, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant ACC = 1e36;
    uint256 public constant MAX_DISCOUNT_BPS = 7_500;
    uint256 public constant MAX_COOLDOWN = 30 days;

    IERC20 public projectToken;
    IERC20 public immutable rewardToken;
    address public feeCollector;

    uint256 public totalStaked;
    mapping(address account => uint256) public stakedBalance;

    struct PendingUnstake {
        uint128 amount;
        uint64 unlockAt;
    }

    mapping(address account => PendingUnstake) public pendingUnstake;
    uint256 public unstakeCooldown = 7 days;

    uint256 public rewardPerTokenStored;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    mapping(address account => uint256) public rewards;

    uint256 public tier1Threshold;
    uint256 public tier1DiscountBps;
    uint256 public tier2Threshold;
    uint256 public tier2DiscountBps;

    event ProjectTokenSet(address indexed token);
    event FeeCollectorSet(address indexed feeCollector);
    event Staked(address indexed account, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rewardPerTokenStored);
    event TiersSet(uint256 t1Threshold, uint256 t1DiscountBps, uint256 t2Threshold, uint256 t2DiscountBps);
    event CooldownSet(uint256 cooldown);

    error AlreadySet();
    error NotActive();
    error BadConfig();
    error ZeroAmount();
    error NotFeeCollector();
    error Locked(uint256 unlockAt);
    error NoStakers();

    constructor(address admin, address guardian, IERC20 rewardToken_) {
        rewardToken = rewardToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.GUARDIAN_ROLE, guardian);
    }

    modifier updateReward(address account) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    modifier whenActive() {
        if (address(projectToken) == address(0)) revert NotActive();
        _;
    }

    // ------------------------------------------------------------------ admin (Timelock)

    /// @notice One-time wiring of the externally launched project token. Callable only via the Timelock.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert AlreadySet();
        if (token == address(0) || token.code.length == 0) revert BadConfig();
        IERC20(token).totalSupply(); // must look like an ERC-20
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert BadConfig();
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function setTiers(uint256 t1Threshold, uint256 t1DiscountBps, uint256 t2Threshold, uint256 t2DiscountBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (t1DiscountBps > MAX_DISCOUNT_BPS || t2DiscountBps > MAX_DISCOUNT_BPS) revert BadConfig();
        if (t2Threshold < t1Threshold || t2DiscountBps < t1DiscountBps) revert BadConfig();
        tier1Threshold = t1Threshold;
        tier1DiscountBps = t1DiscountBps;
        tier2Threshold = t2Threshold;
        tier2DiscountBps = t2DiscountBps;
        emit TiersSet(t1Threshold, t1DiscountBps, t2Threshold, t2DiscountBps);
    }

    function setUnstakeCooldown(uint256 cooldown) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cooldown > MAX_COOLDOWN) revert BadConfig();
        unstakeCooldown = cooldown;
        emit CooldownSet(cooldown);
    }

    function pause() external onlyRole(Constants.GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant whenNotPaused whenActive updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before; // fee-on-transfer safe
        stakedBalance[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Starts the cooldown. Unstaking stake stops earning and stops counting toward fee discounts at once.
    function requestUnstake(uint256 amount) external nonReentrant whenActive updateReward(msg.sender) {
        if (amount == 0 || amount > stakedBalance[msg.sender]) revert ZeroAmount();
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        PendingUnstake storage p = pendingUnstake[msg.sender];
        p.amount += uint128(amount);
        p.unlockAt = uint64(block.timestamp + unstakeCooldown);
        emit UnstakeRequested(msg.sender, amount, p.unlockAt);
    }

    function withdraw() external nonReentrant whenActive {
        PendingUnstake memory p = pendingUnstake[msg.sender];
        if (p.amount == 0) revert ZeroAmount();
        if (block.timestamp < p.unlockAt) revert Locked(p.unlockAt);
        delete pendingUnstake[msg.sender];
        projectToken.safeTransfer(msg.sender, p.amount);
        emit Withdrawn(msg.sender, p.amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (reward == 0) return 0;
        rewards[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    /// @inheritdoc IProjectTokenHooks
    function notifyReward(uint256 amount) external nonReentrant {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        if (totalStaked == 0) revert NoStakers();
        if (amount == 0) revert ZeroAmount();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPerTokenStored += Math.mulDiv(amount, ACC, totalStaked);
        emit RewardNotified(amount, rewardPerTokenStored);
    }

    // ------------------------------------------------------------------ views

    function isActive() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + Math.mulDiv(stakedBalance[account], rewardPerTokenStored - userRewardPerTokenPaid[account], ACC);
    }

    /// @inheritdoc IProjectTokenHooks
    function feeDiscountBps(address account) external view returns (uint256) {
        if (!isActive()) return 0;
        uint256 bal = stakedBalance[account];
        if (tier2Threshold != 0 && bal >= tier2Threshold) return tier2DiscountBps;
        if (tier1Threshold != 0 && bal >= tier1Threshold) return tier1DiscountBps;
        return 0;
    }
}
