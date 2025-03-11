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

contract USITest is Test {
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

        // 创建模拟代币
        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);

        vm.startPrank(owner);

        // 部署AssetFactory
        AssetToken tokenImpl = new AssetToken();
        AssetFactory factoryImpl = new AssetFactory();
        address factoryAddress = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(AssetFactory.initialize, (owner, vault, "SETH", address(tokenImpl)))
            )
        );
        factory = AssetFactory(factoryAddress);
        // 部署AssetIssuer
        issuer = AssetIssuer(
            address(
                new ERC1967Proxy(
                    address(new AssetIssuer()), abi.encodeCall(AssetController.initialize, (owner, address(factory)))
                )
            )
        );

        // 创建资产代币
        address assetTokenAddress =
            factory.createAssetToken(getAsset(), 10000, address(issuer), address(0x2), address(0x3), address(0x4));
        assetToken = AssetToken(assetTokenAddress);
        address assetTokenAddress2 =
            factory.createAssetToken(getAsset2(), 10000, address(issuer), address(0x2), address(0x3), address(0x4));
        assetToken2 = AssetToken(assetTokenAddress2);

        // 部署USSI合约
        ussi = USSI(
            address(
                new ERC1967Proxy(
                    address(new USSI()),
                    abi.encodeCall(USSI.initialize, (owner, orderSigner, address(factory), address(WBTC), "SETH"))
                )
            )
        );

        // 设置权限和支持的资产
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.addSupportAsset(ASSET_ID1);

        vm.stopPrank();

        // 给hedger铸造资产代币
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

    function test_Initialize() public {
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

        // 测试添加支持的资产
        ussi.addSupportAsset(2);

        // 验证资产已添加
        uint256[] memory assetIDs = ussi.getSupportAssetIDs();
        // 验证资产 2 在支持的资产列表中
        bool isSupportAsset = false;
        for (uint256 i = 0; i < assetIDs.length; i++) {
            if (assetIDs[i] == 2) {
                isSupportAsset = true;
                break;
            }
        }
        assertEq(isSupportAsset, true);

        // 测试移除支持的资产
        ussi.removeSupportAsset(2);

        // 验证资产已移除
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
        // 创建铸造订单
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
            receiver: receiver
        });

        // 签名订单
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 申请铸造
        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // 验证申请状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // 验证资产已转移
        assertEq(assetToken.balanceOf(hedger), 0);
        assertEq(assetToken.balanceOf(address(ussi)), MINT_AMOUNT);
    }

    function test_ConfirmMint() public {
        // 创建并申请铸造
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
            receiver: hedger
        });
        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();
        vm.startPrank(owner);
        // 确认铸造
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // 验证确认状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));

        // 验证USSI代币已铸造
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
    }

    function test_CancelMint() public {
        // 创建并申请铸造
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);

        // 尝试取消但还未超时
        vm.expectRevert("not timeout");
        ussi.cancelMint(orderHash);

        // 等待超时
        vm.warp(block.timestamp + ussi.MAX_MINT_DELAY() + 1);

        // 取消铸造
        ussi.cancelMint(orderHash);
        vm.stopPrank();

        // 验证取消状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CANCELED));

        // 验证资产已返还
        assertEq(assetToken.balanceOf(hedger), MINT_AMOUNT);
        assertEq(assetToken.balanceOf(address(ussi)), 0);
    }

    function test_RejectMint() public {
        // 创建并申请铸造
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // 拒绝铸造
        vm.startPrank(owner);
        ussi.rejectMint(orderHash);
        vm.stopPrank();

        // 验证拒绝状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // 验证资产已返还
        assertEq(assetToken.balanceOf(hedger), MINT_AMOUNT);
        assertEq(assetToken.balanceOf(address(ussi)), 0);
    }

    function test_ApplyRedeem() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        // 签名订单
        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 申请赎回
        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 验证申请状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
        assertEq(ussi.requestTimestamps(orderHash), block.timestamp);

        // 验证USSI代币已转移
        assertEq(ussi.balanceOf(hedger), 0);
        assertEq(ussi.balanceOf(address(ussi)), USSI_AMOUNT);
    }

    function test_ConfirmRedeem() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: hedger
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 确认赎回（使用交易哈希）
        vm.startPrank(owner);
        bytes32 txHash = bytes32(uint256(1));
        WBTC.mint(owner, MINT_AMOUNT);
        WBTC.transfer(address(ussi), MINT_AMOUNT);
        ussi.confirmRedeem(orderHash, txHash);
        vm.stopPrank();

        // 验证确认状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));
        assertEq(ussi.redeemTxHashs(orderHash), txHash);

        // 验证USSI代币已销毁
        assertEq(ussi.balanceOf(address(hedger)), 0);
    }

    function test_ConfirmRedeemWithToken() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 确认赎回（直接转账代币）
        vm.startPrank(owner);
        WBTC.mint(address(ussi), MINT_AMOUNT);
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // 验证确认状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CONFIRMED));

        // 验证代币已转移
        assertEq(WBTC.balanceOf(hedger), MINT_AMOUNT);
        assertEq(ussi.balanceOf(address(hedger)), 0);
    }

    function test_CancelRedeem() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);

        // 尝试取消但还未超时
        vm.expectRevert("not timeout");
        ussi.cancelRedeem(orderHash);

        // 等待超时
        vm.warp(block.timestamp + ussi.MAX_REDEEM_DELAY() + 1);

        // 取消赎回
        ussi.cancelRedeem(orderHash);
        vm.stopPrank();

        // 验证取消状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.CANCELED));

        // 验证USSI代币已返还
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
        assertEq(ussi.balanceOf(address(ussi)), 0);
    }

    function test_RejectRedeem() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 拒绝赎回
        vm.startPrank(owner);
        ussi.rejectRedeem(orderHash);
        vm.stopPrank();

        // 验证拒绝状态
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.REJECTED));

        // 验证USSI代币已返还
        assertEq(ussi.balanceOf(hedger), USSI_AMOUNT);
        assertEq(ussi.balanceOf(address(ussi)), 0);
    }

    function test_UpdateOrderSigner() public {
        address newOrderSigner = vm.addr(0x6);

        vm.startPrank(owner);
        ussi.updateOrderSigner(newOrderSigner);
        vm.stopPrank();

        assertEq(ussi.orderSigner(), newOrderSigner);

        // 测试错误情况
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

        // 测试错误情况
        vm.startPrank(owner);
        vm.expectRevert("redeem token is zero address");
        ussi.updateRedeemToken(address(0));

        vm.expectRevert("redeem token not change");
        ussi.updateRedeemToken(newRedeemToken);
        vm.stopPrank();
    }

    function test_Pause() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 暂停合约
        vm.startPrank(owner);
        ussi.pause();
        vm.stopPrank();

        // 测试暂停状态下的操作
        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ussi.applyRedeem(redeemOrder, orderSign);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        ussi.cancelRedeem(orderHash);

        vm.stopPrank();

        // 恢复合约
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        // 测试恢复后的操作
        vm.startPrank(hedger);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 验证申请成功
        assertEq(uint8(ussi.orderStatus(orderHash)), uint8(USSI.HedgeOrderStatus.PENDING));
    }

    function test_GetOrderHashs() public {
        // 创建多个订单
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
                receiver: receiver
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

        // 获取订单哈希列表
        bytes32[] memory orderHashs = ussi.getOrderHashs();

        // 验证列表长度
        assertEq(orderHashs.length, 3);
        assertEq(ussi.getOrderHashLength(), 3);

        // 验证可以通过索引获取订单哈希
        bytes32 orderHash = ussi.getOrderHash(1);
        assertEq(orderHash, orderHashs[1]);
    }

    function test_CheckHedgeOrder() public {
        // 创建有效的铸造订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(validMintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试有效订单
        ussi.checkHedgeOrder(validMintOrder, orderHash, orderSign);

        // 测试链不匹配
        USSI.HedgeOrder memory wrongChainOrder = validMintOrder;
        wrongChainOrder.chain = "ETH";
        orderHash = keccak256(abi.encode(wrongChainOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("chain not match");
        ussi.checkHedgeOrder(wrongChainOrder, orderHash, orderSign);

        // 测试不支持的资产ID
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
            receiver: receiver
        });
        wrongAssetOrder.assetID = 999;
        orderHash = keccak256(abi.encode(wrongAssetOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("assetID not supported");
        ussi.checkHedgeOrder(wrongAssetOrder, orderHash, orderSign);

        // 测试过期订单
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
            receiver: receiver
        });
        expiredOrder.deadline = block.timestamp - 1;
        orderHash = keccak256(abi.encode(expiredOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);

        vm.expectRevert("expired");
        ussi.checkHedgeOrder(expiredOrder, orderHash, orderSign);

        // 测试无效签名
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

        // 测试工厂地址为零
        vm.expectRevert("zero factory address");
        address(
            new ERC1967Proxy(
                address(newUSSI),
                abi.encodeCall(USSI.initialize, (owner, orderSigner, address(0), address(WBTC), "SETH"))
            )
        );

        // 测试赎回代币地址为零
        vm.expectRevert("zero redeem token address");
        address(
            new ERC1967Proxy(
                address(newUSSI),
                abi.encodeCall(USSI.initialize, (owner, orderSigner, address(factory), address(0), "SETH"))
            )
        );

        // 测试订单签名者地址为零
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
        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试正常赎回订单
        ussi.checkHedgeOrder(redeemOrder, orderHash, orderSign);

        // 测试接收者地址为零
        USSI.HedgeOrder memory zeroReceiverOrder = redeemOrder;
        zeroReceiverOrder.receiver = address(0);
        orderHash = keccak256(abi.encode(zeroReceiverOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);
        vm.expectRevert("receiver is zero address");
        ussi.checkHedgeOrder(zeroReceiverOrder, orderHash, orderSign);

        // 测试不支持的赎回代币
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
            receiver: receiver
        });
        wrongRedeemTokenOrder.redeemToken = address(WETH);
        orderHash = keccak256(abi.encode(wrongRedeemTokenOrder));
        (v, r, s) = vm.sign(orderSignerPk, orderHash);
        orderSign = abi.encodePacked(r, s, v);
        vm.expectRevert("redeem token not supported");
        ussi.checkHedgeOrder(wrongRedeemTokenOrder, orderHash, orderSign);
    }

    function test_ApplyMint_Revert() public {
        // 创建铸造订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试没有PARTICIPANT_ROLE权限
        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // 授予权限后测试暂停状态
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.pause();
        vm.stopPrank();

        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // 恢复合约并测试资产转移失败
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        vm.startPrank(hedger);
        // 不批准资产转移
        vm.expectRevert("not enough allowance");
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();
    }

    function test_ApplyRedeem_Revert() public {
        // 先铸造USSI代币
        deal(address(ussi), hedger, USSI_AMOUNT);

        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试没有PARTICIPANT_ROLE权限
        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 授予权限后测试暂停状态
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        ussi.pause();
        vm.stopPrank();

        vm.startPrank(hedger);
        vm.expectRevert();
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 恢复合约并测试代币转移失败
        vm.startPrank(owner);
        ussi.unpause();
        vm.stopPrank();

        vm.startPrank(hedger);
        // 不批准代币转移
        vm.expectRevert("not enough allowance");
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();
    }

    function test_ConfirmMint_Revert() public {
        // 创建铸造订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试订单不存在
        vm.startPrank(owner);
        vm.expectRevert("order not exists");
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // 申请铸造
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);
        vm.stopPrank();

        // 测试非owner确认
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.confirmMint(orderHash);
        vm.stopPrank();

        // 测试订单类型不匹配
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
            receiver: receiver
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
        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试订单不存在
        vm.startPrank(owner);
        vm.expectRevert("order not exists");
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // 申请赎回
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);
        vm.stopPrank();

        // 测试非owner确认
        vm.startPrank(hedger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, hedger));
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();

        // 测试订单类型不匹配
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
            receiver: receiver
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

        // 测试赎回代币余额不足
        vm.startPrank(owner);
        vm.expectRevert("not enough redeem token");
        ussi.confirmRedeem(orderHash, bytes32(0));
        vm.stopPrank();
    }

    function test_CancelMint_Revert() public {
        // 创建铸造订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(mintOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试订单不存在
        vm.startPrank(hedger);
        vm.expectRevert("order not exists");
        ussi.cancelMint(orderHash);
        vm.stopPrank();

        // 申请铸造
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        assetToken.approve(address(ussi), MINT_AMOUNT);
        ussi.applyMint(mintOrder, orderSign);

        // 测试订单类型不匹配
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
            receiver: receiver
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

    function test_CancelRedeem_Revert() public {
        // 创建赎回订单
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
            receiver: receiver
        });

        bytes32 orderHash = keccak256(abi.encode(redeemOrder));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(orderSignerPk, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);

        // 测试订单不存在
        vm.startPrank(hedger);
        vm.expectRevert("order not exists");
        ussi.cancelRedeem(orderHash);
        vm.stopPrank();

        // 申请赎回
        vm.startPrank(owner);
        ussi.grantRole(ussi.PARTICIPANT_ROLE(), hedger);
        vm.stopPrank();

        vm.startPrank(hedger);
        ussi.approve(address(ussi), USSI_AMOUNT);
        ussi.applyRedeem(redeemOrder, orderSign);

        // 测试订单类型不匹配
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
            receiver: receiver
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
}
