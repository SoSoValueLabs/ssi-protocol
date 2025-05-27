// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/Utils.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";

contract SwapTest is Test {
    MockToken WBTC;
    MockToken WETH;

    address owner = vm.addr(0x1);
    address maker = vm.addr(0x2);
    address taker = vm.addr(0x3);
    address receiver = vm.addr(0x4);
    address nonOwner = vm.addr(0x5);

    Swap swap;
    string chain = "SETH";

    function setUp() public {
        // Deploy tokens
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // Deploy Swap contract
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // Set roles
        swap.grantRole(swap.MAKER_ROLE(), maker);
        swap.grantRole(swap.TAKER_ROLE(), taker);

        // Set whitelist addresses
        string[] memory receivers = new string[](2);
        receivers[0] = vm.toString(receiver);
        receivers[1] = vm.toString(taker);

        string[] memory senders = new string[](2);
        senders[0] = vm.toString(maker);
        senders[1] = vm.toString(taker);

        swap.setTakerAddresses(receivers, senders);

        // Add token whitelist
        Token[] memory whiteListTokens = new Token[](2);
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
        swap.addWhiteListTokens(whiteListTokens);

        vm.stopPrank();
    }

    // Create order information
    function createOrderInfo() public returns (OrderInfo memory) {
        // Create input token set
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 1 * 10 ** 8 // 1 BTC
        });

        // Create output token set
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 20 * 10 ** 18 // 20 ETH
        });

        // Create order
        Order memory order = Order({
            chain: chain,
            maker: maker,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8, // 1 BTC
            outAmount: 10 ** 8, // Proportionally
            deadline: block.timestamp + 3600, // Expires in 1 hour
            requester: taker
        });

        order.inAddressList[0] = vm.toString(maker);
        order.outAddressList[0] = vm.toString(receiver);

        // Calculate order hash
        bytes32 orderHash = keccak256(abi.encode(order));

        // Sign
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Create order information
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // Test initialization
    function test_Initialize() public {
        assertEq(swap.chain(), chain);
        assertTrue(swap.hasRole(swap.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(swap.hasRole(swap.MAKER_ROLE(), maker));
        assertTrue(swap.hasRole(swap.TAKER_ROLE(), taker));
    }

    // Test adding whitelist tokens
    function test_AddWhiteListTokens() public {
        vm.startPrank(owner);

        // Add new token
        MockToken USDT = new MockToken("Tether USD", "USDT", 6);
        Token[] memory newTokens = new Token[](1);
        newTokens[0] = Token({
            chain: chain,
            symbol: USDT.symbol(),
            addr: vm.toString(address(USDT)),
            decimals: USDT.decimals(),
            amount: 0
        });

        swap.addWhiteListTokens(newTokens);

        // Verify whitelist length
        assertEq(swap.getWhiteListTokenLength(), 3);

        // Verify the newly added token
        Token memory token = swap.getWhiteListToken(2);
        assertEq(token.symbol, "USDT");

        vm.stopPrank();
    }

    // Test removing whitelist tokens
    function test_RemoveWhiteListTokens() public {
        vm.startPrank(owner);

        // Remove WBTC
        Token[] memory tokensToRemove = new Token[](1);
        tokensToRemove[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 0
        });

        swap.removeWhiteListTokens(tokensToRemove);

        // Verify whitelist length
        assertEq(swap.getWhiteListTokenLength(), 1);

        vm.stopPrank();
    }

    // Test setting Taker addresses
    function test_SetTakerAddresses() public {
        vm.startPrank(owner);

        // Set new Taker addresses
        string[] memory newReceivers = new string[](1);
        newReceivers[0] = vm.toString(vm.addr(0x6));

        string[] memory newSenders = new string[](1);
        newSenders[0] = vm.toString(vm.addr(0x7));

        swap.setTakerAddresses(newReceivers, newSenders);

        // Verify the new Taker addresses
        (string[] memory receivers, string[] memory senders) = swap.getTakerAddresses();
        assertEq(receivers.length, 1);
        assertEq(senders.length, 1);
        assertEq(receivers[0], newReceivers[0]);
        assertEq(senders[0], newSenders[0]);

        vm.stopPrank();
    }

    // Test pause and unpause
    function test_PauseAndUnpause() public {
        vm.startPrank(owner);

        // Pause
        swap.pause();
        assertTrue(swap.paused());

        // Unpause
        swap.unpause();
        assertFalse(swap.paused());

        vm.stopPrank();
    }

    // Test adding swap request
    function test_AddSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(taker);

        // Add swap request
        swap.addSwapRequest(orderInfo, false, false);

        // Verify swap request
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
        assertEq(request.requester, taker);

        vm.stopPrank();
    }

    // Test adding swap request - by contract
    function test_AddSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Mint tokens to maker
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // Maker approves swap contract
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(taker);

        // Add swap request (output via contract)
        swap.addSwapRequest(orderInfo, false, true);

        // Verify swap request
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
        assertEq(request.requester, taker);
        assertTrue(request.outByContract);

        vm.stopPrank();
    }

    // Test maker confirm swap request - not by contract
    function test_MakerConfirmSwapRequest_NotByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker confirms
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.MAKER_CONFIRMED));
        assertEq(bytes32(request.outTxHashs[0]), bytes32("tx_hash_123"));
    }

    // Test maker confirm swap request - by contract
    function test_MakerConfirmSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // Mint tokens to maker
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // Maker confirms
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.MAKER_CONFIRMED));

        // Verify token transfer
        assertEq(WETH.balanceOf(receiver), 20 * 10 ** 18);
    }

    // Test taker confirm swap request - not by contract
    function test_ConfirmSwapRequest_NotByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker confirms
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Taker confirms
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash_456";
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CONFIRMED));
        assertEq(bytes32(request.inTxHashs[0]), bytes32("tx_hash_456"));
    }

    // Test taker confirm swap request - by contract
    function test_ConfirmSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // Maker confirms
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Mint tokens to taker
        vm.startPrank(address(WBTC));
        WBTC.mint(taker, 2 * 10 ** 8);
        vm.stopPrank();

        // Taker confirms
        vm.startPrank(taker);
        WBTC.approve(address(swap), 2 * 10 ** 8);
        bytes[] memory inTxHashs = new bytes[](0);
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CONFIRMED));

        // Verify token transfer
        assertEq(WBTC.balanceOf(maker), 1 * 10 ** 8);
    }

    // Test rollback swap request
    function test_RollbackSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker confirms
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Taker rollbacks
        vm.startPrank(taker);
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
    }

    // Test cancel swap request
    function test_CancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // Advance time
        vm.warp(block.timestamp + 3601); // Exceeds MAX_MARKER_CONFIRM_DELAY

        // Cancel request
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CANCEL));
    }

    // Test force cancel swap request
    function test_ForceCancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 7 hours); // Exceeds EXPIRATION

        // Admin force cancels
        vm.startPrank(owner);
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.FORCE_CANCEL));
    }

    // Test maker reject swap request
    function test_MakerRejectSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker rejects
        vm.startPrank(maker);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.REJECTED));
    }

    // Test error case: non-admin adding whitelist tokens
    function test_AddWhiteListTokens_NotAdmin() public {
        vm.startPrank(nonOwner);

        Token[] memory tokens = new Token[](1);
        tokens[0] = Token({chain: chain, symbol: "TEST", addr: vm.toString(address(0x123)), decimals: 18, amount: 0});

        vm.expectRevert();
        swap.addWhiteListTokens(tokens);

        vm.stopPrank();
    }

    // Test error case: order expired
    function test_AddSwapRequest_Expired() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify order deadline to the past
        orderInfo.order.deadline = block.timestamp - 1;

        // Recalculate hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(taker);

        // Attempt to add an expired swap request
        vm.expectRevert();
        swap.addSwapRequest(orderInfo, false, false);

        vm.stopPrank();
    }

    // Test error case: non-taker cancels request
    function test_CancelSwapRequest_NotTaker() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 3601);

        // Non-taker attempts to cancel
        vm.startPrank(nonOwner);
        vm.expectRevert();
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: non-maker confirms request
    function test_MakerConfirmSwapRequest_NotMaker() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Non-maker attempts to confirm
        vm.startPrank(nonOwner);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        vm.expectRevert();
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
    }

    // Test error case: insufficient balance for contract transfer
    function test_MakerConfirmSwapRequest_InsufficientBalance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // Maker attempts to confirm but has insufficient balance
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        vm.expectRevert("not enough balance");
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
    }

    // Test error case: insufficient allowance for contract transfer
    function test_MakerConfirmSwapRequest_InsufficientAllowance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // Mint tokens to maker but do not approve
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // Maker attempts to confirm but has insufficient allowance
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](0);
        vm.expectRevert("not enough allowance");
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
    }

    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////
    function test_CheckOrderInfo_InvalidOrderHash() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the order hash to make it mismatch
        orderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 2); // Order hash mismatch
    }

    // Test error case: invalid signature
    function test_CheckOrderInfo_InvalidSignature() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the signature to make it invalid
        orderInfo.orderSign = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 3); // Invalid signature
    }

    // Test error case: order already exists
    function test_CheckOrderInfo_OrderExists() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add the order first
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Check the order again
        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 4); // Order already exists
    }

    // Test error case: input address list length mismatch
    function test_CheckOrderInfo_InAddressListLengthMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the input address list length
        string[] memory newInAddressList = new string[](2);
        newInAddressList[0] = orderInfo.order.inAddressList[0];
        newInAddressList[1] = vm.toString(nonOwner);
        orderInfo.order.inAddressList = newInAddressList;

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 5); // Input address list length mismatch
    }

    // Test error case: output address list length mismatch
    function test_CheckOrderInfo_OutAddressListLengthMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the output address list length
        string[] memory newOutAddressList = new string[](2);
        newOutAddressList[0] = orderInfo.order.outAddressList[0];
        newOutAddressList[1] = vm.toString(receiver);
        orderInfo.order.outAddressList = newOutAddressList;

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 6); // Output address list length mismatch
    }

    // Test error case: maker is not MAKER_ROLE
    function test_CheckOrderInfo_NotMakerRole() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the maker to a non-MAKER_ROLE
        orderInfo.order.maker = nonOwner;

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(nonOwner);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x5, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 7); // Not MAKER_ROLE
    }

    // Test error case: output address not whitelisted
    function test_CheckOrderInfo_OutAddressNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the output address to a non-whitelisted address
        orderInfo.order.outAddressList[0] = vm.toString(nonOwner);

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 8); // Output address not whitelisted
    }

    // Test error case: chain mismatch
    function test_CheckOrderInfo_ChainMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the chain
        orderInfo.order.chain = "ETH";

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 9); // Chain mismatch
    }

    // Test error case: input token not whitelisted
    function test_CheckOrderInfo_InTokenNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the input token to a non-whitelisted token
        orderInfo.order.inTokenset[0].symbol = "USDT";
        orderInfo.order.inTokenset[0].addr = vm.toString(vm.addr(0x9));

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 10); // Input token not whitelisted
    }

    // Test error case: output token not whitelisted
    function test_CheckOrderInfo_OutTokenNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the output token to a non-whitelisted token
        orderInfo.order.outTokenset[0].symbol = "USDT";
        orderInfo.order.outTokenset[0].addr = vm.toString(vm.addr(0x9));

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 11); // Output token not whitelisted
    }

    // Test error case: order hash does not exist
    function test_ValidateOrderInfo_OrderHashNotExists() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Attempt to validate a non-existent order
        vm.startPrank(taker);
        vm.expectRevert("order hash not exists");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: order hash is invalid
    function test_ValidateOrderInfo_InvalidOrderHash() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add the order first
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // Modify the order but keep the hash unchanged
        orderInfo.order.nonce = 2;

        // Attempt to validate the modified order
        vm.expectRevert("order hash invalid");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test getOrderHashs function
    function test_GetOrderHashs() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add the order
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Get the order hash list
        bytes32[] memory orderHashs = swap.getOrderHashs();
        assertEq(orderHashs.length, 1);
        assertEq(orderHashs[0], orderInfo.orderHash);
    }

    // Test getOrderHashLength function
    function test_GetOrderHashLength() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add the order
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Get the order hash length
        uint256 length = swap.getOrderHashLength();
        assertEq(length, 1);
    }

    // Test getOrderHash function
    function test_GetOrderHash() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add the order
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Get the order hash
        bytes32 orderHash = swap.getOrderHash(0);
        assertEq(orderHash, orderInfo.orderHash);
    }

    // Test getOrderHash function out-of-range error
    function test_GetOrderHash_OutOfRange() public {
        // Attempt to get a non-existent order hash
        vm.expectRevert("out of range");
        swap.getOrderHash(0);
    }

    // Test checkTokenset function error case: token chain mismatch
    function test_AddSwapRequest_ChainMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the token chain
        orderInfo.order.inTokenset[0].chain = "ETH";

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Attempt to add the order
        vm.startPrank(taker);
        vm.expectRevert("order not valid");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // Test checkTokenset function error case: token address is zero
    function test_AddSwapRequest_ZeroTokenAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the token address to zero
        orderInfo.order.inTokenset[0].addr = "0x0000000000000000000000000000000000000000";

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Attempt to add the order
        vm.startPrank(taker);
        vm.expectRevert("order not valid");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // Test checkTokenset function error case: receive address is zero
    function test_AddSwapRequest_ZeroReceiveAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Modify the receive address to zero
        orderInfo.order.inAddressList[0] = "0x0000000000000000000000000000000000000000";

        // Recalculate the order hash and sign
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Attempt to add the order
        vm.startPrank(taker);
        vm.expectRevert("zero receive address");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // Test error case: cancel request when status is not PENDING
    function test_CancelSwapRequest_NotPending() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 3601);

        // Taker attempts to cancel a confirmed request
        vm.startPrank(taker);
        vm.expectRevert("swap request status is not pending");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: cancel request when not timed out
    function test_CancelSwapRequest_NotTimeout() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // Attempt to cancel immediately
        vm.expectRevert("swap request not timeout");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: force cancel request when status is not correct
    function test_ForceCancelSwapRequest_InvalidStatus() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker rejects the request
        vm.startPrank(maker);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 7 hours);

        // Admin attempts to force cancel a rejected request
        vm.startPrank(owner);
        vm.expectRevert("swap request status is not pending or maker confirmed (not out by contract)");
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: force cancel request when not expired
    function test_ForceCancelSwapRequest_NotExpired() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Admin attempts to force cancel immediately
        vm.startPrank(owner);
        vm.expectRevert("swap request not expired");
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: rollback request when status is not MAKER_CONFIRMED
    function test_RollbackSwapRequest_NotMakerConfirmed() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // Attempt to rollback an unconfirmed request
        vm.expectRevert("swap request status is not maker_confirmed");
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: rollback request for contract transfer
    function test_RollbackSwapRequest_OutByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request with outByContract set to true
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // Mint tokens to maker and approve
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Taker attempts to rollback a request with contract transfer
        vm.startPrank(taker);
        vm.expectRevert("out by contract cannot rollback");
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // Test error case: confirm request when status is not MAKER_CONFIRMED
    function test_ConfirmSwapRequest_NotMakerConfirmed() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // Attempt to confirm an unconfirmed request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash_123";
        vm.expectRevert("status error");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // Test error case: confirm request with wrong inTxHashs length
    function test_ConfirmSwapRequest_WrongInTxHashsLength() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Taker attempts to confirm the request with mismatched inTxHashs length
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](2);
        inTxHashs[0] = "tx_hash_456";
        inTxHashs[1] = "tx_hash_789";
        vm.expectRevert("wrong inTxHashs length");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // Test error case: confirm request with insufficient balance
    function test_ConfirmSwapRequest_InsufficientBalance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Taker attempts to confirm the request but has insufficient balance
        vm.startPrank(taker);
        WBTC.approve(address(swap), 100 * 10 ** 8);
        bytes[] memory inTxHashs = new bytes[](0);
        vm.expectRevert("not enough balance");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // Test error case: confirm request with insufficient allowance
    function test_ConfirmSwapRequest_InsufficientAllowance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Add swap request
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // Maker confirms the request
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Mint tokens to taker but do not approve
        vm.startPrank(address(WBTC));
        WBTC.mint(taker, 100 * 10 ** 8);
        vm.stopPrank();

        // Taker attempts to confirm the request but has insufficient allowance
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](0);
        vm.expectRevert("not enough allowance");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // Test getWhiteListToken function out-of-range error
    function test_GetWhiteListToken_OutOfRange() public {
        // Attempt to get a non-existent whitelist token
        vm.expectRevert();
        swap.getWhiteListToken(100);
    }
}