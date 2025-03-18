// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/AssetController.sol";
import "../src/Swap.sol";
import "../src/AssetFactory.sol";
import "../src/AssetIssuer.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, console} from "forge-std/Test.sol";

error OwnableUnauthorizedAccount(address account);
error InvalidInitialization();

contract AssetControllerTest is Test {
    MockToken WBTC;
    MockToken WETH;

    address owner = vm.addr(0x1);
    address vault = vm.parseAddress("0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63");
    address nonOwner = vm.addr(0x2);
    address maker = vm.addr(0x3);
    address taker = vm.addr(0x4);

    AssetController controller;
    AssetFactory factory;
    AssetIssuer issuer;
    AssetToken tokenImpl;
    Swap swap;
    string chain = "SETH";
    bytes32 constant TAKER_ROLE = keccak256("TAKER_ROLE");
    bytes32 constant MAKER_ROLE = keccak256("MAKER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        // Deploy tokens
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // Deploy AssetToken implementation contract
        tokenImpl = new AssetToken();

        // Deploy AssetFactory contract
        address factoryAddress = address(
            new ERC1967Proxy(
                address(new AssetFactory()),
                abi.encodeCall(AssetFactory.initialize, (owner, vault, chain, address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);
        issuer = AssetIssuer(
            address(
                new ERC1967Proxy(
                    address(new AssetIssuer()), abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // Deploy Swap contract
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // Set roles
        swap.grantRole(swap.MAKER_ROLE(), maker);
        swap.grantRole(swap.TAKER_ROLE(), taker);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));

        // Set whitelist addresses
        string[] memory outWhiteAddresses = new string[](2);

        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);

        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);

        // Add tokens to whitelist
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

        // Deploy AssetController contract
        controller = AssetController(
            address(
                new ERC1967Proxy(
                    address(new AssetController()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

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
            amount: 1 * 10 ** WBTC.decimals() // 1 BTC
        });

        // Create output token set
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 20 * 10 ** WETH.decimals() // 20 ETH
        });
        deal(address(WETH), taker, 10000 * 10 ** WETH.decimals());
        deal(address(WBTC), taker, 10000 * 10 ** WETH.decimals());

        // Create order
        vm.startPrank(maker);
        Order memory order = Order({
            chain: chain,
            maker: maker,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 * 10 ** WETH.decimals(), // 1 BTC
            outAmount: 10 * 10 ** WETH.decimals(), // Proportionally
            deadline: block.timestamp + 3600, // Expires in 1 hour
            requester: taker
        });

        order.inAddressList[0] = vm.toString(maker);
        order.outAddressList[0] = vm.toString(vault);

        // Calculate order hash
        bytes32 orderHash = keccak256(abi.encode(order));

        // Sign

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // Create order information
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // Test initialization
    function test_Initialize() public {
        assertEq(controller.factoryAddress(), address(factory));
        assertEq(controller.owner(), owner);
        assertFalse(controller.paused());
    }

    // Test pause and unpause
    function test_PauseAndUnpause() public {
        vm.startPrank(owner);

        // Pause
        controller.pause();
        assertTrue(controller.paused());

        // Unpause
        controller.unpause();
        assertFalse(controller.paused());

        vm.stopPrank();
    }

    // Test non-owner pause
    function test_Pause_NotOwner() public {
        vm.startPrank(nonOwner);

        // Non-owner attempts to pause
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.pause();

        vm.stopPrank();
    }

    // Test non-owner unpause
    function test_Unpause_NotOwner() public {
        vm.startPrank(owner);
        controller.pause();
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // Non-owner attempts to unpause
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.unpause();

        vm.stopPrank();
    }

    function test_FactoryAddress() public {
        assertEq(controller.factoryAddress(), address(factory));
    }

    function test_Constructor() public {
        // Deploy a new implementation contract
        AssetController newController = new AssetController();

        // Attempt to call initialize directly, which should fail
        vm.expectRevert(abi.encodeWithSelector(InvalidInitialization.selector));
        newController.initialize(owner, address(factory));
    }

    function test_Owner() public {
        assertEq(controller.owner(), owner);

        // Test ownership transfer
        vm.startPrank(owner);
        controller.transferOwnership(nonOwner);
        vm.stopPrank();

        assertEq(controller.owner(), nonOwner);

        // Restore ownership
        vm.startPrank(nonOwner);
        controller.transferOwnership(owner);
        vm.stopPrank();
    }

    // Test rollback swap request
    function test_RollbackSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();
        address assetTokenAddress = createAssetToken();
        apAddMintRequest(assetTokenAddress, orderInfo);

        // Maker confirms
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // Rollback via controller
        vm.startPrank(owner);
        issuer.rollbackSwapRequest(address(swap), orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
    }

    // Test rollback swap request - zero address
    function test_RollbackSwapRequest_ZeroAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(owner);

        // Attempt to rollback with zero address
        vm.expectRevert("zero swap address");
        controller.rollbackSwapRequest(address(0), orderInfo);

        vm.stopPrank();
    }

    // Test rollback swap request - not owner
    function test_RollbackSwapRequest_NotOwner() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(nonOwner);

        // Non-owner attempts to rollback
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.rollbackSwapRequest(address(swap), orderInfo);

        vm.stopPrank();
    }

    function createAssetToken() public returns (address) {
        vm.startPrank(owner);
        address assetTokenAddress =
            factory.createAssetToken(getAsset(), 10000, address(issuer), address(0x7), address(0x8), address(swap));
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        issuer.setIssueFee(assetToken.id(), 10000);
        issuer.setIssueAmountRange(
            assetToken.id(), Range({min: 10 * 10 ** WETH.decimals(), max: 10000 * 10 ** WETH.decimals()})
        );
        issuer.addParticipant(assetToken.id(), taker);
        vm.stopPrank();
        return assetTokenAddress;
    }

    function getAsset() public view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 20 * 10 ** WETH.decimals()
        });
        Asset memory asset = Asset({id: 1, name: "BTC", symbol: "BTC", tokenset: tokenset_});
        return asset;
    }

    function apAddMintRequest(address assetTokenAddress, OrderInfo memory orderInfo)
        public
        returns (uint256, uint256)
    {
        vm.startPrank(taker);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        WETH.mint(taker, 10000 * 10 ** WETH.decimals());
        WETH.approve(address(issuer), 1000000 * 10 ** WETH.decimals());
        WBTC.approve(address(issuer), 1000000 * 10 ** WETH.decimals());
        uint256 amountBeforeMint = WETH.balanceOf(taker);
        uint256 nonce = issuer.addMintRequest(assetToken.id(), orderInfo, 10000);
        vm.stopPrank();
        return (nonce, amountBeforeMint);
    }

    // Test cancel swap request
    function test_CancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        address assetTokenAddress = createAssetToken();
        IERC20 inToken = IERC20(vm.parseAddress(orderInfo.order.inTokenset[0].addr));
        (uint256 nonce, uint256 amountBeforeMint) = apAddMintRequest(assetTokenAddress, orderInfo);

        // Cancel via controller
        vm.startPrank(owner);
        vm.warp(block.timestamp + 3601); // Exceed MAX_MARKER_CONFIRM_DELAY
        issuer.cancelSwapRequest(address(swap), orderInfo);
        vm.stopPrank();

        // Verify status
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CANCEL));
    }

    // Test cancel swap request - zero address
    function test_CancelSwapRequest_ZeroAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(owner);

        // Attempt to cancel with zero address
        vm.expectRevert("zero swap address");
        controller.cancelSwapRequest(address(0), orderInfo);

        vm.stopPrank();
    }

    // Test cancel swap request - not owner
    function test_CancelSwapRequest_NotOwner() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(nonOwner);

        // Non-owner attempts to cancel
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.cancelSwapRequest(address(swap), orderInfo);

        vm.stopPrank();
    }

    // Test contract upgrade
    function test_Upgrade() public {
        vm.startPrank(owner);

        // Deploy new implementation contract
        AssetController newImplementation = new AssetController();

        // Upgrade
        UUPSUpgradeable(address(controller)).upgradeToAndCall(address(newImplementation), "");

        vm.stopPrank();

        // Verify that the upgraded contract still works properly
        assertEq(controller.factoryAddress(), address(factory));
        assertEq(controller.owner(), owner);
    }

    // Test contract upgrade - not owner
    function test_Upgrade_NotOwner() public {
        vm.startPrank(nonOwner);

        // Deploy new implementation contract
        AssetController newImplementation = new AssetController();

        // Non-owner attempts to upgrade
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        UUPSUpgradeable(address(controller)).upgradeToAndCall(address(newImplementation), "");

        vm.stopPrank();
    }

    // Test internal function checkRequestOrderInfo
    function test_CheckRequestOrderInfo() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // Create request
        Request memory request = Request({
            nonce: 1,
            requester: taker,
            assetTokenAddress: address(0),
            amount: 1,
            swapAddress: address(swap),
            orderHash: orderInfo.orderHash,
            status: RequestStatus.PENDING,
            requestTimestamp: block.timestamp,
            issueFee: 0
        });

        // Call internal function
        // Note: Since checkRequestOrderInfo is an internal function, we need to test it via a public function
        // Here we use a mock contract for testing
        AssetControllerMock mock = new AssetControllerMock();

        // Test normal case
        mock.checkRequestOrderInfoPublic(request, orderInfo);

        // Test orderHash mismatch
        bytes32 wrongOrderHash = bytes32(uint256(orderInfo.orderHash) + 1);
        Request memory wrongRequest = request;
        wrongRequest.orderHash = wrongOrderHash;

        vm.expectRevert("order hash not match");
        mock.checkRequestOrderInfoPublic(wrongRequest, orderInfo);

        // Test orderHash calculation error
        OrderInfo memory wrongOrderInfo = orderInfo;
        wrongOrderInfo.order.nonce = 2; // Modify the order to make the hash mismatch

        vm.expectRevert("order hash not match");
        mock.checkRequestOrderInfoPublic(request, wrongOrderInfo);
    }
}

// Mock contract for testing internal functions
contract AssetControllerMock {
    function checkRequestOrderInfoPublic(Request memory request, OrderInfo memory orderInfo) public pure {
        require(request.orderHash == orderInfo.orderHash, "order hash not match");
        require(orderInfo.orderHash == keccak256(abi.encode(orderInfo.order)), "order hash invalid");
    }
}
