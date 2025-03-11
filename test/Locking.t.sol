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
        // 创建模拟代币
        token = new MockToken("Test Token", "TEST", 18);

        // 部署AssetLocking合约
        vm.startPrank(owner);
        assetLocking = AssetLocking(
            address(new ERC1967Proxy(address(new AssetLocking()), abi.encodeCall(AssetLocking.initialize, owner)))
        );

        // 设置锁定配置
        assetLocking.updateLockConfig(address(token), 1, LOCK_LIMIT, COOLDOWN_PERIOD);
        assetLocking.setEpoch(address(token), 1);

        // 给测试用户铸造代币
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

        // 测试更新锁定配置
        assetLocking.updateLockConfig(address(token), 2, LOCK_LIMIT * 2, COOLDOWN_PERIOD * 2);

        // 验证配置已更新
        (uint8 epoch, uint256 lockLimit, uint48 cooldown, uint256 totalLock, uint256 totalCooldown) =
            assetLocking.lockConfigs(address(token));
        assertEq(epoch, 2);
        assertEq(lockLimit, LOCK_LIMIT * 2);
        assertEq(cooldown, COOLDOWN_PERIOD * 2);
        assertEq(totalLock, 0);
        assertEq(totalCooldown, 0);

        // 测试超过最大冷却期限的情况
        vm.expectRevert("cooldown exceeds MAX_COOLDOWN");
        assetLocking.updateLockConfig(address(token), 3, LOCK_LIMIT, 91 days);

        vm.stopPrank();
    }

    function test_SetEpoch() public {
        vm.startPrank(owner);

        // 测试设置新的epoch
        assetLocking.activeEpochs(address(token));
        assetLocking.setEpoch(address(token), 2);
        assertEq(assetLocking.activeEpochs(address(token)), 2);

        // 测试设置相同的epoch
        vm.expectRevert("epoch not change");
        assetLocking.setEpoch(address(token), 2);

        vm.stopPrank();
    }

    function test_GetActiveTokens() public {
        // 创建另一个代币并设置不同的epoch
        MockToken token2 = new MockToken("Test Token 2", "TEST2", 18);

        vm.startPrank(owner);
        assetLocking.updateLockConfig(address(token2), 2, LOCK_LIMIT, COOLDOWN_PERIOD);
        assetLocking.setEpoch(address(token2), 2);

        // 获取活跃的代币列表
        address[] memory activeTokens = assetLocking.getActiveTokens();
        assertEq(activeTokens.length, 2);

        // 将token2的epoch设置为与配置不同的值
        assetLocking.setEpoch(address(token2), 3);

        // 再次获取活跃的代币列表
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

        // 验证锁定状态
        (uint256 amount, uint256 cooldownAmount, uint256 cooldownEndTimestamp) =
            assetLocking.lockDatas(address(token), user1);
        assertEq(amount, lockAmount);
        assertEq(cooldownAmount, 0);
        assertEq(cooldownEndTimestamp, 0);

        // 验证合约中的代币余额
        assertEq(token.balanceOf(address(assetLocking)), lockAmount);

        // 验证锁定配置中的总锁定量
        (,,, uint256 totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, lockAmount);
    }

    function test_LockFailures() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // 测试锁定金额为0的情况
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.lock(address(token), 0);
        vm.stopPrank();

        // 测试锁定不支持的代币
        MockToken unsupportedToken = new MockToken("Unsupported", "UNS", 18);
        unsupportedToken.mint(user1, INITIAL_AMOUNT);

        vm.startPrank(user1);
        unsupportedToken.approve(address(assetLocking), lockAmount);
        vm.expectRevert("token not supported");
        assetLocking.lock(address(unsupportedToken), lockAmount);
        vm.stopPrank();

        // 测试epoch不匹配的情况
        vm.startPrank(owner);
        assetLocking.setEpoch(address(token), 2);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("token cannot stake now");
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();

        // 恢复epoch
        vm.startPrank(owner);
        assetLocking.setEpoch(address(token), 1);
        vm.stopPrank();

        // 测试超过锁定限制的情况
        vm.startPrank(user1);
        token.approve(address(assetLocking), LOCK_LIMIT + 1);
        vm.expectRevert("total lock amount exceeds lock limit");
        assetLocking.lock(address(token), LOCK_LIMIT + 1);
        vm.stopPrank();

        // 测试授权不足的情况
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount - 1);
        vm.expectRevert("not enough allowance");
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();
    }

    function test_Unlock() public {
        uint256 lockAmount = 100 * 10 ** 18;
        uint256 unlockAmount = 50 * 10 ** 18;

        // 先锁定代币
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);

        // 解锁部分代币
        assetLocking.unlock(address(token), unlockAmount);
        vm.stopPrank();

        // 验证解锁状态
        (uint256 amount, uint256 cooldownAmount, uint256 cooldownEndTimestamp) =
            assetLocking.lockDatas(address(token), user1);
        assertEq(amount, lockAmount - unlockAmount);
        assertEq(cooldownAmount, unlockAmount);
        assertEq(cooldownEndTimestamp, block.timestamp + COOLDOWN_PERIOD);

        // 验证锁定配置中的总锁定量和总冷却量
        (,,, uint256 totalLock, uint256 totalCooldown) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, lockAmount - unlockAmount);
        assertEq(totalCooldown, unlockAmount);
    }

    function test_UnlockFailures() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // 测试解锁金额为0的情况
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.unlock(address(token), 0);
        vm.stopPrank();

        // 测试解锁余额不足的情况
        vm.startPrank(user1);
        vm.expectRevert("not enough balance to unlock");
        assetLocking.unlock(address(token), 1);
        vm.stopPrank();

        // 先锁定代币
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);

        // 测试解锁超过锁定量的情况
        vm.expectRevert("not enough balance to unlock");
        assetLocking.unlock(address(token), lockAmount + 1);
        vm.stopPrank();
    }

    function test_Withdraw() public {
        uint256 lockAmount = 100 * 10 ** 18;
        uint256 unlockAmount = 50 * 10 ** 18;

        // 先锁定并解锁代币
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);
        assetLocking.unlock(address(token), unlockAmount);

        // 尝试提取但还在冷却期
        vm.expectRevert("coolingdown");
        assetLocking.withdraw(address(token), unlockAmount);

        // 等待冷却期结束
        vm.warp(block.timestamp + COOLDOWN_PERIOD);

        // 提取代币
        uint256 balanceBefore = token.balanceOf(user1);
        assetLocking.withdraw(address(token), unlockAmount);
        uint256 balanceAfter = token.balanceOf(user1);

        // 验证提取后的状态
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

        // 测试提取金额为0的情况
        vm.startPrank(user1);
        vm.expectRevert("amount is zero");
        assetLocking.withdraw(address(token), 0);
        vm.stopPrank();

        // 测试没有可提取金额的情况
        vm.startPrank(user1);
        vm.expectRevert("nothing to withdraw");
        assetLocking.withdraw(address(token), 1);
        vm.stopPrank();

        // 先锁定并解锁代币
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);
        assetLocking.lock(address(token), lockAmount);
        assetLocking.unlock(address(token), unlockAmount);

        // 测试提取超过冷却量的情况
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        vm.expectRevert("no enough balance to withdraw");
        assetLocking.withdraw(address(token), unlockAmount + 1);
        vm.stopPrank();
    }

    function test_Pause() public {
        uint256 lockAmount = 100 * 10 ** 18;

        // 暂停合约
        vm.startPrank(owner);
        assetLocking.pause();
        vm.stopPrank();

        // 测试暂停状态下的操作
        vm.startPrank(user1);
        token.approve(address(assetLocking), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.lock(address(token), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.unlock(address(token), lockAmount);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        assetLocking.withdraw(address(token), lockAmount);

        vm.stopPrank();

        // 恢复合约
        vm.startPrank(owner);
        assetLocking.unpause();
        vm.stopPrank();

        // 测试恢复后的操作
        vm.startPrank(user1);
        assetLocking.lock(address(token), lockAmount);
        vm.stopPrank();

        // 验证锁定成功
        (uint256 amount,,) = assetLocking.lockDatas(address(token), user1);
        console.log("amount", amount);
        console.log("lockAmount", lockAmount);
        assertEq(amount, lockAmount);
    }

    function test_MultipleUsers() public {
        uint256 user1LockAmount = 100 * 10 ** 18;
        uint256 user2LockAmount = 200 * 10 ** 18;

        // 用户1锁定代币
        vm.startPrank(user1);
        token.approve(address(assetLocking), user1LockAmount);
        assetLocking.lock(address(token), user1LockAmount);
        vm.stopPrank();

        // 用户2锁定代币
        vm.startPrank(user2);
        token.approve(address(assetLocking), user2LockAmount);
        assetLocking.lock(address(token), user2LockAmount);
        vm.stopPrank();

        // 验证总锁定量
        (,,, uint256 totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, user1LockAmount + user2LockAmount);

        // 用户1解锁并提取
        vm.startPrank(user1);
        assetLocking.unlock(address(token), user1LockAmount);
        vm.warp(block.timestamp + COOLDOWN_PERIOD);
        assetLocking.withdraw(address(token), user1LockAmount);
        vm.stopPrank();

        // 验证用户1的状态
        (uint256 amount1, uint256 cooldownAmount1,) = assetLocking.lockDatas(address(token), user1);
        assertEq(amount1, 0);
        assertEq(cooldownAmount1, 0);

        // 验证用户2的状态不变
        (uint256 amount2,,) = assetLocking.lockDatas(address(token), user2);
        assertEq(amount2, user2LockAmount);

        // 验证总锁定量只包含用户2的锁定量
        (,,, totalLock,) = assetLocking.lockConfigs(address(token));
        assertEq(totalLock, user2LockAmount);
    }
}
