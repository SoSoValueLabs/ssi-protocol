pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/AssetLocking.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";

contract AssetLockingTest is Test {
    MockToken public token;
    address owner = vm.addr(0x1);
    address user1 = vm.addr(0x2);
    address user2 = vm.addr(0x3);

    AssetLocking assetLocking;

    uint256 constant INITIAL_AMOUNT = 1000 * 10 ** 18;
    uint256 constant LOCK_LIMIT = 500 * 10 ** 18;
    uint48 constant COOLDOWN_PERIOD = 7 days;

    function setUp() public {
        // Create a mock token
        token = new MockToken("Test Token", "TEST", 18);

        // Deploy the AssetLocking contract
        vm.startPrank(owner);
        assetLocking = AssetLocking(
            address(new ERC1967Proxy(address(new AssetLocking()), abi.encodeCall(AssetLocking.initialize, owner)))
        );

        // Set the lock configuration
        assetLocking.updateLockConfig(address(token), 1, LOCK_LIMIT, COOLDOWN_PERIOD);
        assetLocking.setEpoch(address(token), 1);

        // Mint tokens for test users
        token.mint(user1, INITIAL_AMOUNT);
        token.mint(user2, INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function test_Initialize() public {
        assertEq(assetLocking.owner(), owner);
        assertEq(assetLocking.paused(), false);
    }

    function test_UpdateLockConfig() public {
        vm.startPrank(owner);

        // Test updating the lock configuration
        assetLocking.updateLockConfig(address(token), 2, LOCK_LIMIT * 2, COOLDOWN_PERIOD * 2);

        // Verify that the configuration has been updated
        (uint8 epoch, uint256 lockLimit, uint48 cooldown, uint256 totalLock, uint256 totalCooldown) =
            assetLocking.lockConfigs(address(token));
        assertEq(epoch, 2);
        assertEq(lockLimit, LOCK_LIMIT * 2);
        assertEq(cooldown, COOLDOWN_PERIOD * 2);
        assertEq(totalLock, 0);
        assertEq(totalCooldown, 0);

        // Test exceeding the maximum cooldown period
        vm.expectRevert("cooldown exceeds MAX_COOLDOWN");
        assetLocking.updateLockConfig(address(token), 3, LOCK_LIMIT, 91 days);

        vm.stopPrank();
    }

    function test_SetEpoch() public {
        vm.startPrank(owner);

        // Test setting a new epoch
        assetLocking.activeEpochs(address(token));
        assetLocking.setEpoch(address(token), 2);
        assertEq(assetLocking.activeEpochs(address(token)), 2);

        // Test setting the same epoch
        vm.expectRevert("epoch not change");
        assetLocking.setEpoch(address(token), 2);

        vm.stopPrank();
    }

    function test_GetActiveTokens() public {
        // Create another token and set a different epoch
        MockToken token2 = new MockToken("Test Token 2", "TEST2", 18);

        vm.startPrank(owner);
        assetLocking.updateLockConfig(address(token2), 2, LOCK_LIMIT, COOLDOWN_PERIOD);
        assetLocking.setEpoch(address(token2), 2);

        // Get the list of active tokens
        address[] memory activeTokens = assetLocking.getActiveTokens();
        assertEq(activeTokens.length, 2);

        // Set the epoch of token2 to a value different from the configuration
        assetLocking.setEpoch(address(token2), 3);

        // Get the list of active tokens again
        activeTokens = assetLocking.getActiveTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], address(token));

        vm.stopPrank();
    }

    function test_Lock() public {
        uint256 lockAmount = 100 * 10 ** 18;

        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();

        // Verify the lock status
        (uint256 amount, uint256 cooldownAmount, uint256 cooldownEndTimestamp) =
            assetLocking.lockDatas(address(token), user1);
        assertEq(amount, lockAmount);
        assertEq(cooldownAmount, 0);
        assertEq(cooldownEndTimestamp, 0);

        // Verify the contract's token balance
        assertEq(token.balanceOf(address(assetLocking)), lockAmount);

        // Verify the total locked amount in the lock configuration
        (,,, uint256 totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, lockAmount);
    }

    function test_LockFailures() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // Test locking an amount of 0
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.lock(address(token), 0);
        vm.stopPrank();

        // Test locking an unsupported token
        MockToken unsupportedToken = new MockToken("Unsupported", "UNS", 18);
        unsupportedToken.mint(user1, INITIAL_AMOUNT);

        vm.startPrank(user1);
        unsupportedToken.approve(address(assetLocking), lockAmount);
        vm.expectRevert("token not supported");
        assetLocking.lock(address(unsupportedToken), lockAmount);
        vm.stopPrank();

        // Test epoch mismatch
        vm.startPrank(owner);
        assetLocking.setEpoch(address(token), 2);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("token cannot stake now");
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();

        // Restore epoch
        vm.startPrank(owner);
        assetLocking.setEpoch(address(token), 1);
        vm.stopPrank();

        // Test exceeding the lock limit
        vm.startPrank(user1);
        token.approve(address(assetLocking), LOCK_LIMIT + 1);
        vm.expectRevert("total lock amount exceeds lock limit");
        assetLocking.lock(address(token), LOCK_LIMIT + 1);
        vm.stopPrank();

        // Test insufficient allowance
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount - 1);
        vm.expectRevert("not enough allowance");
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();
    }

    function test_Unlock() public {
        uint256 lockAmount = 100 * 10 ** 18;
        uint256 unlockAmount = 50 * 10 ** 18;

        // Lock tokens first
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);

        // Unlock part of the tokens
        assetLocking.unlock(address(token), unlockAmount);
        vm.stopPrank();

        // Verify the unlock status
        (uint256 amount, uint256 cooldownAmount, uint256 cooldownEndTimestamp) =
            assetLocking.lockDatas(address(token), user1);
        assertEq(amount, lockAmount - unlockAmount);
        assertEq(cooldownAmount, unlockAmount);
        assertEq(cooldownEndTimestamp, block.timestamp + COOLDOWN_PERIOD);

        // Verify the total locked and total cooldown amounts in the lock configuration
        (,,, uint256 totalLock, uint256 totalCooldown) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, lockAmount - unlockAmount);
        assertEq(totalCooldown, unlockAmount);
    }

    function test_UnlockFailures() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // Test unlocking an amount of 0
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.unlock(address(token), 0);
        vm.stopPrank();

        // Test unlocking with insufficient balance
        vm.startPrank(user1);
        vm.expectRevert("not enough balance to unlock");
        assetLocking.unlock(address(token), 1);
        vm.stopPrank();

        // Lock tokens first
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);

        // Test unlocking more than the locked amount
        vm.expectRevert("not enough balance to unlock");
        assetLocking.unlock(address(token), lockAmount + 1);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        uint256 lockAmount = 100 * 10 ** 18;
        uint256 unlockAmount = 50 * 10 ** 18;

        // Lock and unlock tokens first
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);
        assetLocking.unlock(address(token), unlockAmount);

        // Attempt to withdraw while still in the cooldown period
        vm.expectRevert("coolingdown");
        assetLocking.withdraw(address(token), unlockAmount);

        // Wait for the cooldown period to end
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // Withdraw tokens
        uint256 balanceBefore = token.balanceOf(user1);
        assetLocking.withdraw(address(token), unlockAmount);
        uint256 balanceAfter = token.balanceOf(user1);

        // Verify the state after withdrawal
        assertEq(balanceAfter - balanceBefore, unlockAmount);

        (uint256 amount, uint256 cooldownAmount,) = assetLocking.lockDatas(address(token), user1);
        assertEq(amount, lockAmount - unlockAmount);
        assertEq(cooldownAmount, 0);

        (,,, uint256 totalLock, uint256 totalCooldown) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, lockAmount - unlockAmount);
        assertEq(totalCooldown, 0);

        vm.stopPrank();
    }

    function test_WithdrawFailures() public {
        uint256 lockAmount = 100 * 10 ** 18;
        uint256 unlockAmount = 50 * 10 ** 18;

        // Test withdrawing an amount of 0
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.withdraw(address(token), 0);
        vm.stopPrank();

        // Test withdrawing with no balance to withdraw
        vm.startPrank(user1);
        vm.expectRevert("nothing to withdraw");
        assetLocking.withdraw(address(token), 1);
        vm.stopPrank();

        // Lock and unlock tokens first
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);
        assetLocking.unlock(address(token), unlockAmount);

        // Test withdrawing more than the cooldown amount
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        vm.expectRevert("no enough balance to withdraw");
        assetLocking.withdraw(address(token), unlockAmount + 1);
        vm.stopPrank();
    }

    function test_Pause() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // Pause the contract
        vm.startPrank(owner);
        assetLocking.pause();
        vm.stopPrank();

        // Test operations while the contract is paused
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.lock(address(token), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.unlock(address(token), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.withdraw(address(token), lockAmount);

        vm.stopPrank();

        // Unpause the contract
        vm.startPrank(owner);
        assetLocking.unpause();
        vm.stopPrank();

        // Test operations after unpausing
        vm.startPrank(user1);
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();

        // Verify the lock success
        (uint256 amount,,) = assetLocking.lockDatas(address(token), user1);
        console.log("amount", amount);
        console.log("lockAmount", lockAmount);
        assertEq(amount, lockAmount);
    }

    function test_MultipleUsers() public {
        uint256 user1LockAmount = 100 * 10 ** 18;
        uint256 user2LockAmount = 200 * 10 ** 18;

        // User 1 locks tokens
        vm.startPrank(user1);
        token.approve(address(assetLocking), user1LockAmount);
        assetLocking.lock(address(token), user1LockAmount);
        vm.stopPrank();

        // User 2 locks tokens
        vm.startPrank(user2);
        token.approve(address(assetLocking), user2LockAmount);
        assetLocking.lock(address(token), user2LockAmount);
        vm.stopPrank();

        // Verify the total locked amount
        (,,, uint256 totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, user1LockAmount + user2LockAmount);

        // User 1 unlocks and withdraws
        vm.startPrank(user1);
        assetLocking.unlock(address(token), user1LockAmount);
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        assetLocking.withdraw(address(token), user1LockAmount);
        vm.stopPrank();

        // Verify User 1's state
        (uint256 amount1, uint256 cooldownAmount1,) = assetLocking.lockDatas(address(token), user1);
        assertEq(amount1, 0);
        assertEq(cooldownAmount1, 0);

        // Verify User 2's state remains unchanged
        (uint256 amount2,,) = assetLocking.lockDatas(address(token), user2);
        assertEq(amount2, user2LockAmount);

        // Verify the total locked amount only includes User 2's locked amount
        (,,, totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, user2LockAmount);
    }
}
