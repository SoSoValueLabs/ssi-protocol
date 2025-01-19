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
        vm.createSelectFork("https://mainnet.base.org");
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
        issuer.migrateFrom(oldIssuerAddress);
        vm.startPrank(owner);
        vm.expectRevert();
        issuer.migrateFrom(oldIssuerAddress);
        IPausable(oldIssuerAddress).pause();
        issuer.migrateFrom(oldIssuerAddress);
        assertEq(issuer.getMintRequestLength(), oldIssuer.getMintRequestLength());
        assertEq(abi.encode(issuer.getMintRequest(issuer.getMintRequestLength() / 2)), abi.encode(oldIssuer.getMintRequest(oldIssuer.getMintRequestLength() / 2)));
        assertEq(issuer.getRedeemRequestLength(), oldIssuer.getRedeemRequestLength());
        assertEq(abi.encode(issuer.getRedeemRequest(issuer.getRedeemRequestLength() / 2)), abi.encode(oldIssuer.getRedeemRequest(oldIssuer.getRedeemRequestLength() / 2)));
        vm.stopPrank();
    }

    function testRebalancerMigrate() public {
        IAssetRebalancer oldRebalancer = IAssetRebalancer(oldRebalancerAddress);
        vm.expectRevert();
        rebalancer.migrateFrom(oldRebalancerAddress);
        vm.startPrank(owner);
        vm.expectRevert();
        rebalancer.migrateFrom(oldRebalancerAddress);
        IPausable(oldRebalancerAddress).pause();
        rebalancer.migrateFrom(oldRebalancerAddress);
        assertEq(rebalancer.getRebalanceRequestLength(), oldRebalancer.getRebalanceRequestLength());
        assertEq(abi.encode(rebalancer.getRebalanceRequest(rebalancer.getRebalanceRequestLength() / 2)), abi.encode(oldRebalancer.getRebalanceRequest(oldRebalancer.getRebalanceRequestLength() / 2)));
        vm.stopPrank();
    }

    function testFeeManagerMigrate() public {
        IAssetFeeManager oldFeeManager = IAssetFeeManager(oldFeeManagerAddress);
        vm.expectRevert();
        feeManager.migrateFrom(oldFeeManagerAddress);
        vm.startPrank(owner);
        vm.expectRevert();
        feeManager.migrateFrom(oldFeeManagerAddress);
        IPausable(oldFeeManagerAddress).pause();
        feeManager.migrateFrom(oldFeeManagerAddress);
        assertEq(feeManager.getBurnFeeRequestLength(), oldFeeManager.getBurnFeeRequestLength());
        assertEq(abi.encode(feeManager.getBurnFeeRequest(feeManager.getBurnFeeRequestLength() / 2)), abi.encode(oldFeeManager.getBurnFeeRequest(oldFeeManager.getBurnFeeRequestLength() / 2)));
        vm.stopPrank();
    }

    function testSwapMigrate() public {
        ISwap oldSwap = ISwap(oldSwapAddress);
        vm.expectRevert();
        swap.migrateFrom(oldSwapAddress);
        vm.startPrank(owner);
        vm.expectRevert();
        swap.migrateFrom(oldSwapAddress);
        IPausable(oldSwapAddress).pause();
        swap.migrateFrom(oldSwapAddress);
        assertEq(swap.getOrderHashLength(), oldSwap.getOrderHashLength());
        assertEq(swap.getOrderHash(swap.getOrderHashLength() / 2), oldSwap.getOrderHash(oldSwap.getOrderHashLength() / 2));
        assertEq(abi.encode(swap.getSwapRequest(swap.getOrderHash(swap.getOrderHashLength() / 2))), abi.encode(oldSwap.getSwapRequest(oldSwap.getOrderHash(oldSwap.getOrderHashLength() / 2))));
        vm.stopPrank();
    }
}