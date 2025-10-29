// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/Interface.sol";
import "../src/StakeFactory.sol";
import "../src/StakeToken.sol";
import "../src/AssetFactory.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

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
        (uint256 cooldownAmount, uint256 cooldownEndTimestamp) = stakeToken.cooldownInfos(staker);
        assertEq(cooldownAmount, unstakeAmount);
        assertEq(cooldownEndTimestamp, block.timestamp + stakeToken.cooldown());
        // 检查余额
        assertEq(stakeToken.balanceOf(staker), stakeAmount - unstakeAmount);
        assertEq(stakeToken.totalSupply(), stakeAmount - unstakeAmount);
        assertEq(address(stakeToken).balance, stakeAmount);

        // withdraw - 在cooldown期间应该失败
        vm.startPrank(staker);
        vm.expectRevert("cooldowning");
        stakeToken.withdraw(cooldownAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + stakeToken.cooldown());

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
        vm.warp(block.timestamp + 3600*24*7);
        vm.expectRevert("cooldowning");
        vm.prank(staker);
        stakeToken.withdraw(unstakeAmount);
        // 再过7天后提取成功
        vm.warp(block.timestamp + 3600*24*7);
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
        vm.warp(block.timestamp + stakeToken.cooldown());
        stakeToken.withdraw(remainingStaked);
        vm.stopPrank();

        // 现在余额应该完全恢复
        assertEq(staker.balance, initialBalance);
        assertEq(stakeToken.balanceOf(staker), 0);
        assertEq(address(stakeToken).balance, 0);
    }

    receive() external payable {}
}

