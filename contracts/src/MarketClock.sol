// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "./interfaces/ITriplex.sol";
import {Constants} from "./libraries/Constants.sol";

/// @title MarketClock
/// @notice US equity regular-session calendar (NYSE hours, America/New_York with US DST rules).
///         Holidays / early closes are set per ET calendar day by the operator. A guardian can flag a
///         market-wide halt (e.g. a circuit-breaker) which closes mint/redeem immediately.
contract MarketClock is IMarketClock, AccessControl {
    uint8 public constant STATUS_DEFAULT = 0;
    uint8 public constant STATUS_CLOSED = 1;
    uint8 public constant STATUS_EARLY_CLOSE = 2;

    uint256 public constant OPEN_SECONDS = 9 hours + 30 minutes;
    uint256 public constant CLOSE_SECONDS = 16 hours;
    uint256 public constant EARLY_CLOSE_SECONDS = 13 hours;

    /// @notice ET day id (days since 1970-01-01 in New York local time) => status.
    mapping(uint256 dayId => uint8 status) public dayStatus;
    bool public halted;

    uint32 public openBuffer = 5 minutes; // mint/redeem opens at 09:35 ET
    uint32 public closeBuffer = 15 minutes; // mint/redeem closes at 15:45 ET
    uint32 public preCloseWindow = 15 minutes; // daily rebalance window opens 15:45 ET
    uint32 public postCloseWindow = 60 minutes; // ... and closes 17:00 ET

    event DayStatusSet(uint256 indexed dayId, uint8 status);
    event HaltSet(bool halted);
    event WindowsSet(uint32 openBuffer, uint32 closeBuffer, uint32 preCloseWindow, uint32 postCloseWindow);

    error BadConfig();

    constructor(address admin, address guardian, uint256[] memory holidays, uint256[] memory earlyCloses) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Constants.GUARDIAN_ROLE, guardian);
        _grantRole(Constants.OPERATOR_ROLE, guardian);
        // Bounded by calldata provided at deployment.
        for (uint256 i; i < holidays.length; ++i) {
            dayStatus[holidays[i]] = STATUS_CLOSED;
            emit DayStatusSet(holidays[i], STATUS_CLOSED);
        }
        for (uint256 i; i < earlyCloses.length; ++i) {
            dayStatus[earlyCloses[i]] = STATUS_EARLY_CLOSE;
            emit DayStatusSet(earlyCloses[i], STATUS_EARLY_CLOSE);
        }
    }

    // ------------------------------------------------------------------ admin

    function setDayStatus(uint256 dayId, uint8 status) external onlyRole(Constants.OPERATOR_ROLE) {
        if (status > STATUS_EARLY_CLOSE) revert BadConfig();
        dayStatus[dayId] = status;
        emit DayStatusSet(dayId, status);
    }

    function setHalted(bool h) external onlyRole(Constants.GUARDIAN_ROLE) {
        halted = h;
        emit HaltSet(h);
    }

    function setWindows(uint32 openBuffer_, uint32 closeBuffer_, uint32 preClose_, uint32 postClose_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (openBuffer_ > 1 hours || closeBuffer_ > 2 hours || preClose_ > 1 hours || postClose_ > 4 hours) {
            revert BadConfig();
        }
        // mint/redeem must be closed for the whole pre-close rebalance window
        if (closeBuffer_ < preClose_) revert BadConfig();
        openBuffer = openBuffer_;
        closeBuffer = closeBuffer_;
        preCloseWindow = preClose_;
        postCloseWindow = postClose_;
        emit WindowsSet(openBuffer_, closeBuffer_, preClose_, postClose_);
    }

    // ------------------------------------------------------------------ views

    function isMarketOpen() external view returns (bool) {
        return isMarketOpenAt(block.timestamp);
    }

    function isMintRedeemOpen() external view returns (bool) {
        return isMintRedeemOpenAt(block.timestamp);
    }

    function isDailyRebalanceWindow() external view returns (bool) {
        return isDailyRebalanceWindowAt(block.timestamp);
    }

    function tradingDayId(uint256 timestamp) public pure returns (uint256) {
        return _toLocal(timestamp) / 1 days;
    }

    function isMarketOpenAt(uint256 ts) public view returns (bool) {
        if (halted) return false;
        (bool tradingDay, uint256 secs, uint256 closeAt) = _session(ts);
        return tradingDay && secs >= OPEN_SECONDS && secs < closeAt;
    }

    function isMintRedeemOpenAt(uint256 ts) public view returns (bool) {
        if (halted) return false;
        (bool tradingDay, uint256 secs, uint256 closeAt) = _session(ts);
        return tradingDay && secs >= OPEN_SECONDS + openBuffer && secs + closeBuffer < closeAt;
    }

    function isDailyRebalanceWindowAt(uint256 ts) public view returns (bool) {
        if (halted) return false;
        (bool tradingDay, uint256 secs, uint256 closeAt) = _session(ts);
        return tradingDay && secs + preCloseWindow >= closeAt && secs < closeAt + postCloseWindow;
    }

    /// @notice Session details for frontends (ET day id, whether it trades, seconds since local midnight, close time).
    function sessionInfo(uint256 ts)
        external
        view
        returns (uint256 dayId, bool tradingDay, uint256 secondsIntoDay, uint256 closeAt, bool dst)
    {
        uint256 local = _toLocal(ts);
        dayId = local / 1 days;
        (tradingDay, secondsIntoDay, closeAt) = _session(ts);
        dst = isDst(ts);
    }

    // ------------------------------------------------------------------ calendar math

    function _session(uint256 ts) internal view returns (bool tradingDay, uint256 secs, uint256 closeAt) {
        uint256 local = _toLocal(ts);
        uint256 dayId = local / 1 days;
        secs = local % 1 days;
        uint8 status = dayStatus[dayId];
        uint256 wd = weekday(dayId);
        tradingDay = wd >= 1 && wd <= 5 && status != STATUS_CLOSED;
        closeAt = status == STATUS_EARLY_CLOSE ? EARLY_CLOSE_SECONDS : CLOSE_SECONDS;
    }

    function _toLocal(uint256 ts) internal pure returns (uint256) {
        return ts - (isDst(ts) ? 4 hours : 5 hours);
    }

    /// @notice US DST: from the 2nd Sunday of March 02:00 EST (07:00 UTC) to the 1st Sunday of November
    ///         02:00 EDT (06:00 UTC).
    function isDst(uint256 ts) public pure returns (bool) {
        (uint256 y,,) = civilFromDays(ts / 1 days);
        uint256 start = nthSunday(y, 3, 2) * 1 days + 7 hours;
        uint256 end = nthSunday(y, 11, 1) * 1 days + 6 hours;
        return ts >= start && ts < end;
    }

    /// @notice 0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday.
    function weekday(uint256 dayId) public pure returns (uint256) {
        return (dayId + 4) % 7;
    }

    function nthSunday(uint256 y, uint256 m, uint256 n) public pure returns (uint256) {
        uint256 first = daysFromCivil(y, m, 1);
        uint256 wd = weekday(first);
        return first + ((7 - wd) % 7) + 7 * (n - 1);
    }

    /// @notice Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm), y >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    function civilFromDays(uint256 z) public pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
}
