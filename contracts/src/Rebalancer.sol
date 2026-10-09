// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITriplexRegistry, ILeveragedToken, IPositionAdapter, IMarketClock} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title Rebalancer
/// @notice Permissionless keeper entrypoint. Brings each product back to its target leverage:
///         - DAILY: once per trading day inside MarketClock's close window, walks leverage back to target and
///           records the end-of-day NAV snapshot;
///         - EMERGENCY: any time the oracle is live and leverage is outside [minLeverage, maxLeverage]
///           (24/5, including extended/overnight sessions).
///         Every call trades at most `maxChunk` of exposure and calls must be `minInterval` apart (TWAP execution).
///         Trade direction and size are computed on-chain; keepers choose nothing, and every swap is bounded by the
///         adapter's oracle-relative slippage limit. Positions near liquidation skip the interval ("urgent").
contract Rebalancer is AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;

    enum Mode {
        None,
        Daily,
        Emergency
    }

    struct Config {
        uint128 maxChunk; // max exposure traded per call (quote WAD)
        uint32 minInterval; // seconds between chunks
        uint16 toleranceBps; // |lev - target| <= target * tol  => daily rebalance considered done
        bool set;
    }

    struct State {
        uint64 lastChunkAt;
        uint64 lastDailyDay;
        bool emergencyActive; // set when leverage left the band; cleared once back within tolerance of target
    }

    /// @notice Products with less equity than this (1 quote token) are not rebalanced.
    uint256 public constant MIN_EQUITY = 1e18;

    ITriplexRegistry public immutable registry;
    Config public defaultConfig;
    mapping(address product => Config) public productConfig;
    mapping(address product => State) public state;

    event Rebalanced(
        address indexed product,
        Mode indexed mode,
        bool increase,
        uint256 chunkWad,
        uint256 leverageBefore,
        uint256 leverageAfter,
        uint256 navPerShare,
        uint256 price
    );
    event DailyCompleted(address indexed product, uint256 indexed day, uint256 leverage);
    event ConfigSet(address indexed product, uint128 maxChunk, uint32 minInterval, uint16 toleranceBps);

    error NothingToDo();
    error TooSoon(uint256 nextAt);
    error BadConfig();
    error NotProduct();

    constructor(address admin, address guardian, ITriplexRegistry registry_, Config memory defaults) {
        registry = registry_;
        _validate(defaults);
        defaults.set = true;
        defaultConfig = defaults;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.GUARDIAN_ROLE, guardian);
        emit ConfigSet(address(0), defaults.maxChunk, defaults.minInterval, defaults.toleranceBps);
    }

    // ------------------------------------------------------------------ admin

    function setDefaultConfig(Config calldata c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validate(c);
        defaultConfig = Config(c.maxChunk, c.minInterval, c.toleranceBps, true);
        emit ConfigSet(address(0), c.maxChunk, c.minInterval, c.toleranceBps);
    }

    function setProductConfig(address product, Config calldata c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validate(c);
        productConfig[product] = Config(c.maxChunk, c.minInterval, c.toleranceBps, true);
        emit ConfigSet(product, c.maxChunk, c.minInterval, c.toleranceBps);
    }

    function pause() external onlyRole(Constants.GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function configOf(address product) public view returns (Config memory c) {
        c = productConfig[product];
        if (!c.set) c = defaultConfig;
    }

    /// @notice What a keeper call would do right now.
    /// @return mode None / Daily / Emergency
    /// @return leverage current leverage (WAD)
    /// @return increase true if exposure must go up
    /// @return chunk exposure that would be traded (WAD; 0 = snapshot only)
    /// @return ready false if the min interval has not elapsed (and the position is not urgent)
    function check(address product)
        public
        view
        returns (Mode mode, uint256 leverage, bool increase, uint256 chunk, bool ready)
    {
        (bool live, uint256 exposure, uint256 equity) = _live(product);
        if (!live) return (Mode.None, 0, false, 0, false);
        leverage = exposure.mulDiv(Constants.WAD, equity);
        mode = _mode(product, leverage);
        if (mode == Mode.None) return (Mode.None, leverage, false, 0, false);
        (increase, chunk, ready) = _sizing(product, mode, exposure, equity, leverage);
    }

    function _live(address product) internal view returns (bool live, uint256 exposure, uint256 equity) {
        if (!registry.isProduct(product)) return (false, 0, 0);
        ILeveragedToken t = ILeveragedToken(product);
        IPositionAdapter a = t.adapter();
        if (!a.hasPosition()) return (false, 0, 0);
        (bool ok,) = registry.oracle().tryGetQuotePrice(t.underlying(), t.quoteToken());
        if (!ok) return (false, 0, 0);
        (exposure,,, equity) = a.positionValues();
        live = equity >= MIN_EQUITY; // dust (e.g. only the locked dead shares left) is not worth trading

    }

    function _mode(address product, uint256 leverage) internal view returns (Mode) {
        ILeveragedToken t = ILeveragedToken(product);
        if (leverage < t.minLeverage() || leverage > t.maxLeverage()) return Mode.Emergency;
        // an emergency de/re-leverage continues all the way back to target, not just to the band edge
        if (state[product].emergencyActive && !_withinTolerance(product, leverage)) return Mode.Emergency;
        IMarketClock clock = registry.marketClock();
        if (clock.isDailyRebalanceWindow() && state[product].lastDailyDay < clock.tradingDayId(block.timestamp)) {
            return Mode.Daily;
        }
        return Mode.None;
    }

    function _sizing(address product, Mode mode, uint256 exposure, uint256 equity, uint256 leverage)
        internal
        view
        returns (bool increase, uint256 chunk, bool ready)
    {
        ILeveragedToken t = ILeveragedToken(product);
        uint256 target = t.targetLeverage();
        Config memory c = configOf(product);
        uint256 targetExposure = target.mulDiv(equity, Constants.WAD);
        increase = targetExposure > exposure;
        uint256 diff = increase ? targetExposure - exposure : exposure - targetExposure;
        bool withinTol = diff * Constants.BPS <= targetExposure * c.toleranceBps;
        chunk = (mode == Mode.Daily && withinTol) ? 0 : Math.min(diff, c.maxChunk);
        ready = chunk == 0 || _urgentOrDue(product, leverage, target, c.minInterval);
    }

    /// @dev Urgent = leverage beyond max + (max - target), e.g. > 4.2x for a 3x product: skip the TWAP interval.
    function _urgentOrDue(address product, uint256 leverage, uint256 target, uint256 minInterval)
        internal
        view
        returns (bool)
    {
        uint256 maxL = ILeveragedToken(product).maxLeverage();
        if (leverage > maxL + (maxL - target)) return true;
        return block.timestamp >= uint256(state[product].lastChunkAt) + minInterval;
    }

    // ------------------------------------------------------------------ keeper

    struct Step {
        Mode mode;
        uint256 levBefore;
        bool increase;
        uint256 chunk;
        bool ready;
        uint256 levAfter;
    }

    /// @notice Executes one rebalance step for `product`. Permissionless.
    // Writes after the adapter call are safe: the function is nonReentrant and the adapter only calls trusted
    // venues (Morpho, governance-set swap adapter).
    // slither-disable-start reentrancy-no-eth
    function rebalance(address product) external nonReentrant whenNotPaused returns (Mode) {
        Step memory st = Step(Mode.None, 0, false, 0, false, 0);
        (st.mode, st.levBefore, st.increase, st.chunk, st.ready) = check(product);
        if (st.mode == Mode.None) revert NothingToDo();
        Config memory c = configOf(product);
        if (!st.ready) revert TooSoon(uint256(state[product].lastChunkAt) + c.minInterval);

        IPositionAdapter a = ILeveragedToken(product).adapter();
        if (st.chunk != 0) {
            state[product].lastChunkAt = uint64(block.timestamp);
            if (st.increase) a.increaseExposure(st.chunk);
            else a.decreaseExposure(st.chunk);
        }

        st.levAfter = _completeDayIfDone(product, a, c.toleranceBps);
        state[product].emergencyActive = st.mode == Mode.Emergency && !_withinTolerance(product, st.levAfter);
        emit Rebalanced(
            product, st.mode, st.increase, st.chunk, st.levBefore, st.levAfter, _nav(product), a.assetPrice()
        );
        return st.mode;
    }
    // slither-disable-end reentrancy-no-eth

    /// @dev Closes out the trading day (snapshot) once leverage is back within tolerance in the daily window.
    function _completeDayIfDone(address product, IPositionAdapter a, uint256 toleranceBps)
        internal
        returns (uint256 levAfter)
    {
        (uint256 exposure,,, uint256 equity) = a.positionValues();
        if (equity == 0) return type(uint256).max;
        levAfter = exposure.mulDiv(Constants.WAD, equity);

        IMarketClock clock = registry.marketClock();
        uint256 day = clock.tradingDayId(block.timestamp);
        if (!clock.isDailyRebalanceWindow() || state[product].lastDailyDay >= day) return levAfter;

        ILeveragedToken t = ILeveragedToken(product);
        uint256 target = t.targetLeverage();
        uint256 diff = levAfter > target ? levAfter - target : target - levAfter;
        if (diff * Constants.BPS <= target * toleranceBps) {
            state[product].lastDailyDay = uint64(day);
            t.recordDailySnapshot();
            emit DailyCompleted(product, day, levAfter);
        }
    }

    function _withinTolerance(address product, uint256 leverage) internal view returns (bool) {
        uint256 target = ILeveragedToken(product).targetLeverage();
        uint256 diff = leverage > target ? leverage - target : target - leverage;
        return diff * Constants.BPS <= target * configOf(product).toleranceBps;
    }

    function _nav(address product) internal view returns (uint256) {
        (bool ok, bytes memory ret) = product.staticcall(abi.encodeWithSignature("navPerShare()"));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    function _validate(Config memory c) internal pure {
        if (c.maxChunk == 0 || c.minInterval > 1 hours || c.toleranceBps == 0 || c.toleranceBps > 2_000) {
            revert BadConfig();
        }
    }
}
