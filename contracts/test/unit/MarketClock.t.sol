// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MarketClock} from "../../src/MarketClock.sol";

contract MarketClockTest is Test {
    MarketClock clock;
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");

    function setUp() public {
        uint256[] memory hol = new uint256[](1);
        uint256[] memory early = new uint256[](1);
        clock = new MarketClock(admin, guardian, hol, early);
        hol[0] = clock.daysFromCivil(2026, 11, 26); // Thanksgiving
        early[0] = clock.daysFromCivil(2026, 11, 27);
        clock = new MarketClock(admin, guardian, hol, early);
    }

    function _ts(uint256 y, uint256 m, uint256 d, uint256 hh, uint256 mm) internal view returns (uint256) {
        return clock.daysFromCivil(y, m, d) * 1 days + hh * 1 hours + mm * 1 minutes;
    }

    function test_civil_knownDates() public view {
        assertEq(clock.daysFromCivil(1970, 1, 1), 0);
        assertEq(clock.daysFromCivil(2026, 10, 6) * 1 days, 1_791_244_800);
        assertEq(clock.weekday(clock.daysFromCivil(2026, 10, 6)), 2); // Tuesday
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(clock.daysFromCivil(2028, 2, 29));
        assertEq(y, 2028);
        assertEq(m, 2);
        assertEq(d, 29);
        assertEq(clock.nthSunday(2026, 3, 2), clock.daysFromCivil(2026, 3, 8));
        assertEq(clock.nthSunday(2026, 11, 1), clock.daysFromCivil(2026, 11, 1));
    }

    function testFuzz_civil_roundTrip(uint256 z) public view {
        z = bound(z, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(z);
        assertEq(clock.daysFromCivil(y, m, d), z);
    }

    function test_dstBoundaries() public view {
        assertFalse(clock.isDst(_ts(2026, 3, 8, 6, 59)));
        assertTrue(clock.isDst(_ts(2026, 3, 8, 7, 0)));
        assertTrue(clock.isDst(_ts(2026, 11, 1, 5, 59)));
        assertFalse(clock.isDst(_ts(2026, 11, 1, 6, 0)));
    }

    function test_summerSession() public view {
        // Tue 2026-10-06, EDT (UTC-4)
        assertFalse(clock.isMarketOpenAt(_ts(2026, 10, 6, 13, 29))); // 09:29
        assertTrue(clock.isMarketOpenAt(_ts(2026, 10, 6, 13, 30))); // 09:30
        assertFalse(clock.isMintRedeemOpenAt(_ts(2026, 10, 6, 13, 34)));
        assertTrue(clock.isMintRedeemOpenAt(_ts(2026, 10, 6, 13, 35)));
        assertTrue(clock.isMintRedeemOpenAt(_ts(2026, 10, 6, 19, 44))); // 15:44
        assertFalse(clock.isMintRedeemOpenAt(_ts(2026, 10, 6, 19, 45))); // 15:45
        assertFalse(clock.isDailyRebalanceWindowAt(_ts(2026, 10, 6, 19, 44)));
        assertTrue(clock.isDailyRebalanceWindowAt(_ts(2026, 10, 6, 19, 45)));
        assertTrue(clock.isMarketOpenAt(_ts(2026, 10, 6, 19, 59)));
        assertFalse(clock.isMarketOpenAt(_ts(2026, 10, 6, 20, 0))); // 16:00
        assertTrue(clock.isDailyRebalanceWindowAt(_ts(2026, 10, 6, 20, 59)));
        assertFalse(clock.isDailyRebalanceWindowAt(_ts(2026, 10, 6, 21, 0))); // 17:00
    }

    function test_winterSession() public view {
        // Tue 2026-12-01, EST (UTC-5)
        assertFalse(clock.isMarketOpenAt(_ts(2026, 12, 1, 14, 29)));
        assertTrue(clock.isMarketOpenAt(_ts(2026, 12, 1, 14, 30)));
        assertFalse(clock.isMarketOpenAt(_ts(2026, 12, 1, 21, 0)));
        assertEq(clock.tradingDayId(_ts(2026, 12, 2, 3, 0)), clock.daysFromCivil(2026, 12, 1)); // 22:00 ET prev day
    }

    function test_weekendClosed() public view {
        assertFalse(clock.isMarketOpenAt(_ts(2026, 10, 10, 15, 0))); // Saturday
        assertFalse(clock.isMarketOpenAt(_ts(2026, 10, 11, 15, 0))); // Sunday
        assertFalse(clock.isDailyRebalanceWindowAt(_ts(2026, 10, 10, 19, 50)));
    }

    function test_holidayAndEarlyClose() public view {
        assertFalse(clock.isMarketOpenAt(_ts(2026, 11, 26, 15, 0)));
        // early close 13:00 EST = 18:00 UTC
        assertTrue(clock.isMarketOpenAt(_ts(2026, 11, 27, 17, 59)));
        assertFalse(clock.isMarketOpenAt(_ts(2026, 11, 27, 18, 0)));
        assertFalse(clock.isMintRedeemOpenAt(_ts(2026, 11, 27, 17, 45)));
        assertTrue(clock.isDailyRebalanceWindowAt(_ts(2026, 11, 27, 17, 50)));
    }

    function test_operatorSetsDay_andGuardianHalts() public {
        uint256 day = clock.daysFromCivil(2026, 10, 6);
        uint8 closed = clock.STATUS_CLOSED();
        vm.prank(guardian);
        clock.setDayStatus(day, closed);
        assertFalse(clock.isMarketOpenAt(_ts(2026, 10, 6, 15, 0)));
        vm.prank(guardian);
        clock.setDayStatus(day, 0);

        vm.warp(_ts(2026, 10, 6, 15, 0));
        assertTrue(clock.isMarketOpen());
        assertTrue(clock.isMintRedeemOpen());
        vm.prank(guardian);
        clock.setHalted(true);
        assertFalse(clock.isMarketOpen());
        assertFalse(clock.isMintRedeemOpen());
        assertFalse(clock.isDailyRebalanceWindow());

        vm.expectRevert(MarketClock.BadConfig.selector);
        vm.prank(guardian);
        clock.setDayStatus(day, 3);
    }

    function test_sessionInfo() public view {
        (uint256 dayId, bool trading, uint256 secs, uint256 closeAt, bool dst) =
            clock.sessionInfo(_ts(2026, 10, 6, 15, 0));
        assertEq(dayId, clock.daysFromCivil(2026, 10, 6));
        assertTrue(trading);
        assertEq(secs, 11 hours);
        assertEq(closeAt, 16 hours);
        assertTrue(dst);
    }

    function test_setWindows() public {
        vm.prank(admin);
        clock.setWindows(10 minutes, 30 minutes, 30 minutes, 2 hours);
        assertEq(clock.closeBuffer(), 30 minutes);
        vm.startPrank(admin);
        vm.expectRevert(MarketClock.BadConfig.selector);
        clock.setWindows(2 hours, 30 minutes, 30 minutes, 2 hours);
        vm.expectRevert(MarketClock.BadConfig.selector);
        clock.setWindows(0, 10 minutes, 30 minutes, 2 hours); // closeBuffer < preClose
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0))
        );
        clock.setWindows(0, 10 minutes, 10 minutes, 1 hours);
    }
}
