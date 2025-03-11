// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/AssetFactory.sol";
import "../src/AssetToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract AssetFactoryTest is Test {
    MockToken WBTC;
    MockToken WETH;

    address owner = vm.addr(0x1);
    address vault = vm.addr(0x2);
    address issuer = vm.addr(0x3);
    address rebalancer = vm.addr(0x4);
    address feeManager = vm.addr(0x5);
    address swap = vm.addr(0x6);

    AssetFactory factory;
    AssetToken tokenImpl;

    string constant CHAIN = "SETH";

    function setUp() public {
        // 创建模拟代币
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        // 部署AssetToken实现合约
        tokenImpl = new AssetToken();

        // 部署AssetFactory合约
        AssetFactory factoryImpl = new AssetFactory();
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl), abi.encodeCall(AssetFactory.initialize, (owner, vault, CHAIN, address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);
    }

    function getAsset(uint256 id) internal view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: CHAIN,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 10 * 10 ** WBTC.decimals() / 60000
        });
        Asset memory asset = Asset({
            id: id,
            name: string(abi.encodePacked("BTC", vm.toString(id))),
            symbol: string(abi.encodePacked("BTC", vm.toString(id))),
            tokenset: tokenset_
        });
        return asset;
    }

    function test_Initialize() public {
        // 验证初始化参数
        assertEq(factory.vault(), vault);
        assertEq(factory.chain(), CHAIN);
        assertEq(factory.tokenImpl(), address(tokenImpl));
        assertEq(factory.owner(), owner);
    }

    function test_CreateAssetToken() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        uint256 maxFee = 10000;
        address assetTokenAddress = factory.createAssetToken(asset, maxFee, issuer, rebalancer, feeManager, swap);

        // 验证资产代币创建成功
        assertEq(factory.getAssetIDs().length, 1);
        assertEq(factory.getAssetIDs()[0], 1);
        assertEq(factory.assetTokens(1), assetTokenAddress);
        assertEq(factory.issuers(1), issuer);
        assertEq(factory.rebalancers(1), rebalancer);
        assertEq(factory.feeManagers(1), feeManager);
        assertEq(factory.swaps(1), swap);
        assertEq(factory.tokenImpls(1), address(tokenImpl));

        // 验证资产代币初始化正确
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        assertEq(assetToken.id(), 1);
        assertEq(assetToken.maxFee(), maxFee);

        // 验证角色分配正确
        assertTrue(assetToken.hasRole(assetToken.ISSUER_ROLE(), issuer));
        assertTrue(assetToken.hasRole(assetToken.REBALANCER_ROLE(), rebalancer));
        assertTrue(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), feeManager));

        vm.stopPrank();
    }

    function test_CreateDuplicateAssetToken() public {
        vm.startPrank(owner);

        // 创建第一个资产代币
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // 尝试创建相同ID的资产代币，应该失败
        vm.expectRevert("asset exists");
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        vm.stopPrank();
    }

    function test_CreateAssetTokenWithZeroAddresses() public {
        vm.startPrank(owner);

        // 尝试创建资产代币，但控制器地址为零地址，应该失败
        Asset memory asset = getAsset(1);
        vm.expectRevert("controllers not set");
        factory.createAssetToken(asset, 10000, address(0), rebalancer, feeManager, swap);

        vm.expectRevert("controllers not set");
        factory.createAssetToken(asset, 10000, issuer, address(0), feeManager, swap);

        vm.expectRevert("controllers not set");
        factory.createAssetToken(asset, 10000, issuer, rebalancer, address(0), swap);

        vm.stopPrank();
    }

    function test_SetSwap() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // 设置新的swap地址
        address newSwap = vm.addr(0x7);
        factory.setSwap(1, newSwap);

        // 验证swap地址已更新
        assertEq(factory.swaps(1), newSwap);

        // 尝试设置相同的swap地址，应该失败
        vm.expectRevert("swap address not change");
        factory.setSwap(1, newSwap);

        // 尝试设置零地址，应该失败
        vm.expectRevert("swap address is zero");
        factory.setSwap(1, address(0));

        // 尝试为不存在的资产ID设置swap地址，应该失败
        vm.expectRevert("asset not exist");
        factory.setSwap(2, newSwap);

        vm.stopPrank();
    }

    function test_SetVault() public {
        vm.startPrank(owner);

        // 设置新的vault地址
        address newVault = vm.addr(0x7);
        factory.setVault(newVault);

        // 验证vault地址已更新
        assertEq(factory.vault(), newVault);

        // 尝试设置零地址，应该失败
        vm.expectRevert("vault address is zero");
        factory.setVault(address(0));

        vm.stopPrank();
    }

    function test_SetTokenImpl() public {
        vm.startPrank(owner);

        // 部署新的AssetToken实现合约
        AssetToken newTokenImpl = new AssetToken();

        // 设置新的tokenImpl地址
        factory.setTokenImpl(address(newTokenImpl));

        // 验证tokenImpl地址已更新
        assertEq(factory.tokenImpl(), address(newTokenImpl));

        // 尝试设置相同的tokenImpl地址，应该失败
        vm.expectRevert("token impl is not change");
        factory.setTokenImpl(address(newTokenImpl));

        // 尝试设置零地址，应该失败
        vm.expectRevert("token impl address is zero");
        factory.setTokenImpl(address(0));

        vm.stopPrank();
    }

    function test_UpgradeTokenImpl() public {
        vm.startPrank(owner);

        // 创建两个资产代币
        Asset memory asset1 = getAsset(1);
        Asset memory asset2 = getAsset(2);
        factory.createAssetToken(asset1, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset2, 10000, issuer, rebalancer, feeManager, swap);

        // 部署新的AssetToken实现合约
        AssetToken newTokenImpl = new AssetToken();
        factory.setTokenImpl(address(newTokenImpl));

        // 升级第一个资产代币的实现
        uint256[] memory assetIDs = new uint256[](1);
        assetIDs[0] = 1;
        factory.upgradeTokenImpl(assetIDs);

        // 验证第一个资产代币的实现已升级
        assertEq(factory.tokenImpls(1), address(newTokenImpl));

        // 尝试再次升级已升级的资产代币，应该失败
        vm.expectRevert("asset token already upgraded");
        factory.upgradeTokenImpl(assetIDs);

        // 尝试升级不存在的资产代币，应该失败
        assetIDs[0] = 3;
        vm.expectRevert("asset not exist");
        factory.upgradeTokenImpl(assetIDs);

        vm.stopPrank();
    }

    function test_SetIssuer() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // 设置新的issuer地址
        address newIssuer = vm.addr(0x7);
        factory.setIssuer(1, newIssuer);

        // 验证issuer地址已更新
        assertEq(factory.issuers(1), newIssuer);
        assertTrue(assetToken.hasRole(assetToken.ISSUER_ROLE(), newIssuer));
        assertFalse(assetToken.hasRole(assetToken.ISSUER_ROLE(), issuer));

        // 尝试设置零地址，应该失败
        vm.expectRevert("issuer is zero address");
        factory.setIssuer(1, address(0));

        // 尝试为不存在的资产ID设置issuer地址，应该失败
        vm.expectRevert("assetID not exists");
        factory.setIssuer(2, newIssuer);

        vm.stopPrank();
    }

    function test_SetRebalancer() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // 设置新的rebalancer地址
        address newRebalancer = vm.addr(0x7);
        factory.setRebalancer(1, newRebalancer);

        // 验证rebalancer地址已更新
        assertEq(factory.rebalancers(1), newRebalancer);
        assertTrue(assetToken.hasRole(assetToken.REBALANCER_ROLE(), newRebalancer));
        assertFalse(assetToken.hasRole(assetToken.REBALANCER_ROLE(), rebalancer));

        // 尝试设置零地址，应该失败
        vm.expectRevert("rebalancer is zero address");
        factory.setRebalancer(1, address(0));

        // 尝试为不存在的资产ID设置rebalancer地址，应该失败
        vm.expectRevert("assetID not exists");
        factory.setRebalancer(2, newRebalancer);

        vm.stopPrank();
    }

    function test_SetFeeManager() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // 设置新的feeManager地址
        address newFeeManager = vm.addr(0x7);
        factory.setFeeManager(1, newFeeManager);

        // 验证feeManager地址已更新
        assertEq(factory.feeManagers(1), newFeeManager);
        assertTrue(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), newFeeManager));
        assertFalse(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), feeManager));

        // 尝试设置零地址，应该失败
        vm.expectRevert("feeManager is zero address");
        factory.setFeeManager(1, address(0));

        // 尝试为不存在的资产ID设置feeManager地址，应该失败
        vm.expectRevert("assetID not exists");
        factory.setFeeManager(2, newFeeManager);

        vm.stopPrank();
    }

    function test_HasAssetID() public {
        vm.startPrank(owner);

        // 初始状态下，应该没有任何资产ID
        assertFalse(factory.hasAssetID(1));

        // 创建资产代币
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // 验证资产ID存在
        assertTrue(factory.hasAssetID(1));
        assertFalse(factory.hasAssetID(2));

        vm.stopPrank();
    }

    function test_GetAssetIDs() public {
        vm.startPrank(owner);

        // 初始状态下，应该没有任何资产ID
        assertEq(factory.getAssetIDs().length, 0);

        // 创建多个资产代币
        Asset memory asset1 = getAsset(1);
        Asset memory asset2 = getAsset(2);
        Asset memory asset3 = getAsset(3);
        factory.createAssetToken(asset1, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset2, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset3, 10000, issuer, rebalancer, feeManager, swap);

        // 验证资产ID列表
        uint256[] memory assetIDs = factory.getAssetIDs();
        assertEq(assetIDs.length, 3);
        assertEq(assetIDs[0], 1);
        assertEq(assetIDs[1], 2);
        assertEq(assetIDs[2], 3);

        vm.stopPrank();
    }

    function test_Upgrade() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // 部署新的AssetFactory实现合约
        AssetFactory newFactoryImpl = new AssetFactory();

        // 升级AssetFactory合约
        factory.upgradeToAndCall(address(newFactoryImpl), new bytes(0));

        // 验证升级成功
        assertEq(Upgrades.getImplementationAddress(address(factory)), address(newFactoryImpl));

        // 验证状态保持不变
        assertEq(factory.vault(), vault);
        assertEq(factory.chain(), CHAIN);
        assertEq(factory.tokenImpl(), address(tokenImpl));
        assertTrue(factory.hasAssetID(1));

        vm.stopPrank();
    }

    function test_SetControllerWithLock() public {
        vm.startPrank(owner);

        // 创建资产代币
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // 锁定发行
        vm.startPrank(issuer);
        assetToken.lockIssue();
        vm.stopPrank();

        // 尝试在锁定状态下设置新的issuer，应该失败
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        factory.setIssuer(1, vm.addr(0x7));

        // 解锁发行
        vm.startPrank(issuer);
        assetToken.unlockIssue();
        vm.stopPrank();

        // 锁定重新平衡
        vm.startPrank(rebalancer);
        assetToken.lockRebalance();
        vm.stopPrank();

        // 尝试在锁定状态下设置新的rebalancer，应该失败
        vm.startPrank(owner);
        vm.expectRevert("is rebalancing");
        factory.setRebalancer(1, vm.addr(0x7));

        // 解锁重新平衡
        vm.startPrank(rebalancer);
        assetToken.unlockRebalance();
        vm.stopPrank();

        // 锁定燃烧费用
        vm.startPrank(feeManager);
        assetToken.lockBurnFee();
        vm.stopPrank();

        // 尝试在锁定状态下设置新的feeManager，应该失败
        vm.startPrank(owner);
        vm.expectRevert("is burning fee");
        factory.setFeeManager(1, vm.addr(0x7));

        // 解锁燃烧费用
        vm.startPrank(feeManager);
        assetToken.unlockBurnFee();
        vm.stopPrank();

        // 锁定发行
        vm.startPrank(issuer);
        assetToken.lockIssue();
        vm.stopPrank();

        // 尝试在锁定状态下设置新的swap，应该失败
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        factory.setSwap(1, vm.addr(0x7));

        vm.stopPrank();
    }
}
