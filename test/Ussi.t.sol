// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/USSI.sol";
import "../src/AssetFactory.sol";
import "../src/AssetToken.sol";
import "../src/AssetIssuer.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console} from "forge-std/Test.sol";

error OwnableUnauthorizedAccount(address account);

contract USSITest is Test {
    MockToken WBTC;
    MockToken WETH;

    address owner = vm.addr(0x1);
    address vault = vm.addr(0x2);
    uint256 orderSignerPk = 0x3;
    address orderSigner;
    address hedger = vm.addr(0x4);
    address receiver = vm.addr(0x5);
    address staker = vm.addr(0x10);

    AssetFactory factory;
    AssetIssuer issuer;
    AssetToken assetToken;
    AssetToken assetToken2;
    USSI ussi;

    uint256 constant ASSET_ID1 = 1;
    uint256 constant ASSET_ID2 = 2;
    uint256 constant MINT_AMOUNT = 1e8;
    uint256 constant USSI_AMOUNT = 10e8;

    function setUp() public {
        orderSigner = vm.addr(orderSignerPk);

        // Create mock tokens
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // Deploy AssetFactory
        AssetToken tokenImpl = new AssetToken();
        AssetFactory factoryImpl = new AssetFactory();
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(AssetFactory.initialize, (owner, vault, "SETH", address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);
        // Deploy AssetIssuer
        issuer = AssetIssuer(
            address(
                new ERC1967Proxy(
                    address(new AssetIssuer()), abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // Create asset tokens
        address assetTokenAddress =
            factory.createAssetToken(getAsset(), 10000, address(issuer), address(0x2), address(0x3), address(0x4));
        assetToken = AssetToken(assetTokenAddress);
        address assetTokenAddress2 =
            factory.createAssetToken(getAsset2(), 10000, address(issuer), address(0x2), address(0x3), address(0x4));
        assetToken2 = AssetToken(assetTokenAddress2);

        // Deploy USSI contract
        ussi = USSI(
            address(
                new ERC1967Proxy(
                    address(new USSI()),
                    abi.encodeCall(USSI.initialize, (owner, orderSigner, address(factory), address(WBTC), "SETH"))
                )
            )
        );

        // Set permissions and supported assets
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.addSupportAsset(ASSET_ID1);

        vm.stopPrank();

        // Mint asset tokens to hedger
        deal(address(assetToken), hedger, MINT_AMOUNT);
        vm.startPrank(address(issuer));
        assetToken.mint(staker, MINT_AMOUNT);
        vm.stopPrank();
    }

    function getAsset() public view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: "SETH",
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 10 * 10 ** WBTC.decimals() / 60000
        });
        Asset memory asset = Asset({id: ASSET_ID1, name: "BTC", symbol: "BTC", tokenset: tokenset_});
        return asset;
    }

    function getAsset2() public view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 * 10 ** WETH.decimals() / 60000
        });
        Asset memory asset = Asset({id: ASSET_ID2, name: "ETH", symbol: "ETH", tokenset: tokenset_});
        return asset;
    }

    function test_Initialize() public view {
        assertEq(ussi.owner(), owner);
        assertEq(ussi.orderSigner(), orderSigner);
        assertEq(ussi.factoryAddress(), address(factory));
        assertEq(ussi.redeemToken(), address(WBTC));
        assertEq(ussi.chain(), "SETH");
        assertEq(ussi.name(), "USSI");
        assertEq(ussi.symbol(), "USSI");
        assertEq(ussi.decimals(), 8);
    }

    function test_AddSupportAsset() public {
        vm.startPrank(owner);

        // Test adding a supported asset
        ussi.addSupportAsset(2);

        // Verify the asset is added
        uint256[] memory assetIDs = ussi.getSupportAssetIDs();
        // Verify asset 2 is in the list of supported assets
        bool isSupportAsset = false;
        for (uint256 i = 0; i < assetIDs.length; i++) {
            if (assetIDs[i] == 2) {
                isSupportAsset = true;
                break;
            }
        }
        assertEq(isSupportAsset, true);

        // Test removing a supported asset
        ussi.removeSupportAsset(2);

        // Verify the asset is removed
        uint256[] memory assetIDs_remove = ussi.getSupportAssetIDs();
        bool hasRemoved = true;
        for (uint256 i = 0; i < assetIDs_remove.length; i++) {
            if (assetIDs_remove[i] == 2) {
                hasRemoved = false;
                break;
            }
        }
        assertEq(hasRemoved, true);
        vm.stopPrank();
    }

    function test_ApplyMint() public {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        // Sign the order
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Apply for minting
        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Verify the application status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // Verify the asset has been transferred
        assertEq(assetToken.balanceOf(hedger), 0);
        assertEq(assetToken.balanceOf(address(ussi)), MINT_AMOUNT);
    }

    function test_ConfirmMint() public {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(WBTC),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: hedger,
            token: address(0),
            vault: address(0)
        });
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
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

    function test_CancelMint() public {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
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
        assertEq(assetToken.balanceOf(hedger), MINT_AMOUNT);
        assertEq(assetToken.balanceOf(address(ussi)), 0);
    }

    function test_RejectMint() public {
        // Create and apply for minting
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Reject minting
        vm.startPrank(owner);
        ussi.rejectMint(orderHash);
        vm.stopPrank();

        // Verify the rejection status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // Verify the asset has been returned
        assertEq(assetToken.balanceOf(hedger), MINT_AMOUNT);
        assertEq(assetToken.balanceOf(address(ussi)), 0);
    }

    function test_ApplyRedeem() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        // Sign the order
        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Apply for redemption
        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Verify the application status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // Verify USSI tokens have been transferred
        assertEq(ussi.balanceOf(hedger), 0);
        assertEq(ussi.balanceOf(address(ussi)), USSI_AMOUNT);
    }

    function test_ConfirmRedeem() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.REDEEM,
            assetID: ASSET_ID1,
            redeemToken: ussi.redeemToken(),
            nonce: 1,
            inAmount: USSI_AMOUNT,
            outAmount: MINT_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: hedger,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Confirm redemption (using transaction hash)
        vm.startPrank(owner);
        bytes32 txHash = bytes32(uint256(1));
        WBTC.mint(owner, MINT_AMOUNT);
        WBTC.transfer(address(ussi), MINT_AMOUNT);
        ussi.confirmRedeem(orderHash, txHash);
        vm.stopPrank();

        // Verify the confirmation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));
        assertEq(ussi.redeemTxHashs(orderHash), txHash);

        // Verify USSI tokens have been burned
        assertEq(ussi.balanceOf(address(hedger)), 0);
    }

    function test_ConfirmRedeemWithToken() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Confirm redemption (directly transfer tokens)
        vm.startPrank(owner);
        WBTC.mint(address(ussi), MINT_AMOUNT);
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // Verify the confirmation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));

        // Verify tokens have been transferred
        assertEq(WBTC.balanceOf(hedger), MINT_AMOUNT);
        assertEq(ussi.balanceOf(address(hedger)), 0);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_CancelRedeem() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);

        // Attempt to cancel but not yet timed out
        vm.expectRevert("not timeout");
        ussi.cancelRedeem(orderHash);

        // Wait for timeout
        vm.warp(block.timestamp + ussi.MAX_REDEEM_DELAY() + 1);

        // Cancel redemption
        ussi.cancelRedeem(orderHash);
        vm.stopPrank();

        // Verify the cancellation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CANCELED));

        // Verify USSI tokens have been returned
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
        assertEq(ussi.balanceOf(address(ussi)), 0);
    }

    function test_RejectRedeem() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Reject redemption
        vm.startPrank(owner);
        ussi.rejectRedeem(orderHash);
        vm.stopPrank();

        // Verify the rejection status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // Verify USSI tokens have been returned
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
        assertEq(ussi.balanceOf(address(ussi)), 0);
    }

    function test_UpdateOrderSigner() public {
        address newOrderSigner = vm.addr(0x6);

        vm.startPrank(owner);
        ussi.updateOrderSigner(newOrderSigner);
        vm.stopPrank();

        assertEq(ussi.orderSigner(), newOrderSigner);

        // Test error cases
        vm.startPrank(owner);
        vm.expectRevert("orderSigner is zero address");
        ussi.updateOrderSigner(address(0));

        vm.expectRevert("orderSigner not change");
        ussi.updateOrderSigner(newOrderSigner);
        vm.stopPrank();
    }

    function test_UpdateRedeemToken() public {
        address newRedeemToken = address(WETH);

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

    function test_Pause() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Pause the contract
        vm.startPrank(owner);
        ussi.pause();
        vm.stopPrank();

        // Test operations under paused state
        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ussi.applyRedeem(redeemOrder, orderSign);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ussi.cancelRedeem(orderHash);

        vm.stopPrank();

        // Resume the contract
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        // Test operations after resuming
        vm.startPrank(hedger);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Verify the application is successful
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
    }

    function test_GetOrderHashs() public {
        // Create multiple orders
        for (uint256 i = 0; i < 3; i++) {
            USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
                chain: "SETH",
                orderType: USSI.HedgeOrderType.MINT,
                assetID: ASSET_ID1,
                redeemToken: address(0),
                nonce: i,
                inAmount: MINT_AMOUNT,
                outAmount: USSI_AMOUNT,
                deadline: block.timestamp + 600,
                requester: hedger,
                receiver: receiver,
                token: address(0),
                vault: address(0)
            });

            bytes32 orderHash_mint = keccak256(abi.encode(mintOrder));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash_mint);
            bytes memory orderSign = abi.encodePacked(r, s, v);

            deal(address(assetToken), hedger, MINT_AMOUNT);

            vm.startPrank(hedger);
            assetToken.approve(address(ussi), MINT_AMOUNT);
            ussi.applyMint(mintOrder, orderSign);
            vm.stopPrank();
        }

        // Get the list of order hashes
        bytes32[] memory orderHashs = ussi.getOrderHashs();

        // Verify the length of the list
        assertEq(orderHashs.length, 3);
        assertEq(ussi.getOrderHashLength(), 3);

        // Verify the order hash can be retrieved by index
        bytes32 orderHash = ussi.getOrderHash(1);
        assertEq(orderHash, orderHashs[1]);
    }

    function test_CheckHedgeOrder() public {
        // Create a valid mint order
        USSI.HedgeOrder memory validMintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(validMintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test a valid order
        ussi.checkHedgeOrder(validMintOrder, orderHash, orderSign);

        // Test mismatched chain
        USSI.HedgeOrder memory wrongChainOrder = validMintOrder;
        wrongChainOrder.chain = "ETH";
        orderHash = keccak256(abi.encode(wrongChainOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("chain not match");
        ussi.checkHedgeOrder(wrongChainOrder, orderHash, orderSign);

        // Test unsupported asset ID
        USSI.HedgeOrder memory wrongAssetOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });
        wrongAssetOrder.assetID = 999;
        orderHash = keccak256(abi.encode(wrongAssetOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("assetID not supported");
        ussi.checkHedgeOrder(wrongAssetOrder, orderHash, orderSign);

        // Test expired order
        USSI.HedgeOrder memory expiredOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });
        expiredOrder.deadline = block.timestamp - 1;
        orderHash = keccak256(abi.encode(expiredOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("expired");
        ussi.checkHedgeOrder(expiredOrder, orderHash, orderSign);

        // Test invalid signature
        bytes memory wrongSign = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.expectRevert("signature not valid");
        validMintOrder.chain = "SETH";
        ussi.checkHedgeOrder(validMintOrder, orderHash, wrongSign);
    }

    ///////////////////////////////
    ///////////////////////////////
    ///////////////////////////////
    ///////////////////////////////
    ///////////////////////////////
    ///////////////////////////////
    ///////////////////////////////

    function test_Initialize_Revert() public {
        vm.startPrank(owner);
        USSI newUSSI = new USSI();

        // Test zero factory address
        vm.expectRevert("zero factory address");
        address(
            new ERC1967Proxy(
                address(newUSSI),
                abi.encodeCall(USSI.initialize, (owner, orderSigner, address(0), address(WBTC), "SETH"))
            )
        );

        // Test zero redeem token address
        vm.expectRevert("zero redeem token address");
        address(
            new ERC1967Proxy(
                address(newUSSI),
                abi.encodeCall(USSI.initialize, (owner, orderSigner, address(factory), address(0), "SETH"))
            )
        );

        // Test zero order signer address
        vm.expectRevert("zero order signer address");
        address(
            new ERC1967Proxy(
                address(newUSSI),
                abi.encodeCall(USSI.initialize, (owner, address(0), address(factory), address(WBTC), "SETH"))
            )
        );
        vm.stopPrank();
    }

    function test_CheckHedgeOrder_Redeem() public {
        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test a normal redeem order
        ussi.checkHedgeOrder(redeemOrder, orderHash, orderSign);

        // Test zero receiver address
        USSI.HedgeOrder memory zeroReceiverOrder = redeemOrder;
        zeroReceiverOrder.receiver = address(0);
        orderHash = keccak256(abi.encode(zeroReceiverOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);
        vm.expectRevert("receiver is zero address");
        ussi.checkHedgeOrder(zeroReceiverOrder, orderHash, orderSign);

        // Test unsupported redeem token
        USSI.HedgeOrder memory wrongRedeemTokenOrder = USSI.HedgeOrder({
            chain: "SETH",
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
        wrongRedeemTokenOrder.redeemToken = address(WETH);
        orderHash = keccak256(abi.encode(wrongRedeemTokenOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);
        vm.expectRevert("redeem token not supported");
        ussi.checkHedgeOrder(wrongRedeemTokenOrder, orderHash, orderSign);
    }

    function test_ApplyMint_Revert() public {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test no PARTICIPANT_ROLE permission
        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Test paused state after granting permission
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.pause();
        vm.stopPrank();

        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Resume the contract and test asset transfer failure
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        vm.startPrank(hedger);
        // Do not approve asset transfer
        vm.expectRevert("not enough allowance");
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();
    }

    function test_ApplyRedeem_Revert() public {
        // Mint USSI tokens first
        deal(address(ussi), hedger, USSI_AMOUNT);

        // Create a redeem order
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Test no PARTICIPANT_ROLE permission
        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Test paused state after granting permission
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.pause();
        vm.stopPrank();

        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // Resume the contract and test token transfer failure
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        vm.startPrank(hedger);
        // Do not approve token transfer
        vm.expectRevert("not enough allowance");
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();
    }

    function test_ConfirmMint_Revert() public {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
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
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Test non-owner confirmation
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // Test mismatched order type
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

    function test_ConfirmRedeem_Revert() public {
        // Create a redeem order
        deal(address(ussi), hedger, USSI_AMOUNT);
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 mintOrderHash = keccak256(abi.encode(mintOrder));
        (v, r, s) = vm.sign(orderSignerPk, mintOrderHash);
        bytes memory mintOrderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
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

    function test_CancelMint_Revert() public {
        // Create a mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
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
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);

        // Test mismatched order type
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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

        deal(address(ussi), hedger, USSI_AMOUNT);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, redeemOrderSign);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("order type not match");
        ussi.cancelMint(redeemOrderHash);
        vm.stopPrank();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_CancelRedeem_Revert() public {
        // Create a redeem order
        deal(address(ussi), hedger, USSI_AMOUNT);
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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
            chain: "SETH",
            orderType: USSI.HedgeOrderType.MINT,
            assetID: ASSET_ID1,
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(0),
            vault: address(0)
        });

        bytes32 mintOrderHash = keccak256(abi.encode(mintOrder));
        (v, r, s) = vm.sign(orderSignerPk, mintOrderHash);
        bytes memory mintOrderSign = abi.encodePacked(r, s, v);

        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, mintOrderSign);
        vm.expectRevert();
        vm.warp(block.timestamp - 1 hours);
        ussi.cancelRedeem(mintOrderHash);
        vm.stopPrank();
    }

    function test_GetSupportTokens() public {
        vm.startPrank(owner);
        
        // Initially there should be no supported tokens
        address[] memory initialTokens = ussi.getSupportTokens();
        assertEq(initialTokens.length, 0);
        
        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        
        // Get the list of supported tokens
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], newToken);
        
        vm.stopPrank();
    }

    function test_AddSupportToken() public {
        vm.startPrank(owner);
        
        // Test adding a valid token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        
        // Verify the token was added
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], newToken);
        
        // Test adding zero address (should revert)
        vm.expectRevert("token is zero address");
        ussi.addSupportToken(address(0));
        
        // Test adding the same token again (should revert)
        vm.expectRevert("already contains token");
        ussi.addSupportToken(newToken);
        
        vm.stopPrank();
        
        // Test non-owner cannot add token
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.addSupportToken(newToken);
        vm.stopPrank();
    }

    function test_RemoveSupportToken() public {
        vm.startPrank(owner);
        
        // Add a token first
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        
        // Test removing the token
        ussi.removeSupportToken(newToken);
        
        // Verify the token was removed
        address[] memory tokens = ussi.getSupportTokens();
        assertEq(tokens.length, 0);
        
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

    function test_UpdateVault() public {
        vm.startPrank(owner);
        
        // Test updating to a valid vault address
        address newVault = address(0x123);
        ussi.updateVault(newVault);
        assertEq(ussi.vault(), newVault);
        
        // Test updating to zero address (should revert)
        vm.expectRevert("vault is zero address");
        ussi.updateVault(address(0));
        
        // Test updating to same address (should revert)
        vm.expectRevert("vault not change");
        ussi.updateVault(newVault);
        
        vm.stopPrank();
        
        // Test non-owner cannot update vault
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.updateVault(address(0x456));
        vm.stopPrank();
    }

    function test_ApplyMint_TokenMint() public {
        vm.startPrank(owner);
        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        ussi.updateVault(vm.addr(0x123));
        vm.stopPrank();

        // Mint tokens to hedger
        deal(address(newToken), hedger, MINT_AMOUNT);

        // Create a token mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0, // Not used for TOKEN_MINT
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: newToken,
            vault: ussi.vault()
        });

        // Sign the order
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // Apply for minting
        vm.startPrank(hedger);
        IERC20(newToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Verify the application status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // Verify the token has been transferred
        assertEq(IERC20(newToken).balanceOf(hedger), 0);
        assertEq(IERC20(newToken).balanceOf(address(ussi)), MINT_AMOUNT);
    }

    function test_CancelMint_TokenMint() public {
        vm.startPrank(owner);
        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        ussi.updateVault(vm.addr(0x123));
        vm.stopPrank();

        // Mint tokens to hedger
        deal(address(newToken), hedger, MINT_AMOUNT);

        // Create a token mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0, // Not used for TOKEN_MINT
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: newToken,
            vault: ussi.vault()
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(newToken).approve(address(ussi), MINT_AMOUNT);
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

        // Verify the token has been returned
        assertEq(IERC20(newToken).balanceOf(hedger), MINT_AMOUNT);
        assertEq(IERC20(newToken).balanceOf(address(ussi)), 0);
    }

    function test_RejectMint_TokenMint() public {
        vm.startPrank(owner);
        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        ussi.updateVault(vm.addr(0x123));
        vm.stopPrank();

        // Mint tokens to hedger
        deal(address(newToken), hedger, MINT_AMOUNT);

        // Create a token mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0, // Not used for TOKEN_MINT
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: newToken,
            vault: ussi.vault()
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(newToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Reject minting
        vm.startPrank(owner);
        ussi.rejectMint(orderHash);
        vm.stopPrank();

        // Verify the rejection status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // Verify the token has been returned
        assertEq(IERC20(newToken).balanceOf(hedger), MINT_AMOUNT);
        assertEq(IERC20(newToken).balanceOf(address(ussi)), 0);
    }

    function test_ConfirmMint_TokenMint() public {
        vm.startPrank(owner);
        // Add a supported token
        address newToken = address(new MockToken("Test Token", "TEST", 18));
        ussi.addSupportToken(newToken);
        ussi.updateVault(vm.addr(0x123));
        ussi.addVaultRoute(hedger, vm.addr(0x999));
        vm.stopPrank();

        // Mint tokens to hedger
        deal(address(newToken), hedger, MINT_AMOUNT);

        // Create a token mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0, // Not used for TOKEN_MINT
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: newToken,
            vault: ussi.getVaultRoute(hedger)
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        IERC20(newToken).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // Confirm minting
        vm.startPrank(owner);
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // Verify the confirmation status
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));

        // Verify USSI tokens have been minted
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);

        // Verify tokens have been transferred to vault
        assertEq(IERC20(newToken).balanceOf(vm.addr(0x999)), MINT_AMOUNT);
        assertEq(IERC20(newToken).balanceOf(address(ussi)), 0);
    }

    function test_addVaultRoute() public {
        vm.startPrank(owner);
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x456));
        vm.stopPrank();

        // Verify the vault route has been added
        assertEq(ussi.vaultRoutes(vm.addr(0x123)), vm.addr(0x456));
    }

    function test_addVaultRoute_Revert() public {
        vm.startPrank(owner);
        vm.expectRevert("vault is zero address");
        ussi.addVaultRoute(vm.addr(0x123), address(0));
        vm.stopPrank();
    }

    function test_addVaultRoute_Revert_AlreadyExists() public {
        vm.startPrank(owner);
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x456));
        vm.expectRevert("vault route not change");
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x456));
        vm.stopPrank();
    }

    function test_removeVaultRoute() public {
        vm.startPrank(owner);
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x456));
        ussi.removeVaultRoute(vm.addr(0x123));
        vm.stopPrank();

        // Verify the vault route has been removed
        assertEq(ussi.vaultRoutes(vm.addr(0x123)), address(0));
    }

    function test_removeVaultRoute_Revert() public {
        vm.startPrank(owner);
        vm.expectRevert("vault route not exists");
        ussi.removeVaultRoute(vm.addr(0x123));
        vm.stopPrank();
    }

    function test_getVaultRoutes() public {
        vm.startPrank(owner);
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x456));
        vm.stopPrank();
        (address[] memory requesters, address[] memory vaults) = ussi.getVaultRoutes();
        assertEq(requesters.length, 1);
        assertEq(vaults.length, 1);
        assertEq(requesters[0], vm.addr(0x123));
        assertEq(vaults[0], vm.addr(0x456));
    }

    function test_getVaultRoute() public {
        vm.startPrank(owner);
        ussi.updateVault(vm.addr(0x456));
        ussi.addVaultRoute(vm.addr(0x123), vm.addr(0x789));
        vm.stopPrank();
        assertEq(ussi.getVaultRoute(vm.addr(0x123)), vm.addr(0x789));
        assertEq(ussi.getVaultRoute(vm.addr(0x999)), vm.addr(0x456));
    }

    function test_rescueToken() public {
        vm.startPrank(owner);
        ussi.addSupportToken(address(WBTC));
        ussi.updateVault(vm.addr(0x456));
        ussi.addVaultRoute(hedger, vm.addr(0x789));
        vm.stopPrank();

        // Create a token mint order
        USSI.HedgeOrder memory mintOrder = USSI.HedgeOrder({
            chain: "SETH",
            orderType: USSI.HedgeOrderType.TOKEN_MINT,
            assetID: 0, // Not used for TOKEN_MINT
            redeemToken: address(0),
            nonce: 0,
            inAmount: MINT_AMOUNT,
            outAmount: USSI_AMOUNT,
            deadline: block.timestamp + 600,
            requester: hedger,
            receiver: receiver,
            token: address(WBTC),
            vault: ussi.getVaultRoute(hedger)
        });

        bytes32 mintOrderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, mintOrderHash);
        bytes memory mintOrderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        deal(address(WBTC), hedger, MINT_AMOUNT);
        IERC20(WBTC).approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, mintOrderSign);
        vm.stopPrank();
        assertEq(IERC20(WBTC).balanceOf(address(ussi)), MINT_AMOUNT);
        assertEq(ussi.mintPendingAmounts(address(WBTC)), MINT_AMOUNT);

        // create a redeem order
        deal(address(ussi), hedger, USSI_AMOUNT);
        USSI.HedgeOrder memory redeemOrder = USSI.HedgeOrder({
            chain: "SETH",
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
        IERC20(address(ussi)).approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, redeemOrderSign);
        vm.stopPrank();
        assertEq(ussi.redeemPendingAmounts(address(WBTC)), MINT_AMOUNT);
        assertEq(ussi.redeemPendingAmounts(address(ussi)), USSI_AMOUNT);

        vm.startPrank(owner);
        // transfer WBTC to ussi
        deal(address(WBTC), address(ussi), MINT_AMOUNT * 2);
        vm.expectRevert("nothing to rescue");
        ussi.rescueToken(address(ussi));
        vm.expectRevert("nothing to rescue");
        ussi.rescueToken(address(WBTC));
        // over-transfer WBTC to ussi
        deal(address(WBTC), address(ussi), MINT_AMOUNT * 3);
        ussi.rescueToken(address(WBTC));
        assertEq(IERC20(WBTC).balanceOf(address(ussi.vault())), MINT_AMOUNT);
        vm.expectRevert("nothing to rescue");
        ussi.rescueToken(address(WBTC));
        vm.stopPrank();

        vm.startPrank(owner);
        ussi.confirmMint(mintOrderHash);
        assertEq(ussi.mintPendingAmounts(address(WBTC)), 0);
        assertEq(ussi.mintPendingAmounts(address(ussi)), 0);
        assertEq(IERC20(WBTC).balanceOf(ussi.getVaultRoute(hedger)), MINT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(owner);
        ussi.confirmRedeem(redeemOrderHash, bytes32(0));
        assertEq(ussi.redeemPendingAmounts(address(WBTC)), 0);
        assertEq(ussi.redeemPendingAmounts(address(ussi)), 0);
        assertEq(IERC20(WBTC).balanceOf(address(ussi)), 0);
        assertEq(IERC20(WBTC).balanceOf(hedger), MINT_AMOUNT);
        vm.stopPrank();
    }
}
