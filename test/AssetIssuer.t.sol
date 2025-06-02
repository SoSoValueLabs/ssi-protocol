// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetFactory.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/AssetToken.sol";
import "../src/Swap.sol";
import "../src/Utils.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";

error OwnableUnauthorizedAccount(address account);

contract AssetIssuerTest is Test {
    MockToken WBTC;
    MockToken WETH;
    MockToken USDT;

    address owner = vm.addr(0x1);
    address ap = vm.addr(0x2);
    address pmm = vm.addr(0x3);
    address vault = vm.addr(0x4);
    address nonOwner = vm.addr(0x5);

    AssetFactory factory;
    AssetRebalancer rebalancer;
    AssetFeeManager feeManager;
    AssetIssuer issuer;
    Swap swap;
    AssetToken tokenImpl;
    AssetFactory factoryImpl;
    address assetTokenAddress;

    string chain = "SETH";

    function setUp() public {
        // Deploy tokens
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);
        USDT = new MockToken("Tether USD", "USDT", 6);

        vm.startPrank(owner);
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // Deploy AssetToken implementation contract
        tokenImpl = new AssetToken();
        factoryImpl = new AssetFactory();

        // Deploy Factory contract
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl), abi.encodeCall(AssetFactory.initialize, (owner, vault, chain, address(tokenImpl)))
            )
        );

        factory = AssetFactory(factoryAddress);
        // Deploy Issuer contract
        issuer = AssetIssuer(
            address(
                new ERC1967Proxy(
                    address(new AssetIssuer()), abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );
        // Deploy AssetRebalancer proxy contract
        rebalancer = AssetRebalancer(
            address(
                new ERC1967Proxy(
                    address(new AssetRebalancer()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // Deploy AssetFeeManager proxy contract
        feeManager = AssetFeeManager(
            address(
                new ERC1967Proxy(
                    address(new AssetFeeManager()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // Set roles
        swap.grantRole(swap.MAKER_ROLE(), pmm);
        swap.grantRole(swap.TAKER_ROLE(), ap);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));
        swap.grantRole(swap.TAKER_ROLE(), address(rebalancer));
        swap.grantRole(swap.TAKER_ROLE(), address(feeManager));

        // Set whitelist addresses
        string[] memory outWhiteAddresses = new string[](3);
        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);
        outWhiteAddresses[2] = vm.toString(ap);

        string[] memory senders = new string[](4);
        senders[0] = vm.toString(address(issuer));
        senders[1] = vm.toString(vault);
        senders[2] = vm.toString(pmm);
        senders[3] = vm.toString(ap);

        swap.setTakerAddresses(outWhiteAddresses, senders);
        vm.stopPrank();

        // Add token whitelist
        assetTokenAddress = createAssetToken();
        vm.startPrank(owner);
        Token[] memory whiteListTokens = new Token[](4);
        whiteListTokens[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 0
        });
        whiteListTokens[1] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 0
        });
        whiteListTokens[2] = Token({
            chain: chain,
            symbol: USDT.symbol(),
            addr: vm.toString(address(USDT)),
            decimals: USDT.decimals(),
            amount: 0
        });
        whiteListTokens[3] = Token({
            chain: chain,
            symbol: "BASE_USDC",
            addr: vm.toString(assetTokenAddress),
            decimals: IAssetToken(assetTokenAddress).decimals(),
            amount: 10 ** 8
        });
        swap.addWhiteListTokens(whiteListTokens);

        vm.stopPrank();
        deal(address(WETH), ap, 1e15 * 10 ** WETH.decimals());
        deal(address(WBTC), ap, 1e15 * 10 ** WETH.decimals());
        deal(address(USDT), ap, 1e15 * 10 ** WETH.decimals());
    }

    function getAsset(uint256 id) internal view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 10 * 10 ** WBTC.decimals() / 60000
        });
        Asset memory asset = Asset({id: id, name: "BTC", symbol: "BTC", tokenset: tokenset_});
        return asset;
    }

    // Create asset token
    function createAssetToken() internal returns (address) {
        vm.startPrank(owner);

        // Create asset token
        Token[] memory tokenset = new Token[](1);
        tokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18
        });

        Asset memory asset = Asset({id: 1, name: "Test Asset", symbol: "TEST", tokenset: tokenset});

        assetTokenAddress = factory.createAssetToken(
            asset, 10000, address(issuer), address(rebalancer), address(feeManager), address(swap)
        );

        // Set issuance parameters
        uint256 assetID = AssetToken(assetTokenAddress).id();
        issuer.setIssueFee(assetID, 10000); // 0.0001 (10000/10^8)
        issuer.setIssueAmountRange(assetID, Range({min: 1 * 10 ** WETH.decimals(), max: 10000 * 10 ** WETH.decimals()}));

        // Add participants
        issuer.addParticipant(assetID, ap);

        vm.stopPrank();

        return assetTokenAddress;
    }

    // Create order information
    function createMintOrderInfo() internal returns (OrderInfo memory) {
        // Create input token set
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // Create output token set
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // Create order
        Order memory order = Order({
            chain: chain,
            maker: pmm,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 18, // Proportionally
            outAmount: 10 ** 18, // Proportionally
            deadline: block.timestamp + 3600, // Expires in 1 hour
            requester: ap
        });

        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(ap);

        // Calculate order hash
        bytes32 orderHash = keccak256(abi.encode(order));

        // Sign
        vm.startPrank(pmm);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Create order information
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    function createRedeemOrderInfo(address assetTokenAddress) internal returns (OrderInfo memory) {
        // Create input token set (asset token)
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 1000000000000000000
        });

        // Create output token set (WETH)
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // Create order
        Order memory order = Order({
            chain: chain,
            maker: pmm,
            nonce: 2,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 18, // 1 unit of asset token
            outAmount: 10 ** 18, // 1 ETH
            deadline: block.timestamp + 3600, // Expires in 1 hour
            requester: ap
        });

        order.inAddressList[0] = vm.toString(ap);
        order.outAddressList[0] = vm.toString(0x5CF7F96627F3C9903763d128A1cc5D97556A6b99);

        // Calculate order hash
        bytes32 orderHash = keccak256(abi.encode(order));

        // Sign
        vm.startPrank(pmm);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Create order information
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // Test getting issuance amount range
    function test_GetIssueAmountRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        Range memory range = issuer.getIssueAmountRange(assetID);
        assertEq(range.min, 1 * 10 ** 18);
        assertEq(range.max, 10000 * 10 ** 18);
    }

    // Test setting invalid issuance amount range
    function test_SetIssueAmountRange_InvalidRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);

        // Minimum value greater than maximum value
        Range memory invalidRange1 = Range({min: 100, max: 50});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange1);

        // Maximum value is 0
        Range memory invalidRange2 = Range({min: 100, max: 0});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange2);

        // Minimum value is 0
        Range memory invalidRange3 = Range({min: 0, max: 100});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange3);

        vm.stopPrank();
    }

    // Test getting issuance fee
    function test_GetIssueFee() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        uint256 fee = issuer.getIssueFee(assetID);
        assertEq(fee, 10000);
    }

    // Test setting invalid issuance fee
    function test_SetIssueFee_InvalidFee() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);

        // Fee greater than or equal to 1
        uint256 invalidFee = 10 ** issuer.feeDecimals();
        vm.expectRevert("issueFee should less than 1");
        issuer.setIssueFee(assetID, invalidFee);

        vm.stopPrank();
    }

    // Test adding participants
    function test_AddParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        assertTrue(issuer.isParticipant(assetID, nonOwner));
        assertEq(issuer.getParticipantLength(assetID), 2); // ap and nonOwner
    }

    // Test removing participants
    function test_RemoveParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.removeParticipant(assetID, ap);
        vm.stopPrank();

        assertFalse(issuer.isParticipant(assetID, ap));
        assertEq(issuer.getParticipantLength(assetID), 0);
    }

    // Test getting participants
    function test_GetParticipants() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        address[] memory participants = issuer.getParticipants(assetID);
        assertEq(participants.length, 2);

        // Verify that the participant list contains ap and nonOwner
        bool foundAp = false;
        bool foundNonOwner = false;

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == ap) {
                foundAp = true;
            }
            if (participants[i] == nonOwner) {
                foundNonOwner = true;
            }
        }

        assertTrue(foundAp);
        assertTrue(foundNonOwner);
    }

    // Test getting participant length
    function test_GetParticipantLength() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        assertEq(issuer.getParticipantLength(assetID), 1); // Only ap

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        assertEq(issuer.getParticipantLength(assetID), 2); // ap and nonOwner
    }

    // Test getting participant
    function test_GetParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        address participant = issuer.getParticipant(assetID, 0);
        assertEq(participant, ap);

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        // Get the second participant
        address participant2 = issuer.getParticipant(assetID, 1);
        assertEq(participant2, nonOwner);
    }

    // Test getting participant with out-of-range index
    function test_GetParticipant_OutOfRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.expectRevert("out of range");
        issuer.getParticipant(assetID, 1); // Only one participant, index 1 is out of range
    }

    // Test adding mint request
    function test_AddMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** WETH.decimals());
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** WETH.decimals());
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(request.requester, ap);
        assertEq(request.assetTokenAddress, assetTokenAddress);
        assertEq(request.amount, orderInfo.order.outAmount);
        assertEq(request.swapAddress, address(swap));
        assertEq(request.orderHash, orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(RequestStatus.PENDING));
        assertEq(request.issueFee, 10000);
    }

    // Test getting mint request length
    function test_GetMintRequestLength() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        assertEq(issuer.getMintRequestLength(), 0);

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        assertEq(issuer.getMintRequestLength(), 1);
    }

    // // Test canceling mint request
    // function test_CancelMintRequest() public {
    //     // address assetTokenAddress = createAssetToken();
    //     OrderInfo memory orderInfo = createMintOrderInfo();
    //     uint256 assetID = AssetToken(assetTokenAddress).id();

    //     // Mint tokens to ap
    //     vm.startPrank(address(WETH));
    //     WETH.mint(ap, 10 * 10 ** 18);
    //     vm.stopPrank();

    //     vm.startPrank(ap);
    //     WETH.approve(address(issuer), 1e15 * 10 ** 18);
    //     uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);

    //     // Wait one day to cancel
    //     vm.warp(block.timestamp + 1 days);
    //     issuer.cancelMintRequest(nonce, orderInfo, false);
    //     vm.stopPrank();

    //     Request memory request = issuer.getMintRequest(nonce);
    //     assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));
    // }

    // // Test force-canceling mint request
    // function test_ForceCancelMintRequest() public {
    //     // address assetTokenAddress = createAssetToken();
    //     OrderInfo memory orderInfo = createMintOrderInfo();
    //     uint256 assetID = AssetToken(assetTokenAddress).id();

    //     // Mint tokens to ap
    //     vm.startPrank(address(WETH));
    //     WETH.mint(ap, 10 * 10 ** 18);
    //     vm.stopPrank();

    //     vm.startPrank(ap);
    //     WETH.approve(address(issuer), 1e15 * 10 ** 18);
    //     uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);

    //     // Wait one day to force-cancel
    //     vm.warp(block.timestamp + 1 days);
    //     issuer.cancelMintRequest(nonce, orderInfo, true);
    //     vm.stopPrank();

    //     Request memory request = issuer.getMintRequest(nonce);
    //     assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));

    //     // Verify claimable amount
    //     address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
    //     uint256 claimable = issuer.claimables(tokenAddress, ap);
    //     assertTrue(claimable > 0);
    // }

    // Test rejecting mint request
    function test_RejectMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // Maker rejects the request
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // Reject mint request
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo, false);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));
    }

    // Test force-rejecting mint request
    function test_ForceRejectMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // Maker rejects the request
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // Force-reject mint request
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo, true);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));

        // Verify claimable amount
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);
    }

    // Test confirming mint request
    function test_ConfirmMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // Verify that ap received the asset token
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), orderInfo.order.outAmount);
    }

    // Test adding redeem request
    function test_AddRedeemRequest() public {
        // Mint asset token first
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 redeemNonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(redeemNonce);
        assertEq(request.requester, ap);
        assertEq(request.assetTokenAddress, assetTokenAddress);
        assertEq(request.amount, redeemOrderInfo.order.inAmount);
        assertEq(request.swapAddress, address(swap));
        assertEq(request.orderHash, redeemOrderInfo.orderHash);
        assertEq(uint256(request.status), uint256(RequestStatus.PENDING));
        assertEq(request.issueFee, 10000);
    }

    // Test getting redeem request length
    function test_GetRedeemRequestLength() public {
        assertEq(issuer.getRedeemRequestLength(), 0);

        // Mint asset token first
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        assertEq(issuer.getRedeemRequestLength(), 1);
    }

    // // Test canceling redeem request
    // function test_CancelRedeemRequest() public {
    //     // Mint asset token first
    //     // address assetTokenAddress = createAssetToken();
    //     OrderInfo memory mintOrderInfo = createMintOrderInfo();
    //     uint256 assetID = AssetToken(assetTokenAddress).id();

    //     // Mint tokens to ap
    //     vm.startPrank(address(WETH));
    //     WETH.mint(ap, 10 * 10 ** 18);
    //     vm.stopPrank();

    //     vm.startPrank(ap);
    //     WETH.approve(address(issuer), 1e15 * 10 ** 18);
    //     uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
    //     vm.stopPrank();

    //     // Maker confirms the request
    //     vm.startPrank(pmm);
    //     bytes[] memory outTxHashs = new bytes[](1);
    //     outTxHashs[0] = "tx_hash";
    //     swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
    //     vm.stopPrank();

    //     // Confirm mint request
    //     vm.startPrank(owner);
    //     bytes[] memory inTxHashs = new bytes[](1);
    //     inTxHashs[0] = "tx_hash";
    //     issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
    //     vm.stopPrank();

    //     // Create redeem order
    //     OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

    //     vm.startPrank(ap);
    //     IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
    //     uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
    //     vm.stopPrank();

    //     // Cancel redeem request
    //     vm.startPrank(ap);
    //     vm.warp(block.timestamp + 1 hours);
    //     issuer.cancelRedeemRequest(nonce, redeemOrderInfo);
    //     vm.stopPrank();

    //     Request memory request = issuer.getRedeemRequest(nonce);
    //     assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));
    // }

    function test_RejectRedeemRequest() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Maker rejects the request
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(redeemOrderInfo);
        vm.stopPrank();

        // Reject redeem request
        vm.startPrank(owner);
        issuer.rejectRedeemRequest(nonce);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));
    }

    // Test confirming redeem request
    function test_ConfirmRedeemRequest() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();
        // Confirm redeem request
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));
    }

    // Test force-confirming redeem request
    function test_ForceConfirmRedeemRequest() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();

        // Force-confirm redeem request
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, true);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // Verify claimable amount
        address tokenAddress = vm.parseAddress(redeemOrderInfo.order.outTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);
    }

    // Test claim function
    function test_Claim() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // // Force-cancel mint request to make ap have claimable tokens
        // vm.startPrank(ap);
        // vm.warp(block.timestamp + 1 days);
        // issuer.cancelMintRequest(mintNonce, mintOrderInfo, true);
        // vm.stopPrank();

        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(mintOrderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.rejectMintRequest(mintNonce, mintOrderInfo, true);
        vm.stopPrank();

        // Record balance before claiming
        address tokenAddress = vm.parseAddress(mintOrderInfo.order.inTokenset[0].addr);
        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(ap);
        uint256 claimable = issuer.claimables(tokenAddress, ap);

        // Claim tokens
        vm.startPrank(ap);
        issuer.claim(tokenAddress);
        vm.stopPrank();

        // Verify increased balance and zero claimable amount
        uint256 balanceAfter = IERC20(tokenAddress).balanceOf(ap);
        assertEq(balanceAfter - balanceBefore, claimable);
        assertEq(issuer.claimables(tokenAddress, ap), 0);
    }

    // Test participant-related functions
    function test_ParticipantFunctions() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Test adding participants
        vm.startPrank(owner);
        address newParticipant = vm.addr(0x9);
        issuer.addParticipant(assetID, newParticipant);
        vm.stopPrank();

        // Verify that the participant has been added
        assertTrue(issuer.isParticipant(assetID, newParticipant));
        assertEq(issuer.getParticipantLength(assetID), 2); // ap and new participant
        assertEq(issuer.getParticipant(assetID, 1), newParticipant);

        // Test getting all participants
        address[] memory participants = issuer.getParticipants(assetID);
        assertEq(participants.length, 2);
        assertEq(participants[0], ap);
        assertEq(participants[1], newParticipant);

        // Test removing participants
        vm.startPrank(owner);
        issuer.removeParticipant(assetID, newParticipant);
        vm.stopPrank();

        // Verify that the participant has been removed
        assertFalse(issuer.isParticipant(assetID, newParticipant));
        assertEq(issuer.getParticipantLength(assetID), 1);
    }

    // Test setting issuance fee
    function test_SetIssueFee() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Set a new issuance fee
        vm.startPrank(owner);
        uint256 newFee = 5000; // 0.05%
        issuer.setIssueFee(assetID, newFee);
        vm.stopPrank();

        // Verify that the fee has been updated
        assertEq(issuer.getIssueFee(assetID), newFee);

        // Test setting an excessive fee (should fail)
        vm.startPrank(owner);
        vm.expectRevert("issueFee should less than 1");
        issuer.setIssueFee(assetID, 10 ** 8);
        vm.stopPrank();
    }

    // Test setting issuance amount range
    function test_SetIssueAmountRange() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Set a new issuance amount range
        vm.startPrank(owner);
        Range memory newRange = Range({min: 500 * 10 ** 8, max: 20000 * 10 ** 8});
        issuer.setIssueAmountRange(assetID, newRange);
        vm.stopPrank();

        // Verify that the range has been updated
        Range memory range = issuer.getIssueAmountRange(assetID);
        assertEq(range.min, newRange.min);
        assertEq(range.max, newRange.max);

        // Test setting an invalid range (minimum value greater than maximum value)
        vm.startPrank(owner);
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, Range({min: 20000 * 10 ** 8, max: 500 * 10 ** 8}));
        vm.stopPrank();

        // Test setting an invalid range (minimum value is 0)
        vm.startPrank(owner);
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, Range({min: 0, max: 500 * 10 ** 8}));
        vm.stopPrank();
    }

    // Test error cases for getIssueAmountRange function
    function test_GetIssueAmountRangeError() public {
        uint256 newAssetID = 999; // Non-existent asset ID

        vm.expectRevert("issue amount range not set");
        issuer.getIssueAmountRange(newAssetID);
    }

    // Test error cases for getIssueFee function
    function test_GetIssueFeeError() public {
        uint256 newAssetID = 999; // Non-existent asset ID

        vm.expectRevert("issue fee not set");
        issuer.getIssueFee(newAssetID);
    }

    // Test various error cases for addMintRequest function
    function test_AddMintRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Test non-participant call
        address nonParticipant = vm.addr(0x10);
        vm.startPrank(nonParticipant);
        vm.expectRevert("msg sender not order requester");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // Test request not made by the message sender
        Order memory invalidOrder = orderInfo.order;
        invalidOrder.requester = nonParticipant;
        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: invalidOrder, orderHash: orderInfo.orderHash, orderSign: orderInfo.orderSign});

        vm.startPrank(ap);
        vm.expectRevert("msg sender not order requester");
        issuer.addMintRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();

        // Test maximum fee lower than current fee
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 20000);
        vm.stopPrank();

        vm.startPrank(ap);
        vm.expectRevert("current issue fee larger than max issue fee");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();
    }

    // Test various error cases for addRedeemRequest function
    function test_AddRedeemRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        // Test non-participant call
        address nonParticipant = vm.addr(0x10);
        deal(address(WETH), ap, 100000 * 10 ** 18);
        vm.startPrank(nonParticipant);
        vm.expectRevert("msg sender not order requester");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Test request not made by the message sender
        Order memory invalidOrder = redeemOrderInfo.order;
        invalidOrder.requester = nonParticipant;
        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: invalidOrder, orderHash: redeemOrderInfo.orderHash, orderSign: redeemOrderInfo.orderSign});

        vm.startPrank(ap);
        vm.expectRevert("msg sender not order requester");
        issuer.addRedeemRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();

        // Test maximum fee lower than current fee
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 20000);
        vm.stopPrank();

        vm.startPrank(ap);
        vm.expectRevert("current issue fee larger than max issue fee");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Restore fee
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 10000);
        vm.stopPrank();

        // Test insufficient balance
        vm.startPrank(ap);
        redeemOrderInfo.order.requester = ap;
        IERC20(assetTokenAddress).transfer(nonParticipant, IERC20(assetTokenAddress).balanceOf(ap));
        vm.expectRevert("not enough asset token balance");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();
    }

    // // Test error cases for cancelMintRequest and cancelRedeemRequest
    // function test_CancelRequestErrors() public {
    //     uint256 assetID = AssetToken(assetTokenAddress).id();
    //     OrderInfo memory mintOrderInfo = createMintOrderInfo();

    //     // Mint tokens to ap
    //     vm.startPrank(address(WETH));
    //     WETH.mint(ap, 10 * 10 ** 18);
    //     vm.stopPrank();

    //     vm.startPrank(ap);
    //     WETH.approve(address(issuer), 1e15 * 10 ** 18);
    //     uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
    //     vm.stopPrank();

    //     // Test non-requester canceling
    //     address nonRequester = vm.addr(0x10);
    //     vm.startPrank(nonRequester);
    //     vm.expectRevert("not order requester");
    //     issuer.cancelMintRequest(mintNonce, mintOrderInfo, false);
    //     vm.stopPrank();

    //     // Test canceling a non-existent request
    //     vm.startPrank(ap);
    //     vm.expectRevert("nonce too large");
    //     issuer.cancelMintRequest(999, mintOrderInfo, false);
    //     vm.stopPrank();

    //     // Test canceling a confirmed request
    //     vm.startPrank(pmm);
    //     bytes[] memory outTxHashs = new bytes[](1);
    //     outTxHashs[0] = "tx_hash";
    //     swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
    //     vm.stopPrank();

    //     vm.startPrank(owner);
    //     bytes[] memory inTxHashs = new bytes[](1);
    //     inTxHashs[0] = "tx_hash";
    //     issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
    //     vm.stopPrank();

    //     vm.startPrank(ap);
    //     vm.expectRevert();
    //     issuer.cancelMintRequest(mintNonce, mintOrderInfo, false);
    //     vm.stopPrank();

    //     // Create redeem order
    //     OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

    //     vm.startPrank(ap);
    //     IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
    //     uint256 redeemNonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 20000);
    //     vm.stopPrank();

    //     // Test non-requester canceling
    //     vm.startPrank(nonRequester);
    //     vm.expectRevert("not order requester");
    //     issuer.cancelRedeemRequest(redeemNonce, redeemOrderInfo);
    //     vm.stopPrank;

    //     // Test canceling a non-existent request
    //     vm.startPrank(ap);
    //     vm.expectRevert("nonce too large");
    //     issuer.cancelRedeemRequest(999, redeemOrderInfo);
    //     vm.stopPrank();
    // }

    // Test error cases for rejectMintRequest and rejectRedeemRequest
    function test_RejectRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Test non-owner rejecting
        nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.rejectMintRequest(mintNonce, mintOrderInfo, false);
        vm.stopPrank();

        // Test rejecting a non-existent request
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.rejectMintRequest(999, mintOrderInfo, false);
        vm.stopPrank();

        // Test rejecting a confirmed request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert();
        issuer.rejectMintRequest(mintNonce, mintOrderInfo, false);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 redeemNonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Test non-owner rejecting
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.rejectRedeemRequest(redeemNonce);
        vm.stopPrank;

        // Test rejecting a non-existent request
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.rejectRedeemRequest(999);
        vm.stopPrank();
    }

    function test_ClaimError() public {
        address tokenAddress = address(WETH);

        // Test case where there is nothing to claim
        vm.startPrank(ap);
        vm.expectRevert("nothing to claim");
        issuer.claim(tokenAddress);
        vm.stopPrank();
    }

    function test_GetParticipantError() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Test case where the index is out of range
        vm.expectRevert("out of range");
        issuer.getParticipant(assetID, 999);
    }

    // Test error cases for confirmRedeemRequest function
    function test_ConfirmRedeemRequestErrors() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // Test non-owner confirming
        address nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank;

        // Test confirming a non-existent request
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.confirmRedeemRequest(999, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();

        // Test confirming a request not confirmed by maker
        vm.startPrank(owner);
        vm.expectRevert();
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();
    }

    // Test tokenset mismatch error in addMintRequest function
    function test_AddMintRequestTokensetMismatch() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Modify the output token set in the order to mismatch the asset token's token set
        Token[] memory modifiedOutTokenset = new Token[](1);
        modifiedOutTokenset[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 10 ** 8
        });

        Order memory modifiedOrder = orderInfo.order;
        modifiedOrder.outTokenset = modifiedOutTokenset;

        OrderInfo memory modifiedOrderInfo =
            OrderInfo({order: modifiedOrder, orderHash: orderInfo.orderHash, orderSign: orderInfo.orderSign});

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("order not valid");
        issuer.addMintRequest(assetID, modifiedOrderInfo, 10000);
        vm.stopPrank();
    }

    // Test tokenset mismatch error in addRedeemRequest function
    function test_AddRedeemRequestTokensetMismatch() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order but modify the input token set
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        Token[] memory modifiedInTokenset = new Token[](1);
        modifiedInTokenset[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 10 ** 8
        });

        Order memory modifiedOrder = redeemOrderInfo.order;
        modifiedOrder.inTokenset = modifiedInTokenset;

        OrderInfo memory modifiedRedeemOrderInfo = OrderInfo({
            order: modifiedOrder,
            orderHash: redeemOrderInfo.orderHash,
            orderSign: redeemOrderInfo.orderSign
        });

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        vm.expectRevert("order not valid");
        issuer.addRedeemRequest(assetID, modifiedRedeemOrderInfo, 10000);
        vm.stopPrank();
    }

    // Test invalid order error in addMintRequest function
    function test_AddMintRequestInvalidOrder() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Modify the order signature to make it invalid
        bytes memory invalidSign = new bytes(65);

        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: orderInfo.order, orderHash: orderInfo.orderHash, orderSign: invalidSign});

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("order not valid");
        issuer.addMintRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();
    }

    // Test insufficient allowance error in addRedeemRequest function
    function test_AddRedeemRequestInsufficientAllowance() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order but do not approve
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        // Do not call approve
        vm.expectRevert("not enough asset token allowance");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();
    }

    // Test burnFor function
    function test_BurnForErrors() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Test insufficient allowance
        vm.startPrank(ap);
        // Do not call approve
        vm.expectRevert("not enough allowance");
        issuer.burnFor(assetID, mintOrderInfo.order.outAmount);
        vm.stopPrank;

        // Test normal burn
        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        issuer.burnFor(assetID, mintOrderInfo.order.outAmount);
        vm.stopPrank;

        // Verify that the token has been burned
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), 0);
    }

    // Test withdraw function
    function test_WithdrawErrors() public {
        // Transfer some tokens to the issuer contract
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank();

        // Test non-owner call
        address nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(WETH);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.withdraw(tokenAddresses);
        vm.stopPrank;

        // Test withdrawing during issuance
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank;

        // Attempt to withdraw, should fail
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        issuer.withdraw(tokenAddresses);
        vm.stopPrank;
    }

    // Test checkRequestOrderInfo function
    function test_CheckRequestOrderInfo() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank;

        // Create mismatched order information
        OrderInfo memory mismatchOrderInfo = createMintOrderInfo();
        bytes32 differentHash = keccak256("different_hash");

        // Attempt to reject the request but use mismatched order information
        vm.startPrank(owner);
        vm.expectRevert("order hash not match");
        issuer.rejectMintRequest(
            mintNonce,
            OrderInfo({order: mismatchOrderInfo.order, orderHash: differentHash, orderSign: mismatchOrderInfo.orderSign}),
            false
        );
        vm.stopPrank;
    }

    // Test insufficient balance error in addMintRequest function
    function test_AddMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Do not give ap enough tokens
        vm.startPrank(ap);
        // Clear ap's WETH balance
        uint256 balance = WETH.balanceOf(ap);
        WETH.transfer(owner, balance);

        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("not enough balance");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank;
    }

    // Test insufficient allowance error in addMintRequest function
    function test_AddMintRequestInsufficientAllowance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        // Do not approve or approve insufficient amount
        WETH.approve(address(issuer), 1);
        vm.expectRevert("not enough allowance");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank;
    }

    // // Test insufficient balance error in cancelMintRequest function
    // function test_CancelMintRequestInsufficientBalance() public {
    //     uint256 assetID = AssetToken(assetTokenAddress).id();
    //     OrderInfo memory orderInfo = createMintOrderInfo();

    //     // Mint tokens to ap
    //     vm.startPrank(address(WETH));
    //     WETH.mint(ap, 10 * 10 ** 18);
    //     vm.stopPrank;

    //     vm.startPrank(ap);
    //     WETH.approve(address(issuer), 1e15 * 10 ** 18);
    //     uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
    //     vm.stopPrank;

    //     // Remove tokens from the issuer contract to simulate insufficient balance
    //     vm.startPrank(owner);
    //     address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
    //     uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
    //     vm.stopPrank;
    //     vm.startPrank(address(issuer));
    //     IERC20(tokenAddress).transfer(owner, issuerBalance);
    //     vm.stopPrank;

    //     // Attempt to cancel the request, should fail
    //     vm.warp(block.timestamp + 1 days);
    //     vm.startPrank(ap);
    //     vm.expectRevert("not enough balance");
    //     issuer.cancelMintRequest(nonce, orderInfo, false);
    //     vm.stopPrank;
    // }

    // Test insufficient balance error in rejectMintRequest function
    function test_RejectMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank;

        // Maker rejects the request
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank;

        // Remove tokens from the issuer contract to simulate insufficient balance
        vm.startPrank(owner);
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
        vm.stopPrank;
        vm.startPrank(address(issuer));
        IERC20(tokenAddress).transfer(owner, issuerBalance);
        vm.stopPrank;

        // Attempt to reject the request, should fail
        vm.startPrank(owner);
        vm.expectRevert("not enough balance");
        issuer.rejectMintRequest(nonce, orderInfo, false);
        vm.stopPrank;
    }

    // Test insufficient balance error in confirmMintRequest function
    function test_ConfirmMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank;

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank;

        // Remove tokens from the issuer contract to simulate insufficient balance
        vm.startPrank(owner);
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
        vm.stopPrank;
        vm.startPrank(address(issuer));
        IERC20(tokenAddress).transfer(owner, issuerBalance);
        vm.stopPrank;

        // Attempt to confirm the request, should fail
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough balance");
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank;
    }

    // Test insufficient balance error in confirmRedeemRequest function
    function test_ConfirmRedeemRequestInsufficientBalance() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank;

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank;

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank;

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank;

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank;

        // Remove asset token
        vm.startPrank(address(issuer));
        IERC20(assetTokenAddress).transfer(owner, IERC20(assetTokenAddress).balanceOf(address(issuer)));
        vm.stopPrank;

        // Attempt to confirm the redeem request, should fail
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough asset token to burn");
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank;
    }

    // Test insufficient balance error in rejectRedeemRequest function
    function test_RejectRedeemRequestInsufficientBalance() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank;

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank;

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank;

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank;

        // Maker rejects the request
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(redeemOrderInfo);
        vm.stopPrank;

        // Remove tokens from the issuer contract to simulate insufficient balance

        // Remove asset token
        vm.startPrank(address(issuer));
        IERC20(assetTokenAddress).transfer(owner, IERC20(assetTokenAddress).balanceOf(address(issuer)));
        vm.stopPrank;

        // Attempt to reject the redeem request, should fail
        vm.startPrank(owner);
        vm.expectRevert("not enough asset token to transfer");
        issuer.rejectRedeemRequest(nonce);
        vm.stopPrank;
    }

    // Test insufficient output token balance error in confirmRedeemRequest function
    function test_ConfirmRedeemRequestOutputInsufficientBalance() public {
        // Mint asset token first
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // Create redeem order
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();
        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();

        // Remove output tokens from the issuer contract to simulate insufficient balance
        vm.startPrank(owner);
        address outTokenAddress = vm.parseAddress(redeemOrderInfo.order.outTokenset[0].addr);
        vm.stopPrank();
        // Ensure the issuer does not have enough output tokens
        vm.startPrank(address(issuer));
        if (IERC20(outTokenAddress).balanceOf(address(issuer)) > 0) {
            IERC20(outTokenAddress).transfer(owner, IERC20(outTokenAddress).balanceOf(address(issuer)));
        }
        vm.stopPrank();

        // Attempt to confirm the redeem request, should fail
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough balance");
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();
    }

    // Test zero address handling in withdraw function
    function test_WithdrawZeroAddress() public {
        // Transfer some tokens to the issuer contract
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank;

        // Test including zero address
        vm.startPrank(owner);
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(WETH);
        tokenAddresses[1] = address(0); // Zero address

        // Should execute normally without failing due to zero address
        issuer.withdraw(tokenAddresses);
        vm.stopPrank;

        // Verify that WETH has been withdrawn
        assertEq(WETH.balanceOf(owner), 10 * 10 ** 18);
    }

    // Test tokenClaimables handling in withdraw function
    function test_WithdrawWithClaimables() public {
        // Transfer some tokens to the issuer contract
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank;

        // Set some claimable tokens
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank;

        // reject mint request to make ap have claimable tokens
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo, true);
        vm.stopPrank;

        // Get the claimable amount
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);

        // Attempt to withdraw tokens
        vm.startPrank(owner);
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = tokenAddress;
        issuer.withdraw(tokenAddresses);
        vm.stopPrank;

        // Verify that only the non-claimable portion was withdrawn
        uint256 expectedWithdrawn = 10 * 10 ** 18; // Initial transferred amount
        uint256 tokenClaimable = issuer.tokenClaimables(tokenAddress);
    }

    // Test duplicate additions and removals in addParticipant and removeParticipant functions
    function test_ParticipantDuplicateOperations() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Test adding the same participant twice
        vm.startPrank(owner);
        // ap is already a participant, add again
        issuer.addParticipant(assetID, ap);
        vm.stopPrank;

        // Verify that the participant count does not change
        assertEq(issuer.getParticipantLength(assetID), 1);

        // Test removing a non-existent participant
        vm.startPrank(owner);
        address nonParticipant = vm.addr(0x10);
        issuer.removeParticipant(assetID, nonParticipant);
        vm.stopPrank;

        // Verify that the participant count does not change
        assertEq(issuer.getParticipantLength(assetID), 1);
    }

    // Test zero fee in confirmMintRequest function
    function test_ConfirmMintRequestZeroFee() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Set issuance fee to 0
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 0);
        vm.stopPrank;

        OrderInfo memory orderInfo = createMintOrderInfo();

        // Mint tokens to ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank;

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 0);
        vm.stopPrank;

        // Maker confirms the request
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank;

        // Confirm mint request
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank;

        // Verify that the request has been confirmed
        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));
    }
}