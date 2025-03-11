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
        // Create mock tokens
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        // Deploy AssetToken implementation contract
        tokenImpl = new AssetToken();

        // Deploy AssetFactory contract
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
        // Verify initialization parameters
        assertEq(factory.vault(), vault);
        assertEq(factory.chain(), CHAIN);
        assertEq(factory.tokenImpl(), address(tokenImpl));
        assertEq(factory.owner(), owner);
    }

    function test_CreateAssetToken() public {
        vm.startPrank(owner);

        // Create asset token
        Asset memory asset = getAsset(1);
        uint256 maxFee = 10000;
        address assetTokenAddress = factory.createAssetToken(asset, maxFee, issuer, rebalancer, feeManager, swap);

        // Verify asset token creation success
        assertEq(factory.getAssetIDs().length, 1);
        assertEq(factory.getAssetIDs()[0], 1);
        assertEq(factory.assetTokens(1), assetTokenAddress);
        assertEq(factory.issuers(1), issuer);
        assertEq(factory.rebalancers(1), rebalancer);
        assertEq(factory.feeManagers(1), feeManager);
        assertEq(factory.swaps(1), swap);
        assertEq(factory.tokenImpls(1), address(tokenImpl));

        // Verify asset token initialization correctness
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        assertEq(assetToken.id(), 1);
        assertEq(assetToken.maxFee(), maxFee);

        // Verify role assignments
        assertTrue(assetToken.hasRole(assetToken.ISSUER_ROLE(), issuer));
        assertTrue(assetToken.hasRole(assetToken.REBALANCER_ROLE(), rebalancer));
        assertTrue(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), feeManager));

        vm.stopPrank();
    }

    function test_CreateDuplicateAssetToken() public {
        vm.startPrank(owner);

        // Create the first asset token
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // Attempt to create an asset token with the same ID, should fail
        vm.expectRevert("asset exists");
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        vm.stopPrank();
    }

    function test_CreateAssetTokenWithZeroAddresses() public {
        vm.startPrank(owner);

        // Attempt to create an asset token with zero addresses for controllers, should fail
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

        // Create an asset token
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // Set a new swap address
        address newSwap = vm.addr(0x7);
        factory.setSwap(1, newSwap);

        // Verify the swap address has been updated
        assertEq(factory.swaps(1), newSwap);

        // Attempt to set the same swap address again, should fail
        vm.expectRevert("swap address not change");
        factory.setSwap(1, newSwap);

        // Attempt to set a zero address, should fail
        vm.expectRevert("swap address is zero");
        factory.setSwap(1, address(0));

        // Attempt to set a swap address for a non-existent asset ID, should fail
        vm.expectRevert("asset not exist");
        factory.setSwap(2, newSwap);

        vm.stopPrank();
    }

    function test_SetVault() public {
        vm.startPrank(owner);

        // Set a new vault address
        address newVault = vm.addr(0x7);
        factory.setVault(newVault);

        // Verify the vault address has been updated
        assertEq(factory.vault(), newVault);

        // Attempt to set a zero address, should fail
        vm.expectRevert("vault address is zero");
        factory.setVault(address(0));

        vm.stopPrank();
    }

    function test_SetTokenImpl() public {
        vm.startPrank(owner);

        // Deploy a new AssetToken implementation contract
        AssetToken newTokenImpl = new AssetToken();

        // Set the new tokenImpl address
        factory.setTokenImpl(address(newTokenImpl));

        // Verify the tokenImpl address has been updated
        assertEq(factory.tokenImpl(), address(newTokenImpl));

        // Attempt to set the same tokenImpl address again, should fail
        vm.expectRevert("token impl is not change");
        factory.setTokenImpl(address(newTokenImpl));

        // Attempt to set a zero address, should fail
        vm.expectRevert("token impl address is zero");
        factory.setTokenImpl(address(0));

        vm.stopPrank();
    }

    function test_UpgradeTokenImpl() public {
        vm.startPrank(owner);

        // Create two asset tokens
        Asset memory asset1 = getAsset(1);
        Asset memory asset2 = getAsset(2);
        factory.createAssetToken(asset1, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset2, 10000, issuer, rebalancer, feeManager, swap);

        // Deploy a new AssetToken implementation contract
        AssetToken newTokenImpl = new AssetToken();
        factory.setTokenImpl(address(newTokenImpl));

        // Upgrade the implementation of the first asset token
        uint256[] memory assetIDs = new uint256[](1);
        assetIDs[0] = 1;
        factory.upgradeTokenImpl(assetIDs);

        // Verify the implementation of the first asset token has been upgraded
        assertEq(factory.tokenImpls(1), address(newTokenImpl));

        // Attempt to upgrade the already upgraded asset token again, should fail
        vm.expectRevert("asset token already upgraded");
        factory.upgradeTokenImpl(assetIDs);

        // Attempt to upgrade a non-existent asset token, should fail
        assetIDs[0] = 3;
        vm.expectRevert("asset not exist");
        factory.upgradeTokenImpl(assetIDs);

        vm.stopPrank();
    }

    function test_SetIssuer() public {
        vm.startPrank(owner);

        // Create an asset token
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // Set a new issuer address
        address newIssuer = vm.addr(0x7);
        factory.setIssuer(1, newIssuer);

        // Verify the issuer address has been updated
        assertEq(factory.issuers(1), newIssuer);
        assertTrue(assetToken.hasRole(assetToken.ISSUER_ROLE(), newIssuer));
        assertFalse(assetToken.hasRole(assetToken.ISSUER_ROLE(), issuer));

        // Attempt to set a zero address, should fail
        vm.expectRevert("issuer is zero address");
        factory.setIssuer(1, address(0));

        // Attempt to set an issuer address for a non-existent asset ID, should fail
        vm.expectRevert("assetID not exists");
        factory.setIssuer(2, newIssuer);

        vm.stopPrank();
    }

    function test_SetRebalancer() public {
        vm.startPrank(owner);

        // Create an asset token
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // Set a new rebalancer address
        address newRebalancer = vm.addr(0x7);
        factory.setRebalancer(1, newRebalancer);

        // Verify the rebalancer address has been updated
        assertEq(factory.rebalancers(1), newRebalancer);
        assertTrue(assetToken.hasRole(assetToken.REBALANCER_ROLE(), newRebalancer));
        assertFalse(assetToken.hasRole(assetToken.REBALANCER_ROLE(), rebalancer));

        // Attempt to set a zero address, should fail
        vm.expectRevert("rebalancer is zero address");
        factory.setRebalancer(1, address(0));

        // Attempt to set a rebalancer address for a non-existent asset ID, should fail
        vm.expectRevert("assetID not exists");
        factory.setRebalancer(2, newRebalancer);

        vm.stopPrank();
    }

    function test_SetFeeManager() public {
        vm.startPrank(owner);

        // Create an asset token
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // Set a new feeManager address
        address newFeeManager = vm.addr(0x7);
        factory.setFeeManager(1, newFeeManager);

        // Verify the feeManager address has been updated
        assertEq(factory.feeManagers(1), newFeeManager);
        assertTrue(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), newFeeManager));
        assertFalse(assetToken.hasRole(assetToken.FEEMANAGER_ROLE(), feeManager));

        // Attempt to set a zero address, should fail
        vm.expectRevert("feeManager is zero address");
        factory.setFeeManager(1, address(0));

        // Attempt to set a feeManager address for a non-existent asset ID, should fail
        vm.expectRevert("assetID not exists");
        factory.setFeeManager(2, newFeeManager);

        vm.stopPrank();
    }

    function test_HasAssetID() public {
        vm.startPrank(owner);

        // Initially, there should be no asset IDs
        assertFalse(factory.hasAssetID(1));

        // Create an asset token
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // Verify the asset ID exists
        assertTrue(factory.hasAssetID(1));
        assertFalse(factory.hasAssetID(2));

        vm.stopPrank();
    }

    function test_GetAssetIDs() public {
        vm.startPrank(owner);

        // Initially, there should be no asset IDs
        assertEq(factory.getAssetIDs().length, 0);

        // Create multiple asset tokens
        Asset memory asset1 = getAsset(1);
        Asset memory asset2 = getAsset(2);
        Asset memory asset3 = getAsset(3);
        factory.createAssetToken(asset1, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset2, 10000, issuer, rebalancer, feeManager, swap);
        factory.createAssetToken(asset3, 10000, issuer, rebalancer, feeManager, swap);

        // Verify the asset ID list
        uint256[] memory assetIDs = factory.getAssetIDs();
        assertEq(assetIDs.length, 3);
        assertEq(assetIDs[0], 1);
        assertEq(assetIDs[1], 2);
        assertEq(assetIDs[2], 3);

        vm.stopPrank();
    }

    function test_Upgrade() public {
        vm.startPrank(owner);

        // Create an asset token
        Asset memory asset = getAsset(1);
        factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);

        // Deploy a new AssetFactory implementation contract
        AssetFactory newFactoryImpl = new AssetFactory();

        // Upgrade the AssetFactory contract
        factory.upgradeToAndCall(address(newFactoryImpl), new bytes(0));

        // Verify the upgrade was successful
        assertEq(Upgrades.getImplementationAddress(address(factory)), address(newFactoryImpl));

        // Verify the state remains unchanged
        assertEq(factory.vault(), vault);
        assertEq(factory.chain(), CHAIN);
        assertEq(factory.tokenImpl(), address(tokenImpl));
        assertTrue(factory.hasAssetID(1));

        vm.stopPrank();
    }

    function test_SetControllerWithLock() public {
        vm.startPrank(owner);

        // Create an asset token
        Asset memory asset = getAsset(1);
        address assetTokenAddress = factory.createAssetToken(asset, 10000, issuer, rebalancer, feeManager, swap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);

        // Lock issuance
        vm.startPrank(issuer);
        assetToken.lockIssue();
        vm.stopPrank();

        // Attempt to set a new issuer while locked, should fail
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        factory.setIssuer(1, vm.addr(0x7));

        // Unlock issuance
        vm.startPrank(issuer);
        assetToken.unlockIssue();
        vm.stopPrank();

        // Lock rebalancing
        vm.startPrank(rebalancer);
        assetToken.lockRebalance();
        vm.stopPrank();

        // Attempt to set a new rebalancer while locked, should fail
        vm.startPrank(owner);
        vm.expectRevert("is rebalancing");
        factory.setRebalancer(1, vm.addr(0x7));

        // Unlock rebalancing
        vm.startPrank(rebalancer);
        assetToken.unlockRebalance();
        vm.stopPrank();

        // Lock burn fee
        vm.startPrank(feeManager);
        assetToken.lockBurnFee();
        vm.stopPrank();

        // Attempt to set a new feeManager while locked, should fail
        vm.startPrank(owner);
        vm.expectRevert("is burning fee");
        factory.setFeeManager(1, vm.addr(0x7));

        // Unlock burn fee
        vm.startPrank(feeManager);
        assetToken.unlockBurnFee();
        vm.stopPrank();

        // Lock issuance
        vm.startPrank(issuer);
        assetToken.lockIssue();
        vm.stopPrank();

        // Attempt to set a new swap while locked, should fail
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        factory.setSwap(1, vm.addr(0x7));

        vm.stopPrank();
    }
}