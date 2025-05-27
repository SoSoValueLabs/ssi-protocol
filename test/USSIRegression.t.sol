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
        chain = AssetFactory(0x2f207cb16c32eC18E2a7B5aba3a1119bd459592a).chain();
        owner = AssetFactory(0x2f207cb16c32eC18E2a7B5aba3a1119bd459592a).owner();
        vault = AssetFactory(0x2f207cb16c32eC18E2a7B5aba3a1119bd459592a).vault();
        ussi = USSI(0x98c7bEA94F953377285eBa454a638b4d46022FAD);
        quoteToken = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        trader = 0x0306acEb4c20FF33480d90038F8b375cC6A6b66e;
        // set asset id
        ASSET_ID1 = 19;

        vm.startPrank(owner);
        factory = AssetFactory(0x2f207cb16c32eC18E2a7B5aba3a1119bd459592a);
        factory.upgradeToAndCall(address(new AssetFactory()), "");

        address issuerAddr = factory.issuers(ASSET_ID1);
        issuer = AssetIssuer(issuerAddr);
        issuer.upgradeToAndCall(address(new AssetIssuer()), "");
        // upgrade ussi
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        orderSignerPk = 0x333;
        orderSigner = vm.addr(orderSignerPk);
        ussi.updateOrderSigner(orderSigner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.updateRedeemToken(address(WBTC));
        // ussi.addSupportAsset(0);
        vm.stopPrank();

        vm.etch(orderSigner, "");
        vm.resetNonce(orderSigner);
        vm.etch(hedger, "");
        vm.resetNonce(hedger);
        deal(address(quoteToken), hedger, MINT_AMOUNT);
    }

    function test_AddSupportAsset() public override {}

    function test_AddSupportToken() public override {
        vm.startPrank(owner);

        // Test adding a valid token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);

        // Verify the token was added
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[1], newToken);
        vm.expectRevert("token is zero address");
        ussi.addSupportToken(address(0));
        vm.expectRevert("already contains token");
        ussi.addSupportToken(newToken);
        vm.stopPrank();

        // Test non-owner cannot add token
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.addSupportToken(newToken);
        vm.stopPrank();
    }

    function test_ApplyMint_alone() public override {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: quoteToken,
            nonce: vm.unixTime(),
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        // Sign the order
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Apply for minting
        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Verify the application status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // Verify the asset has been transferred
        assertEq(IERC20(quoteToken).balanceOf(hedger), 0);
        assertEq(IERC20(quoteToken).balanceOf(address(ussi)), MINT_AMOUNT);
    }

    function test_CancelMint() public override {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: quoteToken,
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);

        // Attempt to cancel but not yet timed out
        vm.expectRevert("not timeout");
        ussi.cancelMint(orderHash);

        // Wait for timeout
        vm.warp(block.timestamp + ussi.MAX_MINT_DELAY() + 1);

        // Cancel minting
        ussi.cancelMint(orderHash);
        vm.stopPrank();

        // Verify the cancellation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CANCELED));

        // Verify the asset has been returned
        assertEq(IERC20(quoteToken).balanceOf(hedger), MINT_AMOUNT);
        assertEq(IERC20(quoteToken).balanceOf(address(ussi)), 0);
    }

    function test_CancelMint_Revert() public override {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test non-existent order
        vm.startPrank(hedger);
        vm.expectRevert("order not exists");
        ussi.cancelMint(orderHash);
        vm.stopPrank();

        // Apply for minting
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);

        // Test mismatched order type
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.REDEEM,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 1,
            inAmount: USSI_AMOUNT,
            outAmount: MINT_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 redeemOrderHash = keccak256(abi.encode(redeemOrder));
        (v, r, s) = vm.sign(orderSignerPk, redeemOrderHash);
        bytes memory redeemOrderSign = abi.encodePacked(r, s, v);

        deal(address(ussi), hedger, USSI_AMOUNT);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, redeemOrderSign);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("order type not match");
        ussi.cancelMint(redeemOrderHash);
        vm.stopPrank();
    }

    function test_CancelRedeem_Revert() public override {
        // Create a redeem order
        deal(address(ussi), hedger, USSI_AMOUNT);
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.REDEEM,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 1,
            inAmount: USSI_AMOUNT,
            outAmount: MINT_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test non-existent order
        vm.startPrank(hedger);
        vm.expectRevert("order not exists");
        ussi.cancelRedeem(orderHash);
        vm.stopPrank();

        // Apply for redemption
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);

        // Test mismatched order type
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 mintOrderHash = keccak256(abi.encode(mintOrder));
        (v, r, s) = vm.sign(orderSignerPk, mintOrderHash);
        bytes memory mintOrderSign = abi.encodePacked(r, s, v);

        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, mintOrderSign);
        vm.expectRevert();
        vm.warp(block.timestamp - 1 hours);
        ussi.cancelRedeem(mintOrderHash);
        vm.stopPrank();
    }

    function test_ConfirmMint() public override {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();
        vm.startPrank(owner);
        // Confirm minting
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // Verify the confirmation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));

        // Verify USSI tokens have been minted
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
    }

    function test_ConfirmMint_Revert() public override {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test non-existent order
        vm.startPrank(owner);
        vm.expectRevert("order not exists");
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // Apply for minting
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Test non-owner confirmation
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // Test mismatched order type
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.REDEEM,
            assetID: ASSET_ID1,
            redeemToken: address(WBTC),
            nonce: 1,
            inAmount: USSI_AMOUNT,
            outAmount: MINT_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 redeemOrderHash = keccak256(abi.encode(redeemOrder));
        (v, r, s) = vm.sign(orderSignerPk, redeemOrderHash);
        bytes memory redeemOrderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        deal(address(ussi), hedger, USSI_AMOUNT);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, redeemOrderSign);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("order type not match");
        ussi.confirmMint(redeemOrderHash);
        vm.stopPrank();
    }

    function test_ConfirmRedeem_Revert() public override {
        // Create a redeem order
        deal(address(ussi), hedger, USSI_AMOUNT);
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.REDEEM,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 1,
            inAmount: USSI_AMOUNT,
            outAmount: MINT_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test non-existent order
        vm.startPrank(owner);
        vm.expectRevert("order not exists");
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // Apply for redemption
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Test non-owner confirmation
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // Test mismatched order type
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 mintOrderHash = keccak256(abi.encode(mintOrder));
        (v, r, s) = vm.sign(orderSignerPk, mintOrderHash);
        bytes memory mintOrderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, mintOrderSign);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert("order type not match");
        ussi.confirmRedeem(mintOrderHash, bytes32(0));
        vm.stopPrank();

        // Test insufficient redeem token balance
        vm.startPrank(owner);
        vm.expectRevert("not enough redeem token");
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();
    }

    function test_GetOrderHashs() public override {}

    function test_GetSupportTokens() public override {
        vm.startPrank(owner);

        // Initially there should be no supported tokens
        address[] memory initialTokens = ussi.getSupportTokens();
        assertEq(initialTokens.length, 1);

        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);

        // Get the list of supported tokens
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[1], newToken);

        vm.stopPrank();
    }

    function test_RejectMint() public override {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: chain,
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: trader,
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            vault: address(0x87539DA9b5c00E978E565dbb8267e07EBB226acB)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(quoteToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Reject minting
        vm.startPrank(owner);
        ussi.rejectMint(orderHash);
        vm.stopPrank();

        // Verify the rejection status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // Verify the asset has been returned
        assertEq(IERC20(quoteToken).balanceOf(hedger), MINT_AMOUNT);
        assertEq(IERC20(quoteToken).balanceOf(address(ussi)), 0);
    }

    function test_RemoveSupportToken() public override {
        vm.startPrank(owner);

        // Add a token first
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);

        // Test removing the token
        ussi.removeSupportToken(newToken);

        // Verify the token was removed
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 1);

        // Test removing zero address (should revert)
        vm.expectRevert("token is zero address");
        ussi.removeSupportToken(address(0));

        // Test removing a non-existent token (should revert)
        vm.expectRevert("token is not supported");
        ussi.removeSupportToken(newToken);

        vm.stopPrank();

        // Test non-owner cannot remove token
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.removeSupportToken(newToken);
        vm.stopPrank();
    }

    function test_UpdateRedeemToken() public override {
        address newRedeemToken = address(0x239232);

        vm.startPrank(owner);
        ussi.updateRedeemToken(newRedeemToken);
        vm.stopPrank();

        assertEq(ussi.redeemToken(), newRedeemToken);

        // Test error cases
        vm.startPrank(owner);
        vm.expectRevert("redeem token is zero address");
        ussi.updateRedeemToken(address(0));

        vm.expectRevert("redeem token not change");
        ussi.updateRedeemToken(newRedeemToken);
        vm.stopPrank();
    }
}
