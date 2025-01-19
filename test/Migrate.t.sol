// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/Interface.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/Swap.sol";

contract MigrateTest is Test {
    address oldIssuerAddress = 0xdc74D8C5D9a900fdF8a6D03Ad419b236c9A1AD1d;
    address oldFeeManagerAddress = 0x996c93827Ab4C55B1044aDd903D2bDb0dcd546BA;
    address oldRebalancerAddress = 0x242626E1eCe44601A69d9BC3f72a755Eb393f4b1;
    address oldSwapAddress = 0x640cB7201810BC920835A598248c4fe4898Bb5e0;
    address owner = 0xd463D3d8333b7AD6a14d00e1700C80AF5A37F751;
    address factory = 0xb04eB6b64137d1673D46731C8f84718092c50B0D;
    AssetIssuer issuer;
    AssetRebalancer rebalancer;
    AssetFeeManager feeManager;
    Swap swap;

    function setUp() public {
        issuer = AssetIssuer(address(new ERC1967Proxy(
            address(new AssetIssuer()),
            abi.encodeCall(AssetController.initialize, (owner, address(factory)))
        )));
        rebalancer = AssetRebalancer(address(new ERC1967Proxy(
            address(new AssetRebalancer()),
            abi.encodeCall(AssetController.initialize, (owner, address(factory)))
        )));
        feeManager = AssetFeeManager(address(new ERC1967Proxy(
            address(new AssetFeeManager()),
            abi.encodeCall(AssetController.initialize, (owner, address(factory)))
        )));
        swap = Swap(address(new ERC1967Proxy(
            address(new Swap()),
            abi.encodeCall(Swap.initialize, (owner, "BASE_ETH"))
        )));
    }

    function testIssuerMigrate() public {
        IAssetIssuer oldIssuer = IAssetIssuer(oldIssuerAddress);
        vm.expectRevert();
        issuer.migrateFrom(oldIssuerAddress, 10, 50);
        vm.startPrank(owner);
        do {
            issuer.migrateFrom(oldIssuerAddress, 10, 50);
        } while (issuer.getMintRequestLength() < oldIssuer.getMintRequestLength() ||
            issuer.getRedeemRequestLength() < oldIssuer.getRedeemRequestLength());
        assertEq(issuer.getMintRequestLength(), oldIssuer.getMintRequestLength());
        assertEq(issuer.getRedeemRequestLength(), oldIssuer.getRedeemRequestLength());
        vm.stopPrank();
    }

    function testRebalancerMigrate() public {
        IAssetRebalancer oldRebalancer = IAssetRebalancer(oldRebalancerAddress);
        vm.expectRevert();
        rebalancer.migrateFrom(oldRebalancerAddress, 50);
        vm.startPrank(owner);
        do {
            rebalancer.migrateFrom(oldRebalancerAddress, 50);
        } while (rebalancer.getRebalanceRequestLength() < oldRebalancer.getRebalanceRequestLength());
        assertEq(rebalancer.getRebalanceRequestLength(), oldRebalancer.getRebalanceRequestLength());
        vm.stopPrank();
    }

    function testFeeManagerMigrate() public {
        IAssetFeeManager oldFeeManager = IAssetFeeManager(oldFeeManagerAddress);
        vm.expectRevert();
        feeManager.migrateFrom(oldFeeManagerAddress, 50);
        vm.startPrank(owner);
        do {
            feeManager.migrateFrom(oldFeeManagerAddress, 50);
        } while (feeManager.getBurnFeeRequestLength() < oldFeeManager.getBurnFeeRequestLength());
        assertEq(feeManager.getBurnFeeRequestLength(), oldFeeManager.getBurnFeeRequestLength());
        vm.stopPrank();
    }

    function testSwapMigrate() public {
        ISwap oldSwap = ISwap(oldSwapAddress);
        vm.expectRevert();
        swap.migrateFrom(oldSwapAddress);
        vm.startPrank(owner);
        swap.migrateFrom(oldSwapAddress);
        assertEq(abi.encode(swap.getWhiteListTokens()), abi.encode(oldSwap.getWhiteListTokens()));
        vm.stopPrank();
    }

    function testSwapMigrateSwapRequest() public {
        ISwap oldSwap = ISwap(oldSwapAddress);
        vm.expectRevert();
        swap.migrateSwapRequestFrom(oldSwapAddress, 10);
        vm.startPrank(owner);
        do {
            swap.migrateSwapRequestFrom(oldSwapAddress, 10);
        } while (swap.getOrderHashLength() < oldSwap.getOrderHashLength());
        assertEq(swap.getOrderHashLength(), oldSwap.getOrderHashLength());
        vm.stopPrank();
    }
}