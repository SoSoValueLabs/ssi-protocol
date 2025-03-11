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
        // 部署代币
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);
        USDT = new MockToken("Tether USD", "USDT", 6);

        vm.startPrank(owner);
        swap = Swap(address(new ERC1967Proxy(address(new Swap()), abi.encodeCall(Swap.initialize, (owner, chain)))));

        // 部署AssetToken实现合约
        tokenImpl = new AssetToken();
        factoryImpl = new AssetFactory();

        // 部署Factory合约
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl), abi.encodeCall(AssetFactory.initialize, (owner, vault, chain, address(tokenImpl)))
            )
        );

        factory = AssetFactory(factoryAddress);
        // 部署Issuer合约
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

        // 设置角色
        swap.grantRole(swap.MAKER_ROLE(), pmm);
        swap.grantRole(swap.TAKER_ROLE(), ap);
        swap.grantRole(swap.TAKER_ROLE(), address(issuer));
        swap.grantRole(swap.TAKER_ROLE(), address(rebalancer));
        swap.grantRole(swap.TAKER_ROLE(), address(feeManager));

        // 设置白名单地址
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

        // 添加代币白名单
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

    // 创建资产代币
    function createAssetToken() internal returns (address) {
        vm.startPrank(owner);

        // 创建资产代币
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

        // 设置发行参数
        uint256 assetID = AssetToken(assetTokenAddress).id();
        issuer.setIssueFee(assetID, 10000); // 0.0001 (10000/10^8)
        issuer.setIssueAmountRange(assetID, Range({min: 1 * 10 ** WETH.decimals(), max: 10000 * 10 ** WETH.decimals()}));

        // 添加参与者
        issuer.addParticipant(assetID, ap);

        vm.stopPrank();

        return assetTokenAddress;
    }

    // 创建订单信息
    function createMintOrderInfo() internal returns (OrderInfo memory) {
        // 创建输入代币集合
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // 创建输出代币集合
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // 创建订单
        Order memory order = Order({
            chain: chain,
            maker: pmm,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 18, // 按比例
            outAmount: 10 ** 18, // 按比例
            deadline: block.timestamp + 3600, // 1小时后过期
            requester: ap
        });

        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(ap);

        // 计算订单哈希
        bytes32 orderHash = keccak256(abi.encode(order));

        // 签名
        vm.startPrank(pmm);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 创建订单信息
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    function createRedeemOrderInfo(address assetTokenAddress) internal returns (OrderInfo memory) {
        // 创建输入代币集合（资产代币）
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 1000000000000000000
        });

        // 创建输出代币集合（WETH）
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** 18 // 1 ETH
        });

        // 创建订单
        Order memory order = Order({
            chain: chain,
            maker: pmm,
            nonce: 2,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 18, // 1单位资产代币
            outAmount: 10 ** 18, // 1 ETH
            deadline: block.timestamp + 3600, // 1小时后过期
            requester: ap
        });

        order.inAddressList[0] = vm.toString(ap);
        order.outAddressList[0] = vm.toString(0x5CF7F96627F3C9903763d128A1cc5D97556A6b99);

        // 计算订单哈希
        bytes32 orderHash = keccak256(abi.encode(order));

        // 签名
        vm.startPrank(pmm);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        vm.stopPrank();

        // 创建订单信息
        OrderInfo memory orderInfo = OrderInfo({order: order, orderHash: orderHash, orderSign: orderSign});

        return orderInfo;
    }

    // 测试获取发行金额范围
    function test_GetIssueAmountRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        Range memory range = issuer.getIssueAmountRange(assetID);
        assertEq(range.min, 1 * 10 ** 18);
        assertEq(range.max, 10000 * 10 ** 18);
    }

    // 测试设置无效的发行金额范围
    function test_SetIssueAmountRange_InvalidRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);

        // 最小值大于最大值
        Range memory invalidRange1 = Range({min: 100, max: 50});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange1);

        // 最大值为0
        Range memory invalidRange2 = Range({min: 100, max: 0});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange2);

        // 最小值为0
        Range memory invalidRange3 = Range({min: 0, max: 100});
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, invalidRange3);

        vm.stopPrank();
    }

    // 测试获取发行费用
    function test_GetIssueFee() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        uint256 fee = issuer.getIssueFee(assetID);
        assertEq(fee, 10000);
    }

    // 测试设置无效的发行费用
    function test_SetIssueFee_InvalidFee() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);

        // 费用大于等于1
        uint256 invalidFee = 10 ** issuer.feeDecimals();
        vm.expectRevert("issueFee should less than 1");
        issuer.setIssueFee(assetID, invalidFee);

        vm.stopPrank();
    }

    // 测试添加参与者
    function test_AddParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        assertTrue(issuer.isParticipant(assetID, nonOwner));
        assertEq(issuer.getParticipantLength(assetID), 2); // ap和nonOwner
    }

    // 测试移除参与者
    function test_RemoveParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.removeParticipant(assetID, ap);
        vm.stopPrank();

        assertFalse(issuer.isParticipant(assetID, ap));
        assertEq(issuer.getParticipantLength(assetID), 0);
    }

    // 测试获取参与者
    function test_GetParticipants() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        address[] memory participants = issuer.getParticipants(assetID);
        assertEq(participants.length, 2);

        // 验证参与者列表包含ap和nonOwner
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

    // 测试获取参与者长度
    function test_GetParticipantLength() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        assertEq(issuer.getParticipantLength(assetID), 1); // 只有ap

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        assertEq(issuer.getParticipantLength(assetID), 2); // ap和nonOwner
    }

    // 测试获取参与者
    function test_GetParticipant() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        address participant = issuer.getParticipant(assetID, 0);
        assertEq(participant, ap);

        vm.startPrank(owner);
        issuer.addParticipant(assetID, nonOwner);
        vm.stopPrank();

        // 获取第二个参与者
        address participant2 = issuer.getParticipant(assetID, 1);
        assertEq(participant2, nonOwner);
    }

    // 测试获取参与者索引超出范围
    function test_GetParticipant_OutOfRange() public {
        // address assetTokenAddress = createAssetToken();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        vm.expectRevert("out of range");
        issuer.getParticipant(assetID, 1); // 只有一个参与者，索引1超出范围
    }

    // 测试添加铸造请求
    function test_AddMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
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

    // 测试获取铸造请求长度
    function test_GetMintRequestLength() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        assertEq(issuer.getMintRequestLength(), 0);

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        assertEq(issuer.getMintRequestLength(), 1);
    }

    // 测试取消铸造请求
    function test_CancelMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);

        // 等待一天后取消
        vm.warp(block.timestamp + 1 days);
        issuer.cancelMintRequest(nonce, orderInfo, false);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));
    }

    // 测试强制取消铸造请求
    function test_ForceCancelMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);

        // 等待一天后强制取消
        vm.warp(block.timestamp + 1 days);
        issuer.cancelMintRequest(nonce, orderInfo, true);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));

        // 验证可领取金额
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);
    }

    // 测试拒绝铸造请求
    function test_RejectMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // 拒绝铸造请求
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo, false);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));
    }

    // 测试强制拒绝铸造请求
    function test_ForceRejectMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // 强制拒绝铸造请求
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo, true);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));

        // 验证可领取金额
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);
    }

    // 测试确认铸造请求
    function test_ConfirmMintRequest() public {
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();

        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // 验证ap收到了资产代币
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), orderInfo.order.outAmount);
    }

    // 测试添加赎回请求
    function test_AddRedeemRequest() public {
        // 先铸造资产代币
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
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

    // 测试获取赎回请求长度
    function test_GetRedeemRequestLength() public {
        assertEq(issuer.getRedeemRequestLength(), 0);

        // 先铸造资产代币
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        assertEq(issuer.getRedeemRequestLength(), 1);
    }

    // 测试取消赎回请求
    function test_CancelRedeemRequest() public {
        // 先铸造资产代币
        // address assetTokenAddress = createAssetToken();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // 取消赎回请求
        vm.startPrank(ap);
        vm.warp(block.timestamp + 1 hours);
        issuer.cancelRedeemRequest(nonce, redeemOrderInfo);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CANCEL));
    }

    function test_RejectRedeemRequest() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(redeemOrderInfo);
        vm.stopPrank();

        // 拒绝赎回请求
        vm.startPrank(owner);
        issuer.rejectRedeemRequest(nonce);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.REJECTED));
    }

    // 测试确认赎回请求
    function test_ConfirmRedeemRequest() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();
        // 确认赎回请求
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));
    }

    // 测试强制确认赎回请求
    function test_ForceConfirmRedeemRequest() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();

        // 强制确认赎回请求
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, true);
        vm.stopPrank();

        Request memory request = issuer.getRedeemRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));

        // 验证可领取金额
        address tokenAddress = vm.parseAddress(redeemOrderInfo.order.outTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);
    }

    // 测试claim函数
    function test_Claim() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // 强制取消铸造请求，使ap有可领取的代币
        vm.startPrank(ap);
        vm.warp(block.timestamp + 1 days);
        issuer.cancelMintRequest(mintNonce, mintOrderInfo, true);
        vm.stopPrank();

        // 记录取消前的余额
        address tokenAddress = vm.parseAddress(mintOrderInfo.order.inTokenset[0].addr);
        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(ap);
        uint256 claimable = issuer.claimables(tokenAddress, ap);

        // 领取代币
        vm.startPrank(ap);
        issuer.claim(tokenAddress);
        vm.stopPrank();

        // 验证余额增加和可领取金额清零
        uint256 balanceAfter = IERC20(tokenAddress).balanceOf(ap);
        assertEq(balanceAfter - balanceBefore, claimable);
        assertEq(issuer.claimables(tokenAddress, ap), 0);
    }

    // 测试参与者相关函数
    function test_ParticipantFunctions() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 测试添加参与者
        vm.startPrank(owner);
        address newParticipant = vm.addr(0x9);
        issuer.addParticipant(assetID, newParticipant);
        vm.stopPrank();

        // 验证参与者已添加
        assertTrue(issuer.isParticipant(assetID, newParticipant));
        assertEq(issuer.getParticipantLength(assetID), 2); // ap和新参与者
        assertEq(issuer.getParticipant(assetID, 1), newParticipant);

        // 测试获取所有参与者
        address[] memory participants = issuer.getParticipants(assetID);
        assertEq(participants.length, 2);
        assertEq(participants[0], ap);
        assertEq(participants[1], newParticipant);

        // 测试移除参与者
        vm.startPrank(owner);
        issuer.removeParticipant(assetID, newParticipant);
        vm.stopPrank();

        // 验证参与者已移除
        assertFalse(issuer.isParticipant(assetID, newParticipant));
        assertEq(issuer.getParticipantLength(assetID), 1);
    }

    // 测试设置发行费用
    function test_SetIssueFee() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 设置新的发行费用
        vm.startPrank(owner);
        uint256 newFee = 5000; // 0.05%
        issuer.setIssueFee(assetID, newFee);
        vm.stopPrank();

        // 验证费用已更新
        assertEq(issuer.getIssueFee(assetID), newFee);

        // 测试设置过高的费用（应该失败）
        vm.startPrank(owner);
        vm.expectRevert("issueFee should less than 1");
        issuer.setIssueFee(assetID, 10 ** 8);
        vm.stopPrank();
    }

    // 测试设置发行金额范围
    function test_SetIssueAmountRange() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 设置新的发行金额范围
        vm.startPrank(owner);
        Range memory newRange = Range({min: 500 * 10 ** 8, max: 20000 * 10 ** 8});
        issuer.setIssueAmountRange(assetID, newRange);
        vm.stopPrank();

        // 验证范围已更新
        Range memory range = issuer.getIssueAmountRange(assetID);
        assertEq(range.min, newRange.min);
        assertEq(range.max, newRange.max);

        // 测试设置无效范围（最小值大于最大值）
        vm.startPrank(owner);
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, Range({min: 20000 * 10 ** 8, max: 500 * 10 ** 8}));
        vm.stopPrank();

        // 测试设置无效范围（最小值为0）
        vm.startPrank(owner);
        vm.expectRevert("wrong range");
        issuer.setIssueAmountRange(assetID, Range({min: 0, max: 500 * 10 ** 8}));
        vm.stopPrank();
    }

    // 测试getIssueAmountRange函数的错误情况
    function test_GetIssueAmountRangeError() public {
        uint256 newAssetID = 999; // 不存在的资产ID

        vm.expectRevert("issue amount range not set");
        issuer.getIssueAmountRange(newAssetID);
    }

    // 测试getIssueFee函数的错误情况
    function test_GetIssueFeeError() public {
        uint256 newAssetID = 999; // 不存在的资产ID

        vm.expectRevert("issue fee not set");
        issuer.getIssueFee(newAssetID);
    }

    // 测试addMintRequest函数的各种错误情况
    function test_AddMintRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 测试非参与者调用
        address nonParticipant = vm.addr(0x10);
        vm.startPrank(nonParticipant);
        vm.expectRevert("msg sender not order requester");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // 测试请求者不是消息发送者
        Order memory invalidOrder = orderInfo.order;
        invalidOrder.requester = nonParticipant;
        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: invalidOrder, orderHash: orderInfo.orderHash, orderSign: orderInfo.orderSign});

        vm.startPrank(ap);
        vm.expectRevert("msg sender not order requester");
        issuer.addMintRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();

        // 测试最大费用低于当前费用
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 20000);
        vm.stopPrank();

        vm.startPrank(ap);
        vm.expectRevert("current issue fee larger than max issue fee");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();
    }

    // 测试addRedeemRequest函数的各种错误情况
    function test_AddRedeemRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        // 测试非参与者调用
        address nonParticipant = vm.addr(0x10);
        deal(address(WETH), ap, 100000 * 10 ** 18);
        vm.startPrank(nonParticipant);
        vm.expectRevert("msg sender not order requester");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // 测试请求者不是消息发送者
        Order memory invalidOrder = redeemOrderInfo.order;
        invalidOrder.requester = nonParticipant;
        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: invalidOrder, orderHash: redeemOrderInfo.orderHash, orderSign: redeemOrderInfo.orderSign});

        vm.startPrank(ap);
        vm.expectRevert("msg sender not order requester");
        issuer.addRedeemRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();

        // 测试最大费用低于当前费用
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 20000);
        vm.stopPrank();

        vm.startPrank(ap);
        vm.expectRevert("current issue fee larger than max issue fee");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // 恢复费用
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 10000);
        vm.stopPrank();

        // 测试余额不足
        vm.startPrank(ap);
        redeemOrderInfo.order.requester = ap;
        IERC20(assetTokenAddress).transfer(nonParticipant, IERC20(assetTokenAddress).balanceOf(ap));
        vm.expectRevert("not enough asset token balance");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();
    }

    // 测试cancelMintRequest和cancelRedeemRequest的错误情况
    function test_CancelRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // 测试非请求者取消
        address nonRequester = vm.addr(0x10);
        vm.startPrank(nonRequester);
        vm.expectRevert("not order requester");
        issuer.cancelMintRequest(mintNonce, mintOrderInfo, false);
        vm.stopPrank();

        // 测试取消不存在的请求
        vm.startPrank(ap);
        vm.expectRevert("nonce too large");
        issuer.cancelMintRequest(999, mintOrderInfo, false);
        vm.stopPrank();

        // 测试取消已确认的请求
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

        vm.startPrank(ap);
        vm.expectRevert();
        issuer.cancelMintRequest(mintNonce, mintOrderInfo, false);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 redeemNonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 20000);
        vm.stopPrank();

        // 测试非请求者取消
        vm.startPrank(nonRequester);
        vm.expectRevert("not order requester");
        issuer.cancelRedeemRequest(redeemNonce, redeemOrderInfo);
        vm.stopPrank();

        // 测试取消不存在的请求
        vm.startPrank(ap);
        vm.expectRevert("nonce too large");
        issuer.cancelRedeemRequest(999, redeemOrderInfo);
        vm.stopPrank();
    }

    // 测试rejectMintRequest和rejectRedeemRequest的错误情况
    function test_RejectRequestErrors() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory mintOrderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // 测试非所有者拒绝
        nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.rejectMintRequest(mintNonce, mintOrderInfo, false);
        vm.stopPrank();

        // 测试拒绝不存在的请求
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.rejectMintRequest(999, mintOrderInfo, false);
        vm.stopPrank();

        // 测试拒绝已确认的请求
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

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 redeemNonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // 测试非所有者拒绝
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.rejectRedeemRequest(redeemNonce);
        vm.stopPrank();

        // 测试拒绝不存在的请求
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.rejectRedeemRequest(999);
        vm.stopPrank();
    }

    function test_ClaimError() public {
        address tokenAddress = address(WETH);

        // 测试没有可领取金额的情况
        vm.startPrank(ap);
        vm.expectRevert("nothing to claim");
        issuer.claim(tokenAddress);
        vm.stopPrank();
    }

    function test_GetParticipantError() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 测试索引超出范围的情况
        vm.expectRevert("out of range");
        issuer.getParticipant(assetID, 999);
    }

    // 测试confirmRedeemRequest函数的错误情况
    function test_ConfirmRedeemRequestErrors() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // 测试非所有者确认
        address nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();

        // 测试确认不存在的请求
        vm.startPrank(owner);
        vm.expectRevert("nonce too large");
        issuer.confirmRedeemRequest(999, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();

        // 测试确认未被maker确认的请求
        vm.startPrank(owner);
        vm.expectRevert();
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();
    }

    // 测试addMintRequest函数中的tokenset不匹配错误
    function test_AddMintRequestTokensetMismatch() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 修改订单中的输出代币集合，使其与资产代币的代币集合不匹配
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

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("order not valid");
        issuer.addMintRequest(assetID, modifiedOrderInfo, 10000);
        vm.stopPrank();
    }

    // 测试addRedeemRequest函数中的tokenset不匹配错误
    function test_AddRedeemRequestTokensetMismatch() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单，但修改输入代币集合
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

    // 测试addMintRequest函数中的订单无效错误
    function test_AddMintRequestInvalidOrder() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 修改订单签名，使其无效
        bytes memory invalidSign = new bytes(65);

        OrderInfo memory invalidOrderInfo =
            OrderInfo({order: orderInfo.order, orderHash: orderInfo.orderHash, orderSign: invalidSign});

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("order not valid");
        issuer.addMintRequest(assetID, invalidOrderInfo, 10000);
        vm.stopPrank();
    }

    // 测试addRedeemRequest函数中的授权不足错误
    function test_AddRedeemRequestInsufficientAllowance() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单，但不授权
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        // 不调用approve
        vm.expectRevert("not enough asset token allowance");
        issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();
    }

    // 测试burnFor函数
    function test_BurnForErrors() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 测试授权不足的情况
        vm.startPrank(ap);
        // 不调用approve
        vm.expectRevert("not enough allowance");
        issuer.burnFor(assetID, mintOrderInfo.order.outAmount);
        vm.stopPrank();

        // 测试正常销毁
        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        issuer.burnFor(assetID, mintOrderInfo.order.outAmount);
        vm.stopPrank();

        // 验证代币已销毁
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), 0);
    }

    // 测试withdraw函数
    function test_WithdrawErrors() public {
        // 向issuer合约转入一些代币
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank();

        // 测试非所有者调用
        address nonOwner = vm.addr(0x10);
        vm.startPrank(nonOwner);
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(WETH);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, nonOwner));
        issuer.withdraw(tokenAddresses);
        vm.stopPrank();

        // 测试在发行过程中提取
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // 尝试提取，应该失败
        vm.startPrank(owner);
        vm.expectRevert("is issuing");
        issuer.withdraw(tokenAddresses);
        vm.stopPrank();
    }

    // 测试checkRequestOrderInfo函数
    function test_CheckRequestOrderInfo() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // 创建不匹配的订单信息
        OrderInfo memory mismatchOrderInfo = createMintOrderInfo();
        bytes32 differentHash = keccak256("different_hash");

        // 尝试取消请求，但使用不匹配的订单信息
        vm.startPrank(ap);
        vm.expectRevert("order hash not match");
        issuer.cancelMintRequest(
            mintNonce,
            OrderInfo({order: mismatchOrderInfo.order, orderHash: differentHash, orderSign: mismatchOrderInfo.orderSign}),
            false
        );
        vm.stopPrank();
    }

    // 测试addMintRequest函数中的余额不足错误
    function test_AddMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 不给ap足够的代币
        vm.startPrank(ap);
        // 清空ap的WETH余额
        uint256 balance = WETH.balanceOf(ap);
        WETH.transfer(owner, balance);

        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        vm.expectRevert("not enough balance");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();
    }

    // 测试addMintRequest函数中的授权不足错误
    function test_AddMintRequestInsufficientAllowance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        // 不授权或授权不足
        WETH.approve(address(issuer), 1);
        vm.expectRevert("not enough allowance");
        issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();
    }

    // 测试cancelMintRequest函数中的余额不足错误
    function test_CancelMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // 从issuer合约中移除代币，模拟余额不足
        vm.startPrank(owner);
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
        vm.stopPrank();
        vm.startPrank(address(issuer));
        IERC20(tokenAddress).transfer(owner, issuerBalance);
        vm.stopPrank();

        // 尝试取消请求，应该失败
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(ap);
        vm.expectRevert("not enough balance");
        issuer.cancelMintRequest(nonce, orderInfo, false);
        vm.stopPrank();
    }

    // 测试rejectMintRequest函数中的余额不足错误
    function test_RejectMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();

        // 从issuer合约中移除代币，模拟余额不足
        vm.startPrank(owner);
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
        vm.stopPrank();
        vm.startPrank(address(issuer));
        IERC20(tokenAddress).transfer(owner, issuerBalance);
        vm.stopPrank();

        // 尝试拒绝请求，应该失败
        vm.startPrank(owner);
        vm.expectRevert("not enough balance");
        issuer.rejectMintRequest(nonce, orderInfo, false);
        vm.stopPrank();
    }

    // 测试confirmMintRequest函数中的余额不足错误
    function test_ConfirmMintRequestInsufficientBalance() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 从issuer合约中移除代币，模拟余额不足
        vm.startPrank(owner);
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 issuerBalance = IERC20(tokenAddress).balanceOf(address(issuer));
        vm.stopPrank();
        vm.startPrank(address(issuer));
        IERC20(tokenAddress).transfer(owner, issuerBalance);
        vm.stopPrank();

        // 尝试确认请求，应该失败
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough balance");
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();
    }

    // 测试confirmRedeemRequest函数中的余额不足错误
    function test_ConfirmRedeemRequestInsufficientBalance() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();

        // 移除资产代币
        vm.startPrank(address(issuer));
        IERC20(assetTokenAddress).transfer(owner, IERC20(assetTokenAddress).balanceOf(address(issuer)));
        vm.stopPrank();

        // 尝试确认赎回请求，应该失败
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough asset token to burn");
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();
    }

    // 测试rejectRedeemRequest函数中的余额不足错误
    function test_RejectRedeemRequestInsufficientBalance() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker拒绝请求
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(redeemOrderInfo);
        vm.stopPrank();

        // 从issuer合约中移除代币，模拟余额不足

        // 移除资产代币
        vm.startPrank(address(issuer));
        IERC20(assetTokenAddress).transfer(owner, IERC20(assetTokenAddress).balanceOf(address(issuer)));
        vm.stopPrank();

        // 尝试拒绝赎回请求，应该失败
        vm.startPrank(owner);
        vm.expectRevert("not enough asset token to transfer");
        issuer.rejectRedeemRequest(nonce);
        vm.stopPrank();
    }

    // 测试confirmRedeemRequest函数中的输出代币余额不足错误
    function test_ConfirmRedeemRequestOutputInsufficientBalance() public {
        // 先铸造资产代币
        OrderInfo memory mintOrderInfo = createMintOrderInfo();
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 mintNonce = issuer.addMintRequest(assetID, mintOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(mintOrderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(mintNonce, mintOrderInfo, inTxHashs);
        vm.stopPrank();

        // 创建赎回订单
        OrderInfo memory redeemOrderInfo = createRedeemOrderInfo(assetTokenAddress);

        vm.startPrank(ap);
        IERC20(assetTokenAddress).approve(address(issuer), mintOrderInfo.order.outAmount);
        uint256 nonce = issuer.addRedeemRequest(assetID, redeemOrderInfo, 10000);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory redeemOutTxHashs = new bytes[](1);
        redeemOutTxHashs[0] = "tx_hash";
        WETH.approve(address(swap), 1e15 * 10 ** 18);
        swap.makerConfirmSwapRequest(redeemOrderInfo, redeemOutTxHashs);
        vm.stopPrank();

        // 从issuer合约中移除输出代币，模拟余额不足
        vm.startPrank(owner);
        address outTokenAddress = vm.parseAddress(redeemOrderInfo.order.outTokenset[0].addr);
        vm.stopPrank();
        // 确保issuer没有足够的输出代币
        vm.startPrank(address(issuer));
        if (IERC20(outTokenAddress).balanceOf(address(issuer)) > 0) {
            IERC20(outTokenAddress).transfer(owner, IERC20(outTokenAddress).balanceOf(address(issuer)));
        }
        vm.stopPrank();

        // 尝试确认赎回请求，应该失败
        vm.startPrank(owner);
        bytes[] memory redeemInTxHashs = new bytes[](1);
        redeemInTxHashs[0] = "tx_hash";
        vm.expectRevert("not enough balance");
        issuer.confirmRedeemRequest(nonce, redeemOrderInfo, redeemInTxHashs, false);
        vm.stopPrank();
    }

    // 测试withdraw函数中的零地址处理
    function test_WithdrawZeroAddress() public {
        // 向issuer合约转入一些代币
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank();

        // 测试包含零地址的情况
        vm.startPrank(owner);
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(WETH);
        tokenAddresses[1] = address(0); // 零地址

        // 应该正常执行，不会因为零地址而失败
        issuer.withdraw(tokenAddresses);
        vm.stopPrank();

        // 验证WETH已提取
        assertEq(WETH.balanceOf(owner), 10 * 10 ** 18);
    }

    // 测试withdraw函数中的tokenClaimables处理
    function test_WithdrawWithClaimables() public {
        // 向issuer合约转入一些代币
        vm.startPrank(address(WETH));
        WETH.mint(address(issuer), 10 * 10 ** 18);
        vm.stopPrank();

        // 设置一些可领取的代币
        uint256 assetID = AssetToken(assetTokenAddress).id();
        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 10000);
        vm.stopPrank();

        // 强制取消铸造请求，使ap有可领取的代币
        vm.startPrank(ap);
        vm.warp(block.timestamp + 1 days);
        issuer.cancelMintRequest(nonce, orderInfo, true);
        vm.stopPrank();

        // 获取可领取金额
        address tokenAddress = vm.parseAddress(orderInfo.order.inTokenset[0].addr);
        uint256 claimable = issuer.claimables(tokenAddress, ap);
        assertTrue(claimable > 0);

        // 尝试提取代币
        vm.startPrank(owner);
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = tokenAddress;
        issuer.withdraw(tokenAddresses);
        vm.stopPrank();

        // 验证只提取了非可领取部分
        uint256 expectedWithdrawn = 10 * 10 ** 18; // 初始转入的金额
        uint256 tokenClaimable = issuer.tokenClaimables(tokenAddress);
    }

    // 测试addParticipant和removeParticipant函数的重复添加和移除
    function test_ParticipantDuplicateOperations() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 测试重复添加同一参与者
        vm.startPrank(owner);
        // ap已经是参与者，再次添加
        issuer.addParticipant(assetID, ap);
        vm.stopPrank();

        // 验证参与者数量没有变化
        assertEq(issuer.getParticipantLength(assetID), 1);

        // 测试移除不存在的参与者
        vm.startPrank(owner);
        address nonParticipant = vm.addr(0x10);
        issuer.removeParticipant(assetID, nonParticipant);
        vm.stopPrank();

        // 验证参与者数量没有变化
        assertEq(issuer.getParticipantLength(assetID), 1);
    }

    // 测试confirmMintRequest函数中的feeTokenAmount为0的情况
    function test_ConfirmMintRequestZeroFee() public {
        uint256 assetID = AssetToken(assetTokenAddress).id();

        // 设置发行费用为0
        vm.startPrank(owner);
        issuer.setIssueFee(assetID, 0);
        vm.stopPrank();

        OrderInfo memory orderInfo = createMintOrderInfo();

        // 铸造代币给ap
        vm.startPrank(address(WETH));
        WETH.mint(ap, 10 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(ap);
        WETH.approve(address(issuer), 1e15 * 10 ** 18);
        uint256 nonce = issuer.addMintRequest(assetID, orderInfo, 0);
        vm.stopPrank();

        // maker确认请求
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "tx_hash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();

        // 确认铸造请求
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "tx_hash";
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();

        // 验证请求已确认
        Request memory request = issuer.getMintRequest(nonce);
        assertEq(uint256(request.status), uint256(RequestStatus.CONFIRMED));
    }
}
