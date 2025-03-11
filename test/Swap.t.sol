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
        // 部署代币
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // 部署Swap合约
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // 设置角色
        swap.grantRole(swap.MAKER_ROLE(), maker);
        swap.grantRole(swap.TAKER_ROLE(), taker);

        // 设置白名单地址
        string[] memory receivers = new string[](2);
        receivers[0] = vm.toString(receiver);
        receivers[1] = vm.toString(taker);

        string[] memory senders = new string[](2);
        senders[0] = vm.toString(maker);
        senders[1] = vm.toString(taker);

        swap.setTakerAddresses(receivers, senders);

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
            amount: 1 * 10 ** 8 // 1 BTC
        });

        // 创建输出代币集合
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 20 * 10 ** 18 // 20 ETH
        });

        // 创建订单
        Order memory order = Order({
            chain: chain,
            maker: maker,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8, // 1 BTC
            outAmount: 10 ** 8, // 按比例
            deadline: block.timestamp + 3600, // 1小时后过期
            requester: taker
        });

        order.inAddressList[0] = vm.toString(maker);
        order.outAddressList[0] = vm.toString(receiver);

        // 计算订单哈希
        bytes32 orderHash = keccak256(abi.encode(order));

        // 签名
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 创建订单信息
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // 测试初始化
    function test_Initialize() public {
        assertEq(swap.chain(), chain);
        assertTrue(swap.hasRole(swap.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(swap.hasRole(swap.MAKER_ROLE(), maker));
        assertTrue(swap.hasRole(swap.TAKER_ROLE(), taker));
    }

    // 测试添加白名单代币
    function test_AddWhiteListTokens() public {
        vm.startPrank(owner);

        // 添加新代币
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

        // 验证白名单长度
        assertEq(swap.getWhiteListTokenLength(), 3);

        // 验证新添加的代币
        Token memory token = swap.getWhiteListToken(2);
        assertEq(token.symbol, "USDT");

        vm.stopPrank();
    }

    // 测试移除白名单代币
    function test_RemoveWhiteListTokens() public {
        vm.startPrank(owner);

        // 移除WBTC
        Token[] memory tokensToRemove = new Token[](1);
        tokensToRemove[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 0
        });

        swap.removeWhiteListTokens(tokensToRemove);

        // 验证白名单长度
        assertEq(swap.getWhiteListTokenLength(), 1);

        vm.stopPrank();
    }

    // 测试设置Taker地址
    function test_SetTakerAddresses() public {
        vm.startPrank(owner);

        // 设置新的Taker地址
        string[] memory newReceivers = new string[](1);
        newReceivers[0] = vm.toString(vm.addr(0x6));

        string[] memory newSenders = new string[](1);
        newSenders[0] = vm.toString(vm.addr(0x7));

        swap.setTakerAddresses(newReceivers, newSenders);

        // 验证新的Taker地址
        (string[] memory receivers, string[] memory senders) = swap.getTakerAddresses();
        assertEq(receivers.length, 1);
        assertEq(senders.length, 1);
        assertEq(receivers[0], newReceivers[0]);
        assertEq(senders[0], newSenders[0]);

        vm.stopPrank();
    }

    // 测试暂停和恢复
    function test_PauseAndUnpause() public {
        vm.startPrank(owner);

        // 暂停
        swap.pause();
        assertTrue(swap.paused());

        // 恢复
        swap.unpause();
        assertFalse(swap.paused());

        vm.stopPrank();
    }

    // 测试添加交换请求
    function test_AddSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        vm.startPrank(taker);

        // 添加交换请求
        swap.addSwapRequest(orderInfo, false, false);

        // 验证交换请求
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
        assertEq(request.requester, taker);

        vm.stopPrank();
    }

    // 测试添加交换请求 - 合约内转账
    function test_AddSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 铸造代币给maker
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // maker授权swap合约
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(taker);

        // 添加交换请求（输出通过合约）
        swap.addSwapRequest(orderInfo, false, true);

        // 验证交换请求
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
        assertEq(request.requester, taker);
        assertTrue(request.outByContract);

        vm.stopPrank();
    }

    // 测试maker确认交换请求 - 非合约转账
    function test_MakerConfirmSwapRequest_NotByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker确认
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.MAKER_CONFIRMED));
        assertEq(bytes32(request.outTxHashs[0]), bytes32("tx_hash_123"));
    }

    // 测试maker确认交换请求 - 合约转账
    function test_MakerConfirmSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // 铸造代币给maker
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // maker确认
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.MAKER_CONFIRMED));

        // 验证代币转移
        assertEq(WETH.balanceOf(receiver), 20 * 10 ** 18);
    }

    // 测试taker确认交换请求 - 非合约转账
    function test_ConfirmSwapRequest_NotByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker确认
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // taker确认
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash_456";
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CONFIRMED));
        assertEq(bytes32(request.inTxHashs[0]), bytes32("tx_hash_456"));
    }

    // 测试taker确认交换请求 - 合约转账
    function test_ConfirmSwapRequest_ByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // maker确认
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 铸造代币给taker
        vm.startPrank(address(WBTC));
        WBTC.mint(taker, 2 * 10 ** 8);
        vm.stopPrank();

        // taker确认
        vm.startPrank(taker);
        WBTC.approve(address(swap), 2 * 10 ** 8);
        bytes[] memory inTxHashs = new bytes[](0);
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CONFIRMED));

        // 验证代币转移
        assertEq(WBTC.balanceOf(maker), 1 * 10 ** 8);
    }

    // 测试回滚交换请求
    function test_RollbackSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker确认
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // taker回滚
        vm.startPrank(taker);
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.PENDING));
    }

    // 测试取消交换请求
    function test_CancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // 前进时间
        vm.warp(block.timestamp + 3601); // 超过MAX_MARKER_CONFIRM_DELAY

        // 取消请求
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.CANCEL));
    }

    // 测试强制取消交换请求
    function test_ForceCancelSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 前进时间
        vm.warp(block.timestamp + 7 hours); // 超过EXPIRATION

        // 管理员强制取消
        vm.startPrank(owner);
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.FORCE_CANCEL));
    }

    // 测试maker拒绝交换请求
    function test_MakerRejectSwapRequest() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker拒绝
        vm.startPrank(maker);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // 验证状态
        SwapRequest memory request = swap.getSwapRequest(orderInfo.orderHash);
        assertEq(uint256(request.status), uint256(SwapRequestStatus.REJECTED));
    }

    // 测试错误情况：非管理员添加白名单代币
    function test_AddWhiteListTokens_NotAdmin() public {
        vm.startPrank(nonOwner);

        Token[] memory tokens = new Token[](1);
        tokens[0] = Token({chain: chain, symbol: "TEST", addr: vm.toString(address(0x123)), decimals: 18, amount: 0});

        vm.expectRevert();
        swap.addWhiteListTokens(tokens);

        vm.stopPrank();
    }

    // 测试错误情况：订单已过期
    function test_AddSwapRequest_Expired() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改订单截止时间为过去
        orderInfo.order.deadline = block.timestamp - 1;

        // 重新计算哈希和签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        vm.startPrank(taker);

        // 尝试添加过期的交换请求
        vm.expectRevert();
        swap.addSwapRequest(orderInfo, false, false);

        vm.stopPrank();
    }

    // 测试错误情况：非taker取消请求
    function test_CancelSwapRequest_NotTaker() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 前进时间
        vm.warp(block.timestamp + 3601);

        // 非taker尝试取消
        vm.startPrank(nonOwner);
        vm.expectRevert();
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：非maker确认请求
    function test_MakerConfirmSwapRequest_NotMaker() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 非maker尝试确认
        vm.startPrank(nonOwner);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        vm.expectRevert();
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
    }

    // 测试错误情况：合约转账时余额不足
    function test_MakerConfirmSwapRequest_InsufficientBalance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // maker尝试确认但余额不足
        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        vm.expectRevert("not enough balance");
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
    }

    // 测试错误情况：合约转账时授权不足
    function test_MakerConfirmSwapRequest_InsufficientAllowance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // 铸造代币给maker但不授权
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        // maker尝试确认但授权不足
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

        // 修改订单哈希使其不匹配
        orderInfo.orderHash = bytes32(uint256(orderInfo.orderHash) + 1);

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 2); // 订单哈希不匹配
    }

    // 测试错误情况：签名无效
    function test_CheckOrderInfo_InvalidSignature() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改签名使其无效
        orderInfo.orderSign = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 3); // 签名无效
    }

    // 测试错误情况：订单已存在
    function test_CheckOrderInfo_OrderExists() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 先添加订单
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 再次检查订单
        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 4); // 订单已存在
    }

    // 测试错误情况：输入地址列表长度不匹配
    function test_CheckOrderInfo_InAddressListLengthMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改输入地址列表长度
        string[] memory newInAddressList = new string[](2);
        newInAddressList[0] = orderInfo.order.inAddressList[0];
        newInAddressList[1] = vm.toString(nonOwner);
        orderInfo.order.inAddressList = newInAddressList;

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 5); // 输入地址列表长度不匹配
    }

    // 测试错误情况：输出地址列表长度不匹配
    function test_CheckOrderInfo_OutAddressListLengthMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改输出地址列表长度
        string[] memory newOutAddressList = new string[](2);
        newOutAddressList[0] = orderInfo.order.outAddressList[0];
        newOutAddressList[1] = vm.toString(receiver);
        orderInfo.order.outAddressList = newOutAddressList;

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 6); // 输出地址列表长度不匹配
    }

    // 测试错误情况：maker不是MAKER_ROLE
    function test_CheckOrderInfo_NotMakerRole() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改maker为非MAKER_ROLE
        orderInfo.order.maker = nonOwner;

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(nonOwner);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x5, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 7); // 不是MAKER_ROLE
    }

    // 测试错误情况：输出地址不在白名单中
    function test_CheckOrderInfo_OutAddressNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改输出地址为非白名单地址
        orderInfo.order.outAddressList[0] = vm.toString(nonOwner);

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 8); // 输出地址不在白名单中
    }

    // 测试错误情况：链不匹配
    function test_CheckOrderInfo_ChainMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改链
        orderInfo.order.chain = "ETH";

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 9); // 链不匹配
    }

    // 测试错误情况：输入代币不在白名单中
    function test_CheckOrderInfo_InTokenNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改输入代币为非白名单代币
        orderInfo.order.inTokenset[0].symbol = "USDT";
        orderInfo.order.inTokenset[0].addr = vm.toString(vm.addr(0x9));

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 10); // 输入代币不在白名单中
    }

    // 测试错误情况：输出代币不在白名单中
    function test_CheckOrderInfo_OutTokenNotWhitelisted() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改输出代币为非白名单代币
        orderInfo.order.outTokenset[0].symbol = "USDT";
        orderInfo.order.outTokenset[0].addr = vm.toString(vm.addr(0x9));

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        uint256 code = swap.checkOrderInfo(orderInfo);
        assertEq(code, 11); // 输出代币不在白名单中
    }

    // 测试错误情况：订单哈希不存在
    function test_ValidateOrderInfo_OrderHashNotExists() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 尝试验证不存在的订单
        vm.startPrank(taker);
        vm.expectRevert("order hash not exists");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：订单哈希无效
    function test_ValidateOrderInfo_InvalidOrderHash() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 先添加订单
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // 修改订单但保持哈希不变
        orderInfo.order.nonce = 2;

        // 尝试验证修改后的订单
        vm.expectRevert("order hash invalid");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试getOrderHashs函数
    function test_GetOrderHashs() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加订单
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 获取订单哈希列表
        bytes32[] memory orderHashs = swap.getOrderHashs();
        assertEq(orderHashs.length, 1);
        assertEq(orderHashs[0], orderInfo.orderHash);
    }

    // 测试getOrderHashLength函数
    function test_GetOrderHashLength() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加订单
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 获取订单哈希长度
        uint256 length = swap.getOrderHashLength();
        assertEq(length, 1);
    }

    // 测试getOrderHash函数
    function test_GetOrderHash() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加订单
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 获取订单哈希
        bytes32 orderHash = swap.getOrderHash(0);
        assertEq(orderHash, orderInfo.orderHash);
    }

    // 测试getOrderHash函数越界错误
    function test_GetOrderHash_OutOfRange() public {
        // 尝试获取不存在的订单哈希
        vm.expectRevert("out of range");
        swap.getOrderHash(0);
    }

    // 测试checkTokenset函数错误情况：代币链不匹配
    function test_AddSwapRequest_ChainMismatch() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改代币链
        orderInfo.order.inTokenset[0].chain = "ETH";

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 尝试添加订单
        vm.startPrank(taker);
        vm.expectRevert("order not valid");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // 测试checkTokenset函数错误情况：代币地址为零
    function test_AddSwapRequest_ZeroTokenAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改代币地址为零
        orderInfo.order.inTokenset[0].addr = "0x0000000000000000000000000000000000000000";

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 尝试添加订单
        vm.startPrank(taker);
        vm.expectRevert("order not valid");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // 测试checkTokenset函数错误情况：接收地址为零
    function test_AddSwapRequest_ZeroReceiveAddress() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 修改接收地址为零
        orderInfo.order.inAddressList[0] = "0x0000000000000000000000000000000000000000";

        // 重新计算订单哈希并签名
        orderInfo.orderHash = keccak256(abi.encode(orderInfo.order));
        vm.startPrank(maker);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x2, orderInfo.orderHash);
        orderInfo.orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 尝试添加订单
        vm.startPrank(taker);
        vm.expectRevert("zero receive address");
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();
    }

    // 测试错误情况：取消请求时状态不是PENDING
    function test_CancelSwapRequest_NotPending() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 前进时间
        vm.warp(block.timestamp + 3601);

        // taker尝试取消已确认的请求
        vm.startPrank(taker);
        vm.expectRevert("swap request status is not pending");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：取消请求时未超时
    function test_CancelSwapRequest_NotTimeout() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // 尝试立即取消
        vm.expectRevert("swap request not timeout");
        swap.cancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：强制取消请求时状态不正确
    function test_ForceCancelSwapRequest_InvalidStatus() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(maker);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // 前进时间
        vm.warp(block.timestamp + 7 hours);

        // 管理员尝试强制取消已拒绝的请求
        vm.startPrank(owner);
        vm.expectRevert("swap request status is not pending or maker confirmed");
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：强制取消请求时未过期
    function test_ForceCancelSwapRequest_NotExpired() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // 管理员尝试立即强制取消
        vm.startPrank(owner);
        vm.expectRevert("swap request not expired");
        swap.forceCancelSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：回滚请求时状态不是MAKER_CONFIRMED
    function test_RollbackSwapRequest_NotMakerConfirmed() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // 尝试回滚未确认的请求
        vm.expectRevert("swap request status is not maker_confirmed");
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：回滚合约转账的请求
    function test_RollbackSwapRequest_OutByContract() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求，设置outByContract为true
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, true);
        vm.stopPrank();

        // 铸造代币给maker并授权
        vm.startPrank(address(WETH));
        WETH.mint(maker, 100 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(maker);
        WETH.approve(address(swap), 100 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](0);
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // taker尝试回滚合约转账的请求
        vm.startPrank(taker);
        vm.expectRevert("out by contract cannot rollback");
        swap.rollbackSwapRequest(orderInfo);
        vm.stopPrank();
    }

    // 测试错误情况：确认请求时状态不是MAKER_CONFIRMED
    function test_ConfirmSwapRequest_NotMakerConfirmed() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);

        // 尝试确认未经maker确认的请求
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash_123";
        vm.expectRevert("status error");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // 测试错误情况：确认请求时inTxHashs长度不匹配
    function test_ConfirmSwapRequest_WrongInTxHashsLength() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // taker尝试确认请求，但inTxHashs长度不匹配
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](2);
        inTxHashs[0] = "tx_hash_456";
        inTxHashs[1] = "tx_hash_789";
        vm.expectRevert("wrong inTxHashs length");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // 测试错误情况：确认请求时余额不足
    function test_ConfirmSwapRequest_InsufficientBalance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // taker尝试确认请求但余额不足
        vm.startPrank(taker);
        WBTC.approve(address(swap), 100 * 10 ** 8);
        bytes[] memory inTxHashs = new bytes[](0);
        vm.expectRevert("not enough balance");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // 测试错误情况：确认请求时授权不足
    function test_ConfirmSwapRequest_InsufficientAllowance() public {
        OrderInfo memory orderInfo = createOrderInfo();

        // 添加交换请求
        vm.startPrank(taker);
        swap.addSwapRequest(orderInfo, true, false);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(maker);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash_123";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 铸造代币给taker但不授权
        vm.startPrank(address(WBTC));
        WBTC.mint(taker, 100 * 10 ** 8);
        vm.stopPrank();

        // taker尝试确认请求但授权不足
        vm.startPrank(taker);
        bytes[] memory inTxHashs = new bytes[](0);
        vm.expectRevert("not enough allowance");
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // 测试getWhiteListToken函数越界错误
    function test_GetWhiteListToken_OutOfRange() public {
        // 尝试获取不存在的白名单代币
        vm.expectRevert();
        swap.getWhiteListToken(100);
    }
}
