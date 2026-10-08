// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interfaces/external/IChainlink.sol";
import {IOracleAdapter, IPriceSource} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title OracleAdapter
/// @notice Chainlink-backed, swappable price oracle with staleness, sanity, sequencer and deviation checks.
/// @dev The protocol reads the oracle through the factory registry, so a new implementation can be swapped in
///      by the Timelock without touching products.
contract OracleAdapter is IOracleAdapter, AccessControl {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxAge; // max seconds since updatedAt
        uint8 feedDecimals;
    }

    struct DeviationConfig {
        IPriceSource source; // secondary source (e.g. Uniswap v3 TWAP); address(0) = disabled
        uint16 maxDeviationBps; // max |primary - secondary| / primary
        bool strict; // if true, an unavailable secondary makes the price invalid
    }

    uint256 public constant MAX_DEVIATION_CAP_BPS = 2_000; // a deviation bound looser than 20% is meaningless
    uint256 public constant MIN_MAX_AGE = 60;
    uint256 public constant MAX_MAX_AGE = 7 days;

    mapping(address asset => FeedConfig) public feeds;
    mapping(address asset => mapping(address quote => DeviationConfig)) public deviation;

    /// @notice Optional Chainlink L2 sequencer uptime feed (none is published for Robinhood Chain yet).
    AggregatorV3Interface public sequencerUptimeFeed;
    uint256 public sequencerGracePeriod = 1 hours;

    event FeedSet(address indexed asset, address indexed feed, uint32 maxAge, uint8 decimals);
    event DeviationSet(address indexed asset, address indexed quote, address source, uint16 maxDeviationBps, bool strict);
    event SequencerFeedSet(address indexed feed, uint256 gracePeriod);

    error FeedNotSet(address asset);
    error StalePrice(address asset, uint256 updatedAt);
    error InvalidPrice(address asset, int256 answer);
    error SequencerDown();
    error SequencerGracePeriod();
    error PriceDeviation(address asset, uint256 primary, uint256 secondary);
    error SecondaryUnavailable(address asset);
    error BadConfig();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ admin

    function setFeed(address asset, AggregatorV3Interface feed, uint32 maxAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || address(feed) == address(0) || maxAge < MIN_MAX_AGE || maxAge > MAX_MAX_AGE) {
            revert BadConfig();
        }
        uint8 dec = feed.decimals();
        if (dec > 36) revert BadConfig();
        feeds[asset] = FeedConfig({feed: feed, maxAge: maxAge, feedDecimals: dec});
        emit FeedSet(asset, address(feed), maxAge, dec);
    }

    function setDeviation(address asset, address quote, IPriceSource source, uint16 maxDeviationBps, bool strict)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (maxDeviationBps > MAX_DEVIATION_CAP_BPS) revert BadConfig();
        if (address(source) != address(0) && maxDeviationBps == 0) revert BadConfig();
        deviation[asset][quote] = DeviationConfig({source: source, maxDeviationBps: maxDeviationBps, strict: strict});
        emit DeviationSet(asset, quote, address(source), maxDeviationBps, strict);
    }

    function setSequencerUptimeFeed(AggregatorV3Interface feed, uint256 gracePeriod)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (gracePeriod > 1 days) revert BadConfig();
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(address(feed), gracePeriod);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc IOracleAdapter
    function getPrice(address asset) public view returns (uint256) {
        _checkSequencer();
        return _chainlinkPrice(asset);
    }

    /// @inheritdoc IOracleAdapter
    function getQuotePrice(address asset, address quote) public view returns (uint256 price) {
        _checkSequencer();
        uint256 a = _chainlinkPrice(asset);
        uint256 q = _chainlinkPrice(quote);
        price = Math.mulDiv(a, Constants.WAD, q);
        _checkDeviation(asset, quote, price);
    }

    /// @inheritdoc IOracleAdapter
    function tryGetQuotePrice(address asset, address quote) external view returns (bool ok, uint256 price) {
        try this.getQuotePrice(asset, quote) returns (uint256 p) {
            return (true, p);
        } catch {
            return (false, 0);
        }
    }

    // ------------------------------------------------------------------ internals

    function _chainlinkPrice(address asset) internal view returns (uint256) {
        FeedConfig memory cfg = feeds[asset];
        if (address(cfg.feed) == address(0)) revert FeedNotSet(asset);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = cfg.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (answeredInRound < roundId) revert StalePrice(asset, updatedAt);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.maxAge) {
            revert StalePrice(asset, updatedAt);
        }
        // scale to 18 decimals
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        if (cfg.feedDecimals < 18) return raw * 10 ** (18 - cfg.feedDecimals);
        return raw / 10 ** (cfg.feedDecimals - 18);
    }

    function _checkSequencer() internal view {
        AggregatorV3Interface f = sequencerUptimeFeed;
        if (address(f) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = f.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
    }

    function _checkDeviation(address asset, address quote, uint256 primary) internal view {
        DeviationConfig memory d = deviation[asset][quote];
        if (address(d.source) == address(0)) return;
        try d.source.getQuotePrice(asset, quote) returns (uint256 secondary) {
            if (secondary == 0) {
                if (d.strict) revert SecondaryUnavailable(asset);
                return;
            }
            uint256 diff = primary > secondary ? primary - secondary : secondary - primary;
            if (diff * Constants.BPS > primary * d.maxDeviationBps) revert PriceDeviation(asset, primary, secondary);
        } catch {
            if (d.strict) revert SecondaryUnavailable(asset);
        }
    }
}
