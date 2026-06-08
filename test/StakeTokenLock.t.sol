// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/StakeToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract StakeTokenLockTest is Test {
    address owner = vm.addr(0x1);
    address locker = vm.addr(0x2);
    address staker = vm.addr(0x10);
    address staker2 = vm.addr(0x11);

    StakeToken stakeToken;

    uint256 constant STAKE_AMOUNT = 10 ether;

    function setUp() public {
        vm.deal(staker, 100 ether);
        vm.deal(staker2, 100 ether);

        vm.startPrank(owner);
        StakeToken impl = new StakeToken();
        stakeToken = StakeToken(payable(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(StakeToken.initialize, ("Staked SOSO", "sSOSO", address(0), 3600 * 24 * 7, owner))
        ))));
        stakeToken.grantLockerRole(locker);
        vm.stopPrank();

        vm.prank(staker);
        stakeToken.stake{value: STAKE_AMOUNT}(STAKE_AMOUNT);

        vm.prank(staker2);
        stakeToken.stake{value: STAKE_AMOUNT}(STAKE_AMOUNT);
    }

    // ========== Locker Role Tests ==========

    function testGrantLockerRole() public {
        address newLocker = vm.addr(0x99);
        assertFalse(stakeToken.lockers(newLocker));

        vm.prank(owner);
        stakeToken.grantLockerRole(newLocker);

        assertTrue(stakeToken.lockers(newLocker));
    }

    function testRevokeLockerRole() public {
        assertTrue(stakeToken.lockers(locker));

        vm.prank(owner);
        stakeToken.revokeLockerRole(locker);

        assertFalse(stakeToken.lockers(locker));
    }

    function testGrantLockerRoleOnlyOwner() public {
        vm.prank(staker);
        vm.expectRevert();
        stakeToken.grantLockerRole(staker);
    }

    function testRevokeLockerRoleOnlyOwner() public {
        vm.prank(staker);
        vm.expectRevert();
        stakeToken.revokeLockerRole(locker);
    }

    // ========== Lock Access Control ==========

    function testLockOnlyLocker() public {
        vm.prank(staker);
        vm.expectRevert("not locker");
        stakeToken.lock(staker, 1 ether, block.timestamp + 1 hours);
    }

    // ========== Basic Lock Tests ==========

    function testLockBasic() public {
        uint256 lockAmount = 3 ether;
        uint256 expiry = block.timestamp + 1 hours;

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT);

        vm.prank(locker);
        stakeToken.lock(staker, lockAmount, expiry);

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - lockAmount);

        StakeToken.Lock[] memory locks = stakeToken.getActiveLocks(staker);
        assertEq(locks.length, 1);
        assertEq(locks[0].amount, lockAmount);
        assertEq(locks[0].expiry, expiry);
    }

    function testLockMultiple() public {
        uint256 lock1 = 2 ether;
        uint256 lock2 = 3 ether;
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(locker);
        stakeToken.lock(staker, lock1, expiry);
        stakeToken.lock(staker, lock2, expiry + 1 hours);
        vm.stopPrank();

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - lock1 - lock2);

        StakeToken.Lock[] memory locks = stakeToken.getActiveLocks(staker);
        assertEq(locks.length, 2);
    }

    function testLockExpiry() public {
        uint256 lockAmount = 5 ether;
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(locker);
        stakeToken.lock(staker, lockAmount, expiry);

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - lockAmount);

        vm.warp(expiry + 1);

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT);

        StakeToken.Lock[] memory locks = stakeToken.getActiveLocks(staker);
        assertEq(locks.length, 0);
    }

    // ========== Transfer / Unstake Blocked When Locked ==========

    function testTransferBlockedWhenLocked() public {
        vm.prank(locker);
        stakeToken.lock(staker, 8 ether, block.timestamp + 1 hours);

        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(StakeToken.InsufficientAvailableBalance.selector, staker, 2 ether, 5 ether)
        );
        stakeToken.transfer(staker2, 5 ether);
    }

    function testTransferAllowedUpToAvailable() public {
        vm.prank(locker);
        stakeToken.lock(staker, 7 ether, block.timestamp + 1 hours);

        uint256 available = stakeToken.getAvailableBalance(staker);
        assertEq(available, 3 ether);

        vm.prank(staker);
        stakeToken.transfer(staker2, 3 ether);

        assertEq(stakeToken.balanceOf(staker), 7 ether);
        assertEq(stakeToken.balanceOf(staker2), STAKE_AMOUNT + 3 ether);
    }

    function testUnstakeBlockedWhenLocked() public {
        vm.prank(locker);
        stakeToken.lock(staker, 8 ether, block.timestamp + 1 hours);

        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(StakeToken.InsufficientAvailableBalance.selector, staker, 2 ether, 5 ether)
        );
        stakeToken.unstake(5 ether);
    }

    function testUnstakeAllowedUpToAvailable() public {
        vm.prank(locker);
        stakeToken.lock(staker, 7 ether, block.timestamp + 1 hours);

        vm.prank(staker);
        stakeToken.unstake(3 ether);

        assertEq(stakeToken.balanceOf(staker), 7 ether);
    }

    // ========== Clean Expired Locks ==========

    function testCleanExpiredLocks() public {
        uint256 ts = block.timestamp;

        vm.startPrank(locker);
        stakeToken.lock(staker, 1 ether, ts + 1 hours);
        stakeToken.lock(staker, 2 ether, ts + 2 hours);
        vm.stopPrank();

        StakeToken.Lock[] memory locksBefore = stakeToken.getActiveLocks(staker);
        assertEq(locksBefore.length, 2);

        vm.warp(ts + 1 hours + 1);

        vm.prank(locker);
        stakeToken.lock(staker, 1 ether, ts + 3 hours);

        StakeToken.Lock[] memory locksAfter = stakeToken.getActiveLocks(staker);
        assertEq(locksAfter.length, 2);
        assertEq(locksAfter[0].amount, 2 ether);
        assertEq(locksAfter[1].amount, 1 ether);
    }

    // ========== Available Balance Edge Cases ==========

    function testGetAvailableBalanceFullyLocked() public {
        vm.prank(locker);
        stakeToken.lock(staker, STAKE_AMOUNT, block.timestamp + 1 hours);

        assertEq(stakeToken.getAvailableBalance(staker), 0);
    }

    function testGetAvailableBalanceOverLocked() public {
        vm.prank(locker);
        stakeToken.lock(staker, STAKE_AMOUNT + 5 ether, block.timestamp + 1 hours);

        assertEq(stakeToken.getAvailableBalance(staker), 0);
    }

    function testGetAvailableBalanceNoLocks() public {
        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT);
    }

    function testGetAvailableBalanceNoBalance() public {
        address nobody = vm.addr(0x999);
        assertEq(stakeToken.getAvailableBalance(nobody), 0);
    }

    // ========== Events ==========

    function testLockEmitsEvent() public {
        uint256 amount = 3 ether;
        uint256 expiry = block.timestamp + 1 hours;

        vm.expectEmit(true, false, false, true);
        emit StakeToken.Locked(staker, amount, expiry);

        vm.prank(locker);
        stakeToken.lock(staker, amount, expiry);
    }

    function testGrantLockerRoleEmitsEvent() public {
        address newLocker = vm.addr(0x99);

        vm.expectEmit(true, false, false, false);
        emit StakeToken.LockerRoleGranted(newLocker);

        vm.prank(owner);
        stakeToken.grantLockerRole(newLocker);
    }

    function testRevokeLockerRoleEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit StakeToken.LockerRoleRevoked(locker);

        vm.prank(owner);
        stakeToken.revokeLockerRole(locker);
    }

    // ========== Max Active Locks Tests ==========

    function testLockExceedsMaxActiveLocks() public {
        uint256 maxLocks = stakeToken.MAX_ACTIVE_LOCKS();
        uint256 lockAmount = 1;
        uint256 expiry = block.timestamp + 1 days;

        vm.startPrank(locker);
        for (uint256 i; i < maxLocks; i++) {
            stakeToken.lock(staker, lockAmount, expiry + i);
        }
        vm.expectRevert(abi.encodeWithSelector(StakeToken.TooManyActiveLocks.selector, staker, maxLocks));
        stakeToken.lock(staker, lockAmount, expiry + maxLocks);
        vm.stopPrank();
    }

    function testLockAllowsNewAfterExpiredCleanup() public {
        uint256 maxLocks = stakeToken.MAX_ACTIVE_LOCKS();
        uint256 lockAmount = 1;
        uint256 expiry = block.timestamp + 1 hours;

        vm.startPrank(locker);
        for (uint256 i; i < maxLocks; i++) {
            stakeToken.lock(staker, lockAmount, expiry);
        }
        vm.stopPrank();

        vm.warp(expiry + 1);

        vm.prank(locker);
        stakeToken.lock(staker, lockAmount, block.timestamp + 1 hours);
    }

    // ========== Releasable Balance Lock (lock/unlock by amount) ==========

    function testBalanceLockBasic() public {
        uint256 amount = 4 ether;

        vm.prank(locker);
        stakeToken.lock(staker, amount);

        assertEq(stakeToken.lockedBalances(locker, staker), amount);
        assertEq(stakeToken.lockedTotals(staker), amount);
        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - amount);
    }

    function testBalanceLockOnlyLocker() public {
        vm.prank(staker);
        vm.expectRevert("not locker");
        stakeToken.lock(staker, 1 ether);
    }

    function testBalanceLockZeroAmount() public {
        vm.prank(locker);
        vm.expectRevert("amount is zero");
        stakeToken.lock(staker, 0);
    }

    function testBalanceLockInsufficientAvailable() public {
        vm.prank(locker);
        vm.expectRevert("insufficient available");
        stakeToken.lock(staker, STAKE_AMOUNT + 1);
    }

    function testBalanceLockUnlockFull() public {
        uint256 amount = 6 ether;

        vm.startPrank(locker);
        stakeToken.lock(staker, amount);
        stakeToken.unlock(staker, amount);
        vm.stopPrank();

        assertEq(stakeToken.lockedBalances(locker, staker), 0);
        assertEq(stakeToken.lockedTotals(staker), 0);
        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT);
    }

    function testBalanceUnlockPartial() public {
        vm.startPrank(locker);
        stakeToken.lock(staker, 6 ether);
        stakeToken.unlock(staker, 2 ether);
        vm.stopPrank();

        assertEq(stakeToken.lockedBalances(locker, staker), 4 ether);
        assertEq(stakeToken.lockedTotals(staker), 4 ether);
        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - 4 ether);
    }

    function testBalanceUnlockExceeds() public {
        vm.startPrank(locker);
        stakeToken.lock(staker, 3 ether);
        vm.expectRevert("exceeds locked");
        stakeToken.unlock(staker, 4 ether);
        vm.stopPrank();
    }

    function testBalanceUnlockScopedToLocker() public {
        address locker2 = vm.addr(0x77);
        vm.prank(owner);
        stakeToken.grantLockerRole(locker2);

        vm.prank(locker);
        stakeToken.lock(staker, 3 ether);

        // locker2 never locked anything for staker, so it cannot unlock locker's lock.
        vm.prank(locker2);
        vm.expectRevert("exceeds locked");
        stakeToken.unlock(staker, 3 ether);
    }

    function testBalanceLockCombinesWithExpiryLock() public {
        vm.startPrank(locker);
        stakeToken.lock(staker, 3 ether, block.timestamp + 1 hours); // expiry lock
        stakeToken.lock(staker, 2 ether);                            // balance lock
        vm.stopPrank();

        assertEq(stakeToken.getAvailableBalance(staker), STAKE_AMOUNT - 5 ether);
    }

    function testBalanceLockBlocksTransfer() public {
        vm.prank(locker);
        stakeToken.lock(staker, 8 ether);

        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(StakeToken.InsufficientAvailableBalance.selector, staker, 2 ether, 5 ether)
        );
        stakeToken.transfer(staker2, 5 ether);
    }

    function testBalanceLockBlocksUnstake() public {
        vm.prank(locker);
        stakeToken.lock(staker, 8 ether);

        vm.prank(staker);
        vm.expectRevert(
            abi.encodeWithSelector(StakeToken.InsufficientAvailableBalance.selector, staker, 2 ether, 5 ether)
        );
        stakeToken.unstake(5 ether);
    }

    function testBalanceLockEmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit StakeToken.BalanceLocked(locker, staker, 3 ether);

        vm.prank(locker);
        stakeToken.lock(staker, 3 ether);
    }

    function testBalanceUnlockEmitsEvent() public {
        vm.prank(locker);
        stakeToken.lock(staker, 3 ether);

        vm.expectEmit(true, true, false, true);
        emit StakeToken.BalanceUnlocked(locker, staker, 3 ether);

        vm.prank(locker);
        stakeToken.unlock(staker, 3 ether);
    }

    receive() external payable {}
}
