// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/USSI.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/AssetFactory.sol";
import {USSITest} from "./Ussi.t.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

error OwnableUnauthorizedAccount(address account);

import {Test, console} from "forge-std/Test.sol";

contract USSIRegressionTest is USSITest {
    function setUp() public override {
        chain = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).chain();
        owner = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).owner();
        vault = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).vault();
        ussi = USSI(0x3a46ed8FCeb6eF1ADA2E4600A522AE7e24D2Ed18);
        quoteToken = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        trader = 0x0306acEb4c20FF33480d90038F8b375cC6A6b66e;
        // set asset id
        ASSET_ID1 = 100;

        vm.startPrank(owner);
        factory = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D);
        factory.upgradeToAndCall(address(new AssetFactory()), "");

        issuer = AssetIssuer(0x0306acEb4c20FF33480d90038F8b375cC6A6b66e);
        issuer.upgradeToAndCall(address(new AssetIssuer()), "");
        // upgrade ussi
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);
        redeemToken = address(WBTC);
        mintToken = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        mintTokenVault = address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB);
        orderSignerPk = 0x333;
        orderSigner = vm.addr(orderSignerPk);
        ussi.upgradeToAndCall(address(new USSI()), "");
        ussi.updateOrderSigner(orderSigner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.updateRedeemToken(address(WBTC));

        assetTokenAddress =
            factory.createAssetToken(getAsset(), 10000, address(issuer), address(0x2), address(0x3), address(0x4));
        assetToken = AssetToken(assetTokenAddress);
        ussi.addSupportAsset(ASSET_ID1);

        swap = Swap(0xF909bfa750721501B4F8433588FaE5cE303Db08B);
        swap.upgradeToAndCall(address(new Swap()), "");
        swap.grantRole(swap.MAKER_ROLE(), orderSigner);
        string[] memory takerAddresses = new string[](2);
        takerAddresses[0] = vm.toString(address(issuer));
        takerAddresses[1] = vm.toString(orderSigner);
        swap.setTakerAddresses(takerAddresses, takerAddresses);
        vm.stopPrank();

        vm.etch(orderSigner, "");
        vm.resetNonce(orderSigner);
        vm.etch(hedger, "");
        vm.resetNonce(hedger);
        deal(address(quoteToken), hedger, MINT_AMOUNT);
        deal(address(assetToken), hedger, MINT_AMOUNT);

        vm.startPrank(address(issuer));
        assetToken.mint(orderSigner, MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_rescueToken() public override {}

    function test_AddSupportAsset() public override {}

    // function test_ConfirmMint() public override {}
}
