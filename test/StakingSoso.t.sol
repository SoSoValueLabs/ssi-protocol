// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/Interface.sol";
import "../src/StakeFactory.sol";
import "../src/StakeToken.sol";
import "../src/AssetFactory.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Upgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import "forge-std/StdCheats.sol";
import {Test, console} from "forge-std/Test.sol";

contract StakingSOSOTest is Test {
    address owner = vm.addr(0x1);
    address vault = vm.addr(0x2);
    address staker = vm.addr(0x10);

    AssetFactory factory;
    StakeFactory stakeFactory;
    StakeToken stakeToken;

    uint256 stakeAmount = 10 ether; // 使用ETH作为单位

    function setUp() public {
        // 给staker一些ETH用于测试
        vm.deal(staker, 100 ether);
        
        // 部署Factory
        vm.startPrank(owner);
        AssetToken tokenImpl = new AssetToken();
        AssetFactory factoryImpl = new AssetFactory();
        address factoryAddress = address(new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(AssetFactory.initialize, (owner, vault, "SETH", address(tokenImpl)))
        ));
        factory = AssetFactory(factoryAddress);
        
        // 部署StakeFactory
        StakeToken stakeTokenImpl = new StakeToken();
        StakeFactory stakeFactoryImpl = new StakeFactory();
        address stakeFactoryAddress = address(new ERC1967Proxy(
            address(stakeFactoryImpl),
            abi.encodeCall(StakeFactory.initialize, (owner, address(factory), address(stakeTokenImpl)))
        ));
        stakeFactory = StakeFactory(stakeFactoryAddress);
        vm.stopPrank();
    }

    function testNativeTokenStakeUnstakeWithdraw() public {
        // 创建stake token，token地址为address(0)表示native token
        vm.startPrank(owner);
        address stakeTokenImpl = address(new StakeToken());
        address stakeTokenProxy = address(new ERC1967Proxy(
            stakeTokenImpl,
            abi.encodeCall(StakeToken.initialize, (
                "Staked SOSO",
                "sSOSO",
                address(0), // native token
                3600*24*7,  // 7天cooldown
                owner
            ))
        ));
        stakeToken = StakeToken(payable(stakeTokenProxy));
        assertEq(stakeToken.token(), address(0));
        assertEq(stakeToken.decimals(), 18);
        vm.stopPrank();

        // 测试 pause
        vm.startPrank(owner);
        stakeToken.pause();
        vm.stopPrank();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(staker);
        stakeToken.stake{value: stakeAmount}(stakeAmount);
        vm.startPrank(owner);
        stakeToken.unpause();
        vm.stopPrank();

        // stake ETH
        vm.startPrank(staker);
        uint256 initialBalance = staker.balance;
        stakeToken.stake{value: stakeAmount}(stakeAmount);
        // 测试错误情况：msg.value不等于amount
        vm.expectRevert("value must equal amount");
        stakeToken.stake{value: 1 ether}(2 ether);
        vm.stopPrank();
        // 检查余额
        assertEq(staker.balance, initialBalance - stakeAmount);
        assertEq(stakeToken.balanceOf(staker), stakeAmount);
        assertEq(stakeToken.totalSupply(), stakeAmount);
        assertEq(address(stakeToken).balance, stakeAmount);

        // unstake 50%
        vm.startPrank(staker);
        uint256 unstakeAmount = stakeAmount * 50 / 100;
        stakeToken.unstake(unstakeAmount);
        vm.stopPrank();
        uint256 ts = block.timestamp;
        (uint256 cooldownAmount, uint256 cooldownEndTimestamp) = stakeToken.cooldownInfos(staker);
        assertEq(cooldownAmount, unstakeAmount);
        assertEq(cooldownEndTimestamp, ts + stakeToken.cooldown());
        // 检查余额
        assertEq(stakeToken.balanceOf(staker), stakeAmount - unstakeAmount);
        assertEq(stakeToken.totalSupply(), stakeAmount - unstakeAmount);
        assertEq(address(stakeToken).balance, stakeAmount);

        // withdraw - 在cooldown期间应该失败
        vm.startPrank(staker);
        vm.expectRevert("cooldowning");
        stakeToken.withdraw(cooldownAmount);
        vm.stopPrank();
        ts += stakeToken.cooldown();
        vm.warp(ts);

        // 更新cooldown时长
        vm.startPrank(owner);
        stakeToken.setCooldown(3600*24*14); // 改为14天
        assertEq(stakeToken.cooldown(), 3600*24*14);
        vm.stopPrank();

        // withdraw成功
        vm.startPrank(staker);
        stakeToken.withdraw(cooldownAmount);
        vm.stopPrank();
        // 检查余额
        assertEq(staker.balance, initialBalance - stakeAmount + unstakeAmount);
        assertEq(stakeToken.balanceOf(staker), stakeAmount - unstakeAmount);
        assertEq(stakeToken.totalSupply(), stakeAmount - unstakeAmount);
        assertEq(address(stakeToken).balance, stakeAmount - unstakeAmount);

        // 再次stake来测试新的cooldown时长
        vm.startPrank(staker);
        stakeToken.stake{value: unstakeAmount}(unstakeAmount);
        stakeToken.unstake(unstakeAmount);
        vm.stopPrank();
        // 7天后尝试提取，应该失败（因为cooldown现在是14天）
        ts += 3600*24*7;
        vm.warp(ts);
        vm.expectRevert("cooldowning");
        vm.prank(staker);
        stakeToken.withdraw(unstakeAmount);
        // 再过7天后提取成功
        ts += 3600*24*7;
        vm.warp(ts);
        vm.startPrank(staker);
        stakeToken.withdraw(unstakeAmount);
        vm.stopPrank();

        // 最终余额检查（还有一半锁在stake token中）
        uint256 remainingStaked = stakeAmount - unstakeAmount;
        assertEq(staker.balance, initialBalance - remainingStaked);
        assertEq(stakeToken.balanceOf(staker), remainingStaked);

        // 完整取出所有资金
        vm.startPrank(staker);
        stakeToken.unstake(remainingStaked);
        ts += stakeToken.cooldown();
        vm.warp(ts);
        stakeToken.withdraw(remainingStaked);
        vm.stopPrank();

        // 现在余额应该完全恢复
        assertEq(staker.balance, initialBalance);
        assertEq(stakeToken.balanceOf(staker), 0);
        assertEq(address(stakeToken).balance, 0);
    }

    /// @notice Fork test for upgrading StakeToken with ReentrancyGuard
    /// @dev This test forks a network and tests upgrading StakeToken to include ReentrancyGuard
    function testForkUpgradeStakeToken() public {
        // Read fork URL and block number from environment variables
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        uint256 forkBlock = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        
        // Skip test if fork URL is not provided
        if (bytes(forkUrl).length == 0 || forkBlock == 0) {
            console.log("Skipping fork test: FORK_URL or FORK_BLOCK_NUMBER not set");
            return;
        }

        // Create fork at specified block
        vm.createSelectFork(forkUrl);
        vm.rollFork(forkBlock);

        // Read StakeToken address from environment (optional, if not provided, create new one)
        address stakeTokenAddress = vm.envOr("FORK_STAKE_TOKEN_ADDRESS", address(0));
        address ownerAddress = vm.envOr("FORK_OWNER_ADDRESS", address(0));

        StakeToken stakeTokenProxy;
        address forkOwner;

        if (stakeTokenAddress != address(0) && ownerAddress != address(0)) {
            // Use existing StakeToken from fork
            stakeTokenProxy = StakeToken(payable(stakeTokenAddress));
            forkOwner = ownerAddress;
            console.log("Using existing StakeToken at:", stakeTokenAddress);
            console.log("Owner:", forkOwner);
        } else {
            // Create new StakeToken for testing
            forkOwner = vm.addr(0x1);
            vm.deal(forkOwner, 100 ether);
            
            vm.startPrank(forkOwner);
            StakeToken stakeTokenImpl = new StakeToken();
            stakeTokenProxy = StakeToken(payable(address(new ERC1967Proxy(
                address(stakeTokenImpl),
                abi.encodeCall(StakeToken.initialize, (
                    "Staked SOSO",
                    "sSOSO",
                    address(0), // native token
                    3600*24*7,  // 7 days cooldown
                    forkOwner
                ))
            ))));
            vm.stopPrank();
            console.log("Created new StakeToken at:", address(stakeTokenProxy));
        }

        // Record initial state before any test operations
        string memory nameBefore = stakeTokenProxy.name();
        string memory symbolBefore = stakeTokenProxy.symbol();
        address tokenBefore = stakeTokenProxy.token();
        uint48 cooldownBefore = stakeTokenProxy.cooldown();
        uint256 initialTotalSupply = stakeTokenProxy.totalSupply();

        console.log("Initial state:");
        console.log("  Implementation:", Upgrades.getImplementationAddress(address(stakeTokenProxy)));
        console.log("  Name:", nameBefore);
        console.log("  Symbol:", symbolBefore);
        console.log("  Initial Total Supply:", initialTotalSupply);

        // Test that functions work before upgrade
        address testStaker = vm.addr(0x100);
        vm.deal(testStaker, 10 ether);

        vm.startPrank(testStaker);
        stakeTokenProxy.stake{value: 1 ether}(1 ether);
        assertEq(stakeTokenProxy.balanceOf(testStaker), 1 ether, "Stake should work before upgrade");
        vm.stopPrank();

        // Record state after test operations but before upgrade
        uint256 totalSupplyBeforeUpgrade = stakeTokenProxy.totalSupply();
        assertEq(totalSupplyBeforeUpgrade, initialTotalSupply + 1 ether, "Total supply should increase after stake");

        console.log("Before upgrade (after test operations):");
        console.log("  Total Supply:", totalSupplyBeforeUpgrade);

        // Deploy new implementation and upgrade
        {
            vm.startPrank(forkOwner);
            StakeToken newImplementation = new StakeToken();
            address newImplAddress = address(newImplementation);
            console.log("New implementation:", newImplAddress);
            stakeTokenProxy.upgradeToAndCall(newImplAddress, "");
            vm.stopPrank();

            address newImplementationAddress = Upgrades.getImplementationAddress(address(stakeTokenProxy));
            assertEq(newImplementationAddress, newImplAddress, "Implementation should be upgraded");
            console.log("Upgrade successful, new implementation:", newImplementationAddress);
        }

        // Verify state is preserved
        assertEq(stakeTokenProxy.name(), nameBefore, "Name should be preserved");
        assertEq(stakeTokenProxy.symbol(), symbolBefore, "Symbol should be preserved");
        assertEq(stakeTokenProxy.token(), tokenBefore, "Token address should be preserved");
        assertEq(stakeTokenProxy.cooldown(), cooldownBefore, "Cooldown should be preserved");
        assertEq(stakeTokenProxy.totalSupply(), totalSupplyBeforeUpgrade, "Total supply should be preserved");
        assertEq(stakeTokenProxy.balanceOf(testStaker), 1 ether, "User balance should be preserved");

        // Test that functions work after upgrade (with ReentrancyGuard)
        vm.startPrank(testStaker);
        stakeTokenProxy.stake{value: 1 ether}(1 ether);
        assertEq(stakeTokenProxy.balanceOf(testStaker), 2 ether, "Stake should work after upgrade");

        stakeTokenProxy.unstake(1 ether);
        {
            (uint256 cooldownAmount, uint256 cooldownEndTimestamp) = stakeTokenProxy.cooldownInfos(testStaker);
            assertGt(cooldownAmount, 0, "Cooldown amount should be set");
            assertGt(cooldownEndTimestamp, block.timestamp, "Cooldown end timestamp should be set");
            vm.warp(cooldownEndTimestamp);
        }

        {
            uint256 balanceBeforeWithdraw = testStaker.balance;
            stakeTokenProxy.withdraw(1 ether);
            assertEq(testStaker.balance, balanceBeforeWithdraw + 1 ether, "Withdraw should work after upgrade");
        }
        vm.stopPrank();

        // Test pause/unpause still works
        vm.startPrank(forkOwner);
        stakeTokenProxy.pause();
        assertTrue(stakeTokenProxy.paused(), "Contract should be paused");
        stakeTokenProxy.unpause();
        assertFalse(stakeTokenProxy.paused(), "Contract should be unpaused");
        vm.stopPrank();

        vm.startPrank(testStaker);
        stakeTokenProxy.stake{value: 1 ether}(1 ether);
        vm.stopPrank();

        console.log("All upgrade tests passed!");
    }

    receive() external payable {}
}

