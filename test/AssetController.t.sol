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
        // 部署代币
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // 部署AssetToken实现合约
        tokenImpl = new AssetToken();

        // 部署AssetFactory合约
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

        // 部署Swap合约
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // 设置角色
        swap.grantRole(swap.MAKER_ROLE(), maker);
        swap.grantRole(swap.TAKER_ROLE(), taker);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));

        // 设置白名单地址
        string[] memory outWhiteAddresses = new string[](2);

        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);

        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);

        // 添加代币白名单
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

        // 部署AssetController合约
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

    // 创建订单信息
    function createOrderInfo() public returns (OrderInfo memory) {
        // 创建输入代币集合
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 1 * 10 ** WBTC.decimals() // 1 BTC
        });

        // 创建输出代币集合
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

        // 创建订单
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
            outAmount: 10 * 10 ** WETH.decimals(), // 按比例
            deadline: block.timestamp + 3600, // 1小时后过期
            requester: taker
        });

        order.inAddressList[0] = vm.toString(maker);
        order.outAddressList[0] = vm.toString(vault);

        // 计算订单哈希
        bytes32 orderHash = keccak256(abi.encode(order));

        // 签名

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 创建订单信息
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // 测试初始化
    function test_Initialize() public {
        assertEq(controller.factoryAddress(), address(factory));
        assertEq(controller.owner(), owner);
        assertFalse(controller.paused());
    }

    // 测试暂停和恢复
    function test_PauseAndUnpause() public {
        vm.startPrank(owner);

        // 暂停
        controller.pause();
        assertTrue(controller.paused());

        // 恢复
        controller.unpause();
        assertFalse(controller.paused());

        vm.stopPrank();
    }

    // 测试非所有者暂停
    function test_Pause_NotOwner() public {
        vm.startPrank(nonOwner);

        // 非所有者尝试暂停
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.pause();

        vm.stopPrank();
    }

    // 测试非所有者恢复
    function test_Unpause_NotOwner() public {
        vm.startPrank(owner);
        controller.pause();
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // 非所有者尝试恢复
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.unpause();

        vm.stopPrank();
    }

    function test_FactoryAddress() public {
        assertEq(controller.factoryAddress(), address(factory));
    }

    function test_Constructor() public {
        // 部署一个新的实现合约
        AssetController newController = new AssetController();

        // 尝试直接调用initialize，应该会失败
        vm.expectRevert(abi.encodeWithSelector(InvalidInitialization.selector));
        newController.initialize(owner, address(factory));
    }

    function test_Owner() public {
        assertEq(controller.owner(), owner);

        // 测试转移所有权
        vm.startPrank(owner);
        controller.transferOwnership(nonOwner);
        vm.stopPrank();

        assertEq(controller.owner(), nonOwner);

        // 恢复所有权
        vm.startPrank(nonOwner);
        controller.transferOwnership(owner);
        vm.stopPrank();
    }

    // 测试回滚交换请求
    function test_RollbackSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();
        address assetTokenAddress = createAssetToken();
        apAddMintRequest(assetTokenAddress, orderInfo);

        // maker确认
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 通过controller回滚
        vm.startPrank(owner);
        issuer.rollbackSwapRequest(address(swap), orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
    }

    // 测试回滚交换请求 - 零地址
    function test_RollbackSwapRequest_ZeroAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(owner);

        // 尝试用零地址回滚
        vm.expectRevert("zero swap address");
        controller.rollbackSwapRequest(address(0), orderInfo);

        vm.stopPrank();
    }

    // 测试回滚交换请求 - 非所有者
    function test_RollbackSwapRequest_NotOwner() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(nonOwner);

        // 非所有者尝试回滚
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

    // 测试取消交换请求
    function test_CancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        address assetTokenAddress = createAssetToken();
        IERC20 inToken = IERC20(vm.parseAddress(orderInfo.order.inTokenset[0].addr));
        (uint256 nonce, uint256 amountBeforeMint) = apAddMintRequest(assetTokenAddress, orderInfo);

        // 通过controller取消
        vm.startPrank(owner);
        vm.warp(block.timestamp + 3601); // 超过MAX_MARKER_CONFIRM_DELAY
        issuer.cancelSwapRequest(address(swap), orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CANCEL));
    }

    // 测试取消交换请求 - 零地址
    function test_CancelSwapRequest_ZeroAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(owner);

        // 尝试用零地址取消
        vm.expectRevert("zero swap address");
        controller.cancelSwapRequest(address(0), orderInfo);

        vm.stopPrank();
    }

    // 测试取消交换请求 - 非所有者
    function test_CancelSwapRequest_NotOwner() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(nonOwner);

        // 非所有者尝试取消
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        controller.cancelSwapRequest(address(swap), orderInfo);

        vm.stopPrank();
    }

    // 测试升级合约
    function test_Upgrade() public {
        vm.startPrank(owner);

        // 部署新的实现合约
        AssetController newImplementation = new AssetController();

        // 升级
        UUPSUpgradeable(address(controller)).upgradeToAndCall(address(newImplementation), "");

        vm.stopPrank();

        // 验证升级后的合约仍然可以正常工作
        assertEq(controller.factoryAddress(), address(factory));
        assertEq(controller.owner(), owner);
    }

    // 测试升级合约 - 非所有者
    function test_Upgrade_NotOwner() public {
        vm.startPrank(nonOwner);

        // 部署新的实现合约
        AssetController newImplementation = new AssetController();

        // 非所有者尝试升级
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        UUPSUpgradeable(address(controller)).upgradeToAndCall(address(newImplementation), "");

        vm.stopPrank();
    }

    // 测试内部函数checkRequestOrderInfo
    function test_CheckRequestOrderInfo() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 创建请求
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

        // 调用内部函数
        // 注意：由于checkRequestOrderInfo是internal函数，我们需要通过一个公共函数来测试它
        // 这里我们使用一个模拟合约来测试
        AssetControllerMock mock = new AssetControllerMock();

        // 测试正常情况
        mock.checkRequestOrderInfoPublic(request, orderInfo);

        // 测试orderHash不匹配
        bytes32 wrongOrderHash = bytes32(uint256(orderInfo.orderHash) + 1);
        Request memory wrongRequest = request;
        wrongRequest.orderHash = wrongOrderHash;

        vm.expectRevert("order hash not match");
        mock.checkRequestOrderInfoPublic(wrongRequest, orderInfo);

        // 测试orderHash计算错误
        OrderInfo memory wrongOrderInfo = orderInfo;
        wrongOrderInfo.order.nonce = 2; // 修改订单，使哈希不匹配

        vm.expectRevert("order hash not match");
        mock.checkRequestOrderInfoPublic(request, wrongOrderInfo);
    }
}

// 用于测试internal函数的模拟合约
contract AssetControllerMock {
    function checkRequestOrderInfoPublic(Request memory request, OrderInfo memory orderInfo) public pure {
        require(request.orderHash == orderInfo.orderHash, "order hash not match");
        require(orderInfo.orderHash == keccak256(abi.encode(orderInfo.order)), "order hash invalid");
    }
}
