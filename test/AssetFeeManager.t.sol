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

        // 部署Swap合约
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, "SETH")))));

        // 部署AssetToken和AssetFactory实现合约
        tokenImpl = new AssetToken();
        factoryImpl = new AssetFactory();

        // 部署AssetFactory代理合约
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(AssetFactory.initialize, (owner, vault, "SETH", address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);

        // 部署AssetIssuer代理合约
        issuer = AssetIssuer(
            address(
                new ERC1967Proxy(
                    address(new AssetIssuer()), abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // 部署AssetRebalancer代理合约
        rebalancer = AssetRebalancer(
            address(
                new ERC1967Proxy(
                    address(new AssetRebalancer()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // 部署AssetFeeManager代理合约
        feeManager = AssetFeeManager(
            address(
                new ERC1967Proxy(
                    address(new AssetFeeManager()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // 设置Swap角色和白名单
        swap.grantRole(swap.MAKER_ROLE(), pmm);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));
        swap.grantRole(swap.TAKER_ROLE(), address(rebalancer));
        swap.grantRole(swap.TAKER_ROLE(), address(feeManager));

        string[] memory outWhiteAddresses = new string[](2);
        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);
        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);

        // 添加代币白名单
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

        // 铸造一些代币用于测试
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

        // 前进时间以便收集费用
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

    // 测试设置费用
    function test_SetFee() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();
        uint256 newFee = 5000; // 0.5%

        vm.startPrank(owner);

        // 确保费用已收集
        vm.warp(block.timestamp + 1 days);
        feeManager.collectFeeTokenset(assetID);

        // 设置新的费用
        feeManager.setFee(assetID, newFee);

        // 验证费用已更新
        assertEq(assetToken.fee(), newFee);

        vm.stopPrank();
    }

    // 测试收集费用
    function test_CollectFeeTokenset() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        vm.startPrank(owner);

        // 初始状态下应该没有费用
        assertEq(assetToken.getFeeTokenset().length, 0);

        // 前进时间以便收集费用
        vm.warp(block.timestamp + 2 days);
        feeManager.collectFeeTokenset(assetID);

        // 验证费用已收集
        assertEq(assetToken.getFeeTokenset().length, 1);
        assertTrue(assetToken.getFeeTokenset()[0].amount > 0);

        vm.stopPrank();
    }

    // 测试添加燃烧费用请求
    function test_AddBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);

        // 添加燃烧费用请求
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 验证请求已添加
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(request.nonce, nonce);
        assertEq(request.requester, owner);
        assertEq(request.assetTokenAddress, assetTokenAddress);
        assertEq(request.swapAddress, address(swap));
        assertEq(request.orderHash, orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(RequestStatus.PENDING));

        // 验证资产代币已锁定燃烧费用
        assertTrue(assetToken.burningFee());

        vm.stopPrank();
    }

    // 测试拒绝燃烧费用请求
    function test_RejectBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM拒绝交换请求
        vm.stopPrank();
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        vm.startPrank(owner);

        // 拒绝燃烧费用请求
        feeManager.rejectBurnFeeRequest(nonce);

        // 验证请求已拒绝
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));

        // 验证资产代币已解锁燃烧费用
        assertFalse(assetToken.burningFee());

        vm.stopPrank();
    }

    // 测试确认燃烧费用请求
    function test_ConfirmBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 记录燃烧前的费用代币集
        Token[] memory feeTokensetBefore = assetToken.getFeeTokenset();
        assertTrue(feeTokensetBefore.length > 0);

        vm.stopPrank();

        // PMM确认交换请求
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // 确认燃烧费用请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        // 验证请求已确认
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // 验证费用代币已燃烧
        Token[] memory feeTokensetAfter = assetToken.getFeeTokenset();
        if (feeTokensetAfter.length > 0) {
            assertLt(feeTokensetAfter[0].amount, feeTokensetBefore[0].amount);
        } else {
            assertEq(feeTokensetAfter.length, 0);
        }

        // 验证资产代币已解锁燃烧费用
        assertFalse(assetToken.burningFee());

        vm.stopPrank();
    }

    // 测试获取燃烧费用请求长度
    function test_GetBurnFeeRequestLength() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 初始长度应为0
        assertEq(feeManager.getBurnFeeRequestLength(), 0);

        // 添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 验证长度增加
        assertEq(feeManager.getBurnFeeRequestLength(), 1);

        vm.stopPrank();
    }

    // 测试获取燃烧费用请求
    function test_GetBurnFeeRequest() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 获取并验证请求
        Request memory request = feeManager.getBurnFeeRequest(nonce);
        assertEq(request.nonce, nonce);
        assertEq(request.requester, owner);
        assertEq(request.assetTokenAddress, assetTokenAddress);

        vm.stopPrank();
    }

    // 测试错误情况：非所有者调用
    function test_OnlyOwnerFunctions() public {
        address assetTokenAddress = mintAndCollectFee();
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);

        vm.startPrank(nonOwner);

        // 尝试设置费用
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.setFee(assetID, 5000);

        // 尝试收集费用
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.collectFeeTokenset(assetID);

        // 尝试添加燃烧费用请求
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 添加一个请求用于后续测试
        vm.stopPrank();
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();

        vm.startPrank(nonOwner);

        // 尝试拒绝燃烧费用请求
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.rejectBurnFeeRequest(nonce);

        // 尝试确认燃烧费用请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // 测试错误情况：设置费用时资产代币没有收集费用
    function test_SetFee_NotCollected() public {
        address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 确保lastCollectTimestamp已经过期（超过1天）
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(owner);

        // 尝试设置费用，但费用尚未收集
        vm.expectRevert("has fee not collected");
        feeManager.setFee(assetID, 5000);

        vm.stopPrank();
    }
    // 测试错误情况：非费用管理者调用

    function test_NotFeeManager() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建一个新的费用管理者，但不授予角色
        AssetFeeManager newFeeManager = AssetFeeManager(
            address(
                new ERC1967Proxy(
                    address(new AssetFeeManager()),
                    abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        vm.startPrank(owner);

        // 确保费用已收集
        vm.warp(block.timestamp + 1 days);
        feeManager.collectFeeTokenset(assetID);

        // 尝试使用新的费用管理者设置费用
        vm.expectRevert("not a fee manager");
        newFeeManager.setFee(assetID, 5000);

        // 尝试使用新的费用管理者收集费用
        vm.expectRevert("not a fee manager");
        newFeeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // 测试错误情况：在重新平衡时收集费用
    function test_CollectFeeTokenset_Rebalancing() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 模拟重新平衡状态
        vm.startPrank(address(rebalancer));
        assetToken.lockRebalance();
        vm.stopPrank();

        vm.startPrank(owner);

        // 尝试在重新平衡时收集费用
        vm.expectRevert("is rebalancing");
        feeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // 测试错误情况：在发行时收集费用
    function test_CollectFeeTokenset_Issuing() public {
        address assetTokenAddress = createAssetToken();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 模拟发行状态
        vm.startPrank(address(issuer));
        assetToken.lockIssue();
        vm.stopPrank();

        vm.startPrank(owner);

        // 尝试在发行时收集费用
        vm.expectRevert("is issuing");
        feeManager.collectFeeTokenset(assetID);

        vm.stopPrank();
    }

    // 测试错误情况：添加燃烧费用请求时已经在燃烧费用
    function test_AddBurnFeeRequest_AlreadyBurning() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 添加第一个请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);

        feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 尝试添加第二个请求
        vm.expectRevert("is burning fee");
        feeManager.addBurnFeeRequest(assetID, orderInfo);

        vm.stopPrank();
    }

    // 测试错误情况：拒绝不存在的请求
    function test_RejectBurnFeeRequest_NonExistent() public {
        vm.startPrank(owner);

        // 尝试拒绝不存在的请求
        vm.expectRevert("nonce too large");
        feeManager.rejectBurnFeeRequest(0);

        vm.stopPrank();
    }

    // 测试错误情况：确认不存在的请求
    function test_ConfirmBurnFeeRequest_NonExistent() public {
        // 创建订单信息
        address assetTokenAddress = mintAndCollectFee();
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";

        // 尝试确认不存在的请求
        vm.startPrank(owner);

        vm.expectRevert("nonce too large");
        feeManager.confirmBurnFeeRequest(0, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    function test_AddBurnFeeRequest_OrderNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // 修改订单哈希使其无效
        orderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        // 尝试添加燃烧费用请求
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // 测试添加燃烧费用请求 - 费用代币不足
    function test_AddBurnFeeRequest_NotEnoughFee() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // 修改输入代币数量使其超过可用费用
        orderInfo.order.inAmount = 1000000 * 10 ** 8; // 设置一个非常大的值

        // 重新计算订单哈希
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // 尝试添加燃烧费用请求
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // 测试添加燃烧费用请求 - 接收者不匹配
    function test_AddBurnFeeRequest_ReceiverNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // 修改接收者地址
        orderInfo.order.outAddressList[0] = vm.toString(nonOwner);

        // 重新计算订单哈希
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // 尝试添加燃烧费用请求
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // 测试添加燃烧费用请求 - 链不匹配
    function test_AddBurnFeeRequest_ChainNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        // 修改链
        orderInfo.order.outTokenset[0].chain = "ETH";

        // 重新计算订单哈希
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));

        // 尝试添加燃烧费用请求
        vm.startPrank(owner);
        vm.expectRevert("order not valid");
        feeManager.addBurnFeeRequest(assetID, orderInfo);
        vm.stopPrank();
    }

    // 测试拒绝燃烧费用请求 - 请求状态不是PENDING
    function test_RejectBurnFeeRequest_NotPending() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM拒绝交换请求
        vm.stopPrank();
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        vm.startPrank(owner);

        // 拒绝燃烧费用请求
        feeManager.rejectBurnFeeRequest(nonce);

        // 尝试再次拒绝
        vm.expectRevert();
        feeManager.rejectBurnFeeRequest(nonce);

        vm.stopPrank();
    }

    // 测试拒绝燃烧费用请求 - 交换请求状态不正确
    function test_RejectBurnFeeRequest_SwapStatusNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM确认交换请求（而不是拒绝）
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // 尝试拒绝燃烧费用请求
        vm.expectRevert();
        feeManager.rejectBurnFeeRequest(nonce);

        vm.stopPrank();
    }

    // 测试确认燃烧费用请求 - 请求状态不是PENDING
    function test_ConfirmBurnFeeRequest_NotPending() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM确认交换请求
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // 确认燃烧费用请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        // 尝试再次确认
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // 测试确认燃烧费用请求 - 交换请求状态不是MAKER_CONFIRMED
    function test_ConfirmBurnFeeRequest_SwapStatusNotValid() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // 不让PMM确认交换请求

        // 尝试确认燃烧费用请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);

        vm.stopPrank();
    }

    // 测试确认燃烧费用请求 - 订单哈希不匹配
    function test_ConfirmBurnFeeRequest_OrderHashNotMatch() public {
        address assetTokenAddress = mintAndCollectFee();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint256 assetID = assetToken.id();

        // 创建订单信息并添加请求
        OrderInfo memory orderInfo = createOrderInfo(assetTokenAddress);
        vm.startPrank(owner);
        uint256 nonce = feeManager.addBurnFeeRequest(assetID, orderInfo);

        // PMM确认交换请求
        vm.stopPrank();
        pmmConfirmSwapRequest(orderInfo, true);

        vm.startPrank(owner);

        // 修改订单信息
        OrderInfo memory wrongOrderInfo = orderInfo;
        wrongOrderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        // 尝试确认燃烧费用请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "txHash";
        vm.expectRevert();
        feeManager.confirmBurnFeeRequest(nonce, wrongOrderInfo, inTxHashs);

        vm.stopPrank();
    }
}
