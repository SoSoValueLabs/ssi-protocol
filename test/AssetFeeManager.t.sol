// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/AssetFactory.sol";
import "../src/AssetToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Test, console} from "forge-std/Test.sol";

contract AssetFeeManagerTest is Test {
    MockToken WBTC;
    MockToken WETH;

    address owner = vm.addr(0x1);
    address vault = vm.parseAddress("0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63");
    address pmm = vm.addr(0x3);
    address ap = vm.addr(0x4);
    address nonOwner = vm.addr(0x5);

    Swap swap;
    AssetIssuer issuer;
    AssetRebalancer rebalancer;
    AssetFeeManager feeManager;
    AssetFactory factory;
    AssetToken tokenImpl;
    AssetFactory factoryImpl;

    error OwnableUnauthorizedAccount(address account);

    function setUp() public {
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // Deploy Swap contract
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, "SETH")))));

        // Deploy AssetToken and AssetFactory implementation contracts
        tokenImpl = new AssetToken();
        factoryImpl = new AssetFactory();

        // Deploy AssetFactory proxy contract
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(AssetFactory.initialize, (owner, vault, "SETH", address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);

        // Deploy AssetIssuer proxy contract
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

        // Set Swap roles and whitelist
        swap.grantRole(swap.MAKER_ROLE(), pmm);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));
        swap.grantRole(swap.TAKER_ROLE(), address(rebalancer));
        swap.grantRole(swap.TAKER_ROLE(), address(feeManager));

        string[] memory outWhiteAddresses = new string[](2);
        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);
        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);

        // Add tokens to whitelist
        Token[] memory whiteListTokens = new Token[](2);
        whiteListTokens[0] = Token({
            chain: "SETH",
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 0
        });
        whiteListTokens[1] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 0
        });
        swap.addWhiteListTokens(whiteListTokens);

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
        Asset memory asset = Asset({id: 1, name: "BTC", symbol: "BTC", tokenset: tokenset_});
        return asset;
    }

    function createAssetToken() public returns (address) {
        vm.startPrank(owner);
        address assetTokenAddress = factory.createAssetToken(
            getAsset(),
            10000, // maxFee
            address(issuer),
            address(rebalancer),
            address(feeManager),
            address(swap)
        );

        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        issuer.setIssueFee(assetToken.id(), 10000);
        issuer.setIssueAmountRange(assetToken.id(), Range({min: 10 * 10 ** 8, max: 10000 * 10 ** 8}));
        issuer.addParticipant(assetToken.id(), ap);

        // Mint some tokens for testing
        vm.startPrank(address(issuer));
        assetToken.mint(ap, 1000 * 10 ** 8);
        vm.stopPrank();

        vm.startPrank(owner);
        return assetTokenAddress;
    }

    function pmmConfirmSwapRequest(OrderInfo memory orderInfo, bool byContract) public {
        vm.startPrank(pmm);
        uint256 transferAmount = orderInfo.order.outTokenset[0].amount * orderInfo.order.outAmount / 10 ** 8;
        MockToken token = MockToken(vm.parseAddress(orderInfo.order.outTokenset[0].addr));
        token.mint(pmm, transferAmount);

        if (!byContract) {
            token.transfer(vm.parseAddress(orderInfo.order.outAddressList[0]), transferAmount);
            bytes[] memory outTxHashs = new bytes[](1);
            outTxHashs[0] = "outTxHashs";
            swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        } else {
            token.approve(address(swap), transferAmount);
            bytes[] memory outTxHashs = new bytes[](1);
            outTxHashs[0] = "outTxHashs";
            swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        }
        vm.stopPrank();
    }

    function mintAndCollectFee() public returns (address) {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);

        // Advance time to collect fees
        vm.warp(block.timestamp + 2 days);
        feeManager.collectFeeTokenset(assetToken.id());

        vm.stopPrank();
        return assetTokenAddress;
    }

    function createOrderInfo(address assetTokenAddress) public returns (OrderInfo memory) {
        AssetToken assetToken = AssetToken(assetTokenAddress);
        Token[] memory inTokenset = assetToken.getFeeTokenset();

        vm.startPrank(pmm);
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** WETH.decimals()
        });

        Order memory order = Order({
            chain: "SETH",
            maker: pmm,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8,
            outAmount: 60000 * inTokenset[0].amount / 3000,
            deadline: block.timestamp + 60,
            requester: ap
        });

        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(vault);

        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        vm.stopPrank();
        return orderInfo;
    }

    // Test setting fees
    function test_SetFee() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();
        uint256 newFee = 5000;

        vm.startPrank(owner);

        // Ensure fees have been collected
        vm.warp(block.timestamp + 1 days);
        feeManager.collectFeeTokenset(assetID);

        // Set new fee
        feeManager.setFee(assetID, newFee);

        // Verify fee has been updated
        assertEq(assetToken.fee(), newFee);

        vm.stopPrank();
    }

    // Test collecting fees
    function test_CollectFeeTokenset() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        vm.startPrank(owner);

        // Initially, there should be no fees
        assertEq(assetToken.getFeeTokenset().length, 0);

        // Advance time to collect fees
        vm.warp(block.timestamp + 2 days);
        feeManager.collectFeeTokenset(assetID);

        // Verify fees have been collected
        assertEq(assetToken.getFeeTokenset().length, 1);
        assertTrue(assetToken.getFeeTokenset()[0].amount > 0);

        vm.stopPrank();
    }

    // Test adding a burn fee request
    function test_AddBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);

        // Add burn fee request
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Verify request has been added
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(request.nonce, nonce);
        assertEq(request.requester, owner);
        assertEq(request.assetTokenAddress, assetTokenAddress);
        assertEq(request.swapAddress, address(swap));
        assertEq(request.orderHash, orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(RequestStatus.PENDING));

        // Verify asset token has locked burn fee
        assertTrue(assetToken.burningFee());

        vm.stopPrank();
    }

    // Test rejecting a burn fee request
    function test_RejectBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM rejects swap request
        vm.stopPrank();
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        vm.startPrank(owner);

        // Reject burn fee request
        feeManager.rejectBurnFeeRequest(nonce);

        // Verify request has been rejected
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));

        // Verify asset token has unlocked burn fee
        assertFalse(assetToken.burningFee());

        vm.stopPrank();
    }

    // Test confirming a burn fee request
    function test_ConfirmBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Record fee tokenset before burning
        Token[] memory feeTokensetBefore = assetToken.getFeeTokenset();
        assertTrue(feeTokensetBefore.length > 0);

        vm.stopPrank();

        // PMM confirms swap request
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // Confirm burn fee request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        // Verify request has been confirmed
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // Verify fee tokens have been burned
        Token[] memory feeTokensetAfter = assetToken.getFeeTokenset();
        if (feeTokensetAfter.length > 0) {
            assertLt(feeTokensetAfter[0].amount, feeTokensetBefore[0].amount);
        } else {
            assertEq(feeTokensetAfter.length, 0);
        }

        // Verify asset token has unlocked burn fee
        assertFalse(assetToken.burningFee());

        vm.stopPrank();
    }

    // Test getting burn fee request length
    function test_GetBurnFeeRequestLength() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Initially, length should be 0
        assertEq(feeManager.getBurnFeeRequestLength(), 0);

        // Add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Verify length has increased
        assertEq(feeManager.getBurnFeeRequestLength(), 1);

        vm.stopPrank();
    }

    // Test getting burn fee request
    function test_GetBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Get and verify request
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(request.nonce, nonce);
        assertEq(request.requester, owner);
        assertEq(request.assetTokenAddress, assetTokenAddress);

        vm.stopPrank();
    }

    // Test error case: non-owner calls
    function test_OnlyOwnerFunctions() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);

        vm.startPrank(nonOwner);

        // Attempt to set fee
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.setFee(assetID, 5000);

        // Attempt to collect fees
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.collectFeeTokenset(assetID);

        // Attempt to add burn fee request
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Add a request for subsequent tests
        vm.stopPrank();
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // Attempt to reject burn fee request
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.rejectBurnFeeRequest(nonce);

        // Attempt to confirm burn fee request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // Test error case: setting fee when asset token has not collected fees
    function test_SetFee_NotCollected() public {
        address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // Ensure lastCollectTimestamp has expired (over 1 day)
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(owner);

        // Attempt to set fee, but fees have not been collected
        vm.expectRevert("has fee not collected");
        feeManager.setFee(assetID, 5000);

        vm.stopPrank();
    }

    // Test error case: non-fee manager calls
    function test_NotFeeManager() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create a new fee manager without granting the role
        AssetFeeManager newFeeManager = AssetFeeManager(
            address(
                new ERC1967Proxy(
                    address(new AssetFeeManager()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        vm.startPrank(owner);

        // Ensure fees have been collected
        vm.warp(block.timestamp + 1 days);
        feeManager.collectFeeTokenset(assetID);

        // Attempt to set fee using the new fee manager
        vm.expectRevert("not a fee manager");
        newFeeManager.setFee(assetID, 5000);

        // Attempt to collect fees using the new fee manager
        vm.expectRevert("not a fee manager");
        newFeeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // Test error case: collecting fees during rebalancing
    function test_CollectFeeTokenset_Rebalancing() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Simulate rebalancing state
        vm.startPrank(address(rebalancer));
        assetToken.lockRebalance();
        vm.stopPrank();

        vm.startPrank(owner);

        // Attempt to collect fees during rebalancing
        vm.expectRevert("is rebalancing");
        feeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // Test error case: collecting fees during issuance
    function test_CollectFeeTokenset_Issuing() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Simulate issuance state
        vm.startPrank(address(issuer));
        assetToken.lockIssue();
        vm.stopPrank();

        vm.startPrank(owner);

        // Attempt to collect fees during issuance
        vm.expectRevert("is issuing");
        feeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // Test error case: adding a burn fee request while already burning fees
    function test_AddBurnFeeRequest_AlreadyBurning() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Add the first request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Attempt to add a second request
        vm.expectRevert("is burning fee");
        feeManager.addBurnFeeRequest(assetID, orderInfo);

        vm.stopPrank();
    }

    // Test error case: rejecting a non-existent request
    function test_RejectBurnFeeRequest_NonExistent() public {
        vm.startPrank(owner);

        // Attempt to reject a non-existent request
        vm.expectRevert("nonce too large");
        feeManager.rejectBurnFeeRequest(0);

        vm.stopPrank();
    }

    // Test error case: confirming a non-existent request
    function test_ConfirmBurnFeeRequest_NonExistent() public {
        // Create order info
        address assetTokenAddress = mintAndCollectFee();
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";

        // Attempt to confirm a non-existent request
        vm.startPrank(owner);

        vm.expectRevert("nonce too large");
        feeManager.confirmBurnFeeRequest(0, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    function test_AddBurnFeeRequest_OrderNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // Modify order hash to make it invalid
        orderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        // Attempt to add burn fee request
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // Test adding a burn fee request - not enough fee tokens
    function test_AddBurnFeeRequest_NotEnoughFee() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // Modify input token amount to exceed available fees
        orderInfo.order.inAmount = 1000000 * 10 ** 8; // Set a very large value

        // Recalculate order hash
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // Attempt to add burn fee request
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // Test adding a burn fee request - receiver does not match
    function test_AddBurnFeeRequest_ReceiverNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // Modify receiver address
        orderInfo.order.outAddressList[0] = vm.toString(nonOwner);

        // Recalculate order hash
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // Attempt to add burn fee request
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // Test adding a burn fee request - chain does not match
    function test_AddBurnFeeRequest_ChainNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // Modify chain
        orderInfo.order.outTokenset[0].chain = "ETH";

        // Recalculate order hash
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // Attempt to add burn fee request
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // Test rejecting a burn fee request - request status is not PENDING
    function test_RejectBurnFeeRequest_NotPending() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM rejects swap request
        vm.stopPrank();
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        vm.startPrank(owner);

        // Reject burn fee request
        feeManager.rejectBurnFeeRequest(nonce);

        // Attempt to reject again
        vm.expectRevert();
        feeManager.rejectBurnFeeRequest(nonce);

        vm.stopPrank();
    }

    // Test rejecting a burn fee request - swap request status is not valid
    function test_RejectBurnFeeRequest_SwapStatusNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM confirms swap request (instead of rejecting)
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // Attempt to reject burn fee request
        vm.expectRevert();
        feeManager.rejectBurnFeeRequest(nonce);

        vm.stopPrank();
    }

    // Test confirming a burn fee request - request status is not PENDING
    function test_ConfirmBurnFeeRequest_NotPending() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM confirms swap request
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // Confirm burn fee request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        // Attempt to confirm again
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // Test confirming a burn fee request - swap request status is not MAKER_CONFIRMED
    function test_ConfirmBurnFeeRequest_SwapStatusNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // Do not let PMM confirm swap request

        // Attempt to confirm burn fee request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // Test confirming a burn fee request - order hash does not match
    function test_ConfirmBurnFeeRequest_OrderHashNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // Create order info and add request
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM confirms swap request
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // Modify order info
        OrderInfo memory wrongOrderInfo = orderInfo;
        wrongOrderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        // Attempt to confirm burn fee request
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, wrongOrderInfo, inTxHashs);

        vm.stopPrank();
    }
}
