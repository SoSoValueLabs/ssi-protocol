// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import {Upgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
// import "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "../lib/openzeppelin-foundry-upgrades/src/Options.sol";
import {DefenderOptions} from "../lib/openzeppelin-foundry-upgrades/src/Options.sol";
import {TxOverrides} from "../lib/openzeppelin-foundry-upgrades/src/Options.sol";

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/AssetFactory.sol";

import {Test, console} from "forge-std/Test.sol";

contract FundManagerTest is Test {
    MockToken WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
    MockToken WETH = new MockToken("Wrapped ETH", "WETH", 18);

    address swapProxy;
    address assetFactoryProxy;
    address assetIssuerProxy;
    address assetRebalancerProxy;
    address assetFeeManagerProxy;

    address owner = vm.addr(0x1);
    address vault =
        vm.parseAddress("0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63");
    address pmm = vm.addr(0x3);
    address ap = vm.addr(0x4);

    Swap swap;
    AssetIssuer issuer;
    AssetRebalancer rebalancer;
    AssetFeeManager feeManager;
    AssetFactory factory;

    function setUp() public {
        Options memory options;
        options.unsafeSkipProxyAdminCheck = true;

        vm.startPrank(owner);

        swapProxy = Upgrades.deployTransparentProxy(
            "Swap.sol",
            owner,
            abi.encodeCall(Swap.initialize, (owner, "SETH"))
        );
        swap = Swap(swapProxy);

        assetFactoryProxy = Upgrades.deployTransparentProxy(
            "AssetFactory.sol",
            owner,
            abi.encodeCall(
                AssetFactory.initialize,
                (owner, swapProxy, vault, "SETH")
            )
        );
        factory = AssetFactory(assetFactoryProxy);

        assetIssuerProxy = Upgrades.deployTransparentProxy(
            "AssetIssuer.sol",
            owner,
            abi.encodeCall(AssetIssuer.initialize, (owner, assetFactoryProxy))
        );
        issuer = AssetIssuer(assetIssuerProxy);

        assetRebalancerProxy = Upgrades.deployTransparentProxy(
            "AssetRebalancer.sol",
            owner,
            abi.encodeCall(
                AssetRebalancer.initialize,
                (owner, assetFactoryProxy)
            )
        );
        rebalancer = AssetRebalancer(assetRebalancerProxy);

        assetFeeManagerProxy = Upgrades.deployTransparentProxy(
            "AssetFeeManager.sol",
            owner,
            abi.encodeCall(
                AssetFeeManager.initialize,
                (owner, assetFactoryProxy)
            )
        );
        feeManager = AssetFeeManager(assetFeeManagerProxy);

        swap.grantRole(swap.MAKER_ROLE(), pmm);
        swap.grantRole(swap.TAKER_ROLE(), assetIssuerProxy);
        swap.grantRole(swap.TAKER_ROLE(), assetRebalancerProxy);
        swap.grantRole(swap.TAKER_ROLE(), assetFeeManagerProxy);
        string[] memory outWhiteAddresses = new string[](2);
        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);
        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);
        vm.stopPrank();
    }

    // function test_Sign() public view {
    //     address maker = 0xd1d1aDfD330B29D4ccF9E0d44E90c256Df597dc9;
    //     bytes32 orderHash = 0xd43e73902ff40548ac79fff32652e7e0a9af269dcbaf60999601fee4267797a8;
    //     bytes
    //         memory orderSign = hex"81542ef8cee89f0c5501db77e5c0836f367c06039de4454b529df8f63d347ae8083ef4b33cdea8b5defb799b154b6d1f1fa3baf88614ae8c2024cd2579f1b0371b";
    //     assertTrue(
    //         SignatureChecker.isValidSignatureNow(maker, orderHash, orderSign)
    //     );
    // }

    uint maxFee = 10000;
    function getAsset() public view returns (Asset memory) {
        Token[] memory tokenset_ = new Token[](1);
        tokenset_[0] = Token({
            chain: "SETH",
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: (10 * 10 ** WBTC.decimals()) / 60000
        });
        Asset memory asset = Asset({
            id: 1,
            name: "BTC",
            symbol: "BTC",
            tokenset: tokenset_
        });
        return asset;
    }

    function createAssetToken() public returns (address) {
        vm.startPrank(owner);
        address assetTokenAddress = factory.createAssetToken(
            getAsset(),
            maxFee,
            assetIssuerProxy,
            assetRebalancerProxy,
            assetFeeManagerProxy
        );
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        issuer.setIssueFee(assetToken.id(), 10000);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 10 * 10 ** 8, max: 10000 * 10 ** 8})
        );
        issuer.addParticipant(assetToken.id(), ap);
        vm.stopPrank();
        return assetTokenAddress;
    }

    function pmmQuoteMint() public returns (OrderInfo memory) {
        vm.startPrank(pmm);
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** WETH.decimals()
        });
        Order memory order = Order({
            maker: pmm,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: getAsset().tokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8,
            outAmount: (3000 * 10 ** 8) / 10,
            deadline: vm.getBlockTimestamp() + 60
        });
        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(vault);
        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        OrderInfo memory orderInfo = OrderInfo({
            order: order,
            orderHash: orderHash,
            orderSign: orderSign
        });
        vm.stopPrank();
        return orderInfo;
    }

    function apAddMintRequest(
        address assetTokenAddress,
        OrderInfo memory orderInfo
    ) public returns (uint, uint) {
        vm.startPrank(ap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        WETH.mint(ap, (10 ** WETH.decimals() * (10 ** 8 + 10000)) / 10 ** 8);
        WETH.approve(
            assetIssuerProxy,
            (10 ** WETH.decimals() * (10 ** 8 + 10000)) / 10 ** 8
        );
        uint amountBeforeMint = WETH.balanceOf(ap);
        uint nonce = issuer.addMintRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
        return (nonce, amountBeforeMint);
    }

    function pmmConfirmSwapRequest(
        OrderInfo memory orderInfo,
        bool byContract
    ) public {
        vm.startPrank(pmm);
        uint transferAmount = (orderInfo.order.outTokenset[0].amount *
            orderInfo.order.outAmount) / 10 ** 8;
        MockToken token = MockToken(
            vm.parseAddress(orderInfo.order.outTokenset[0].addr)
        );
        token.mint(pmm, transferAmount);
        if (!byContract) {
            token.transfer(
                vm.parseAddress(orderInfo.order.outAddressList[0]),
                transferAmount
            );
            bytes[] memory outTxHashs = new bytes[](1);
            outTxHashs[0] = "outTxHashs";
            swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        } else {
            token.approve(swapProxy, transferAmount);
            bytes[] memory outTxHashs = new bytes[](0);
            swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        }
    }

    function vaultConfirmSwap(
        OrderInfo memory orderInfo,
        uint256 beforeAmount,
        bool check
    ) public {
        vm.startPrank(vault);
        if (check) {
            uint outAmount = (orderInfo.order.outTokenset[0].amount *
                orderInfo.order.outAmount) / 10 ** 8;
            MockToken outToken = MockToken(
                vm.parseAddress(orderInfo.order.outTokenset[0].addr)
            );
            vm.assertEq(outToken.balanceOf(vault), outAmount + beforeAmount);
        }
        uint inAmount = (orderInfo.order.inTokenset[0].amount *
            orderInfo.order.inAmount) / 10 ** 8;
        MockToken inToken = MockToken(
            vm.parseAddress(orderInfo.order.inTokenset[0].addr)
        );
        inToken.transfer(pmm, inAmount);
        vm.stopPrank();
    }

    function confirmMintRequest(uint nonce, OrderInfo memory orderInfo) public {
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "inTxHashs";
        issuer.confirmMintRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();
    }

    function pmmQuoteRedeem() public returns (OrderInfo memory) {
        vm.startPrank(pmm);
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** WETH.decimals()
        });
        WETH.approve(swapProxy, 10 ** WETH.decimals());
        Order memory order = Order({
            maker: pmm,
            nonce: 1,
            inTokenset: getAsset().tokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: (3000 * 10 ** 8) / 10,
            outAmount: 10 ** 8,
            deadline: vm.getBlockTimestamp() + 60
        });
        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(assetIssuerProxy);
        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        OrderInfo memory orderInfo = OrderInfo({
            order: order,
            orderHash: orderHash,
            orderSign: orderSign
        });
        vm.stopPrank();
        return orderInfo;
    }

    function apAddRedeemRequest(
        address assetTokenAddress,
        OrderInfo memory orderInfo
    ) public returns (uint, uint) {
        vm.startPrank(ap);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        assetToken.approve(assetIssuerProxy, orderInfo.order.inAmount);
        uint amountBeforeRedeem = assetToken.balanceOf(ap);
        uint nonce = issuer.addRedeemRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
        return (nonce, amountBeforeRedeem);
    }

    function vaultTransferToIssuer(
        OrderInfo memory orderInfo
    ) public returns (address) {
        vm.startPrank(vault);
        uint outAmount = (orderInfo.order.outTokenset[0].amount *
            orderInfo.order.outAmount) / 10 ** 8;
        MockToken outToken = MockToken(
            vm.parseAddress(orderInfo.order.outTokenset[0].addr)
        );
        outToken.transfer(assetIssuerProxy, outAmount);
        vm.stopPrank();
        return address(outToken);
    }

    function confirmRedeemRequest(
        uint nonce,
        OrderInfo memory orderInfo
    ) public {
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "inTxHashs";
        issuer.confirmRedeemRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();
    }

    function collectFeeTokenset(address assetTokenAddress) public {
        AssetToken assetToken = AssetToken(assetTokenAddress);
        Token[] memory basket = assetToken.getBasket();
        vm.startPrank(owner);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        feeManager.collectFeeTokenset(assetToken.id());
        vm.stopPrank();
        uint firstDayAmount = basket[0].amount -
            (basket[0].amount * assetToken.fee()) /
            10 ** assetToken.feeDecimals();
        uint sencodDayAmount = firstDayAmount -
            (firstDayAmount * assetToken.fee()) /
            10 ** assetToken.feeDecimals();
        uint feeAmount = 0;
        feeAmount +=
            (basket[0].amount * assetToken.fee()) /
            10 ** assetToken.feeDecimals();
        feeAmount +=
            (firstDayAmount * assetToken.fee()) /
            10 ** assetToken.feeDecimals();
        assertEq(assetToken.getBasket()[0].amount, sencodDayAmount);
        assertEq(assetToken.getFeeTokenset()[0].amount, feeAmount);
        assertEq(
            assetToken.getTokenset()[0].amount,
            (sencodDayAmount * 10 ** assetToken.decimals()) /
                assetToken.totalSupply()
        );
    }

    function pmmQuoteBurn(
        address assetTokenAddress
    ) public returns (OrderInfo memory) {
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
            maker: pmm,
            nonce: 1,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8,
            outAmount: (60000 * inTokenset[0].amount) / 3000,
            deadline: vm.getBlockTimestamp() + 60
        });
        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(vault);
        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        OrderInfo memory orderInfo = OrderInfo({
            order: order,
            orderHash: orderHash,
            orderSign: orderSign
        });
        vm.stopPrank();
        return orderInfo;
    }

    function addBurnFeeRequest(
        address assetTokenAddress,
        OrderInfo memory orderInfo
    ) public returns (uint) {
        vm.startPrank(owner);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        uint nonce = feeManager.addBurnFeeRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
        return nonce;
    }

    function confirmBurnFeeRequest(
        uint nonce,
        OrderInfo memory orderInfo
    ) public {
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "inTxHashs";
        feeManager.confirmBurnFeeRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();
    }

    function pmmQuoteRebalance(
        address assetTokenAddress
    ) public returns (OrderInfo memory) {
        vm.startPrank(pmm);
        AssetToken assetToken = AssetToken(assetTokenAddress);
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: "SETH",
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 10 ** WETH.decimals()
        });
        Order memory order = Order({
            maker: pmm,
            nonce: 1,
            inTokenset: assetToken.getBasket(),
            outTokenset: outTokenset,
            inAddressList: new string[](1),
            outAddressList: new string[](1),
            inAmount: 10 ** 8,
            outAmount: (assetToken.getBasket()[0].amount * 60000) / 3000,
            deadline: vm.getBlockTimestamp() + 60
        });
        order.inAddressList[0] = vm.toString(pmm);
        order.outAddressList[0] = vm.toString(vault);
        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x3, orderHash);
        bytes memory orderSign = abi.encodePacked(r, s, v);
        OrderInfo memory orderInfo = OrderInfo({
            order: order,
            orderHash: orderHash,
            orderSign: orderSign
        });
        vm.stopPrank();
        return orderInfo;
    }

    function addRebalanceRequest(
        address assetTokenAddress,
        OrderInfo memory orderInfo
    ) public returns (uint) {
        vm.startPrank(owner);
        AssetToken assetToken = AssetToken(assetTokenAddress);
        uint nonce = rebalancer.addRebalanceRequest(
            assetToken.id(),
            assetToken.getBasket(),
            orderInfo
        );
        vm.stopPrank();
        return nonce;
    }

    function confirmRebalanceRequest(
        uint nonce,
        OrderInfo memory orderInfo
    ) public {
        vm.startPrank(owner);
        bytes[] memory inTxHashs = new bytes[](1);
        inTxHashs[0] = "inTxHashs";
        rebalancer.confirmRebalanceRequest(nonce, orderInfo, inTxHashs);
        vm.stopPrank();
    }

    function test_CreateAssetToken() public {
        address assetTokenAddress = createAssetToken();
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        assertEq(factory.getAssetIDs().length, 1);
        assertEq(
            factory.assetTokens(factory.getAssetIDs()[0]),
            assetTokenAddress
        );
        assertEq(issuer.getIssueFee(assetToken.id()), 10000);
        assertEq(
            abi.encode(issuer.getIssueAmountRange(assetToken.id())),
            abi.encode(Range({min: 10 * 10 ** 8, max: 10000 * 10 ** 8}))
        );
    }

    function test_Mint() public returns (address) {
        address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = pmmQuoteMint();
        (uint nonce, ) = apAddMintRequest(assetTokenAddress, orderInfo);
        // uint256 beforeAmount = IERC20(vm.parseAddress(orderInfo.order.outTokenset[0].addr)).balanceOf(vault);
        pmmConfirmSwapRequest(orderInfo, false);
        // vaultConfirmSwap(orderInfo, beforeAmount);
        confirmMintRequest(nonce, orderInfo);
        assertEq(
            IERC20(assetTokenAddress).balanceOf(ap),
            orderInfo.order.outAmount
        );
        assertEq(
            AssetToken(assetTokenAddress).getBasket()[0].amount,
            (orderInfo.order.outTokenset[0].amount *
                orderInfo.order.outAmount) / 10 ** 8
        );
        return assetTokenAddress;
    }

    function test_Redeem() public {
        address assetTokenAddress = test_Mint();
        OrderInfo memory orderInfo = pmmQuoteRedeem();
        (uint nonce, ) = apAddRedeemRequest(assetTokenAddress, orderInfo);
        uint256 beforeAmount = IERC20(
            vm.parseAddress(orderInfo.order.outTokenset[0].addr)
        ).balanceOf(vault);
        pmmConfirmSwapRequest(orderInfo, true);
        vaultConfirmSwap(orderInfo, beforeAmount, false);
        // address outTokenAddress = vaultTransferToIssuer(orderInfo);
        address outTokenAddress = vm.parseAddress(
            orderInfo.order.outTokenset[0].addr
        );
        confirmRedeemRequest(nonce, orderInfo);
        MockToken outToken = MockToken(outTokenAddress);
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), 0);
        uint256 expectAmount = (orderInfo.order.outTokenset[0].amount *
            orderInfo.order.outAmount) / 10 ** 8;
        assertEq(
            outToken.balanceOf(ap),
            expectAmount - (expectAmount * 10000) / 10 ** 8
        );
    }

    function test_BurnFee() public {
        address assetTokenAddress = test_Mint();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        collectFeeTokenset(assetTokenAddress);
        assertEq(assetToken.getFeeTokenset().length, 1);
        OrderInfo memory orderInfo = pmmQuoteBurn(assetTokenAddress);
        uint nonce = addBurnFeeRequest(assetTokenAddress, orderInfo);
        uint256 beforeAmount = IERC20(
            vm.parseAddress(orderInfo.order.outTokenset[0].addr)
        ).balanceOf(vault);
        pmmConfirmSwapRequest(orderInfo, true);
        vaultConfirmSwap(orderInfo, beforeAmount, false);
        confirmBurnFeeRequest(nonce, orderInfo);
        assertEq(assetToken.getFeeTokenset().length, 0);
        assertEq(
            IERC20(vm.parseAddress(orderInfo.order.outTokenset[0].addr))
                .balanceOf(vault),
            beforeAmount +
                (orderInfo.order.outTokenset[0].amount *
                    orderInfo.order.outAmount) /
                10 ** 8
        );
    }

    function test_Rebalance() public {
        address assetTokenAddress = test_Mint();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        OrderInfo memory orderInfo = pmmQuoteRebalance(assetTokenAddress);
        uint nonce = addRebalanceRequest(assetTokenAddress, orderInfo);
        uint256 beforeAmount = IERC20(
            vm.parseAddress(orderInfo.order.outTokenset[0].addr)
        ).balanceOf(vault);
        pmmConfirmSwapRequest(orderInfo, false);
        vaultConfirmSwap(orderInfo, beforeAmount, true);
        confirmRebalanceRequest(nonce, orderInfo);
        assertEq(
            assetToken.getBasket()[0].symbol,
            orderInfo.order.outTokenset[0].symbol
        );
        assertEq(
            assetToken.getBasket()[0].amount,
            (orderInfo.order.outTokenset[0].amount *
                orderInfo.order.outAmount) / 10 ** 8
        );
        assertEq(
            assetToken.getBasket()[0].amount,
            (assetToken.getTokenset()[0].amount * assetToken.totalSupply()) /
                10 ** 8
        );
        assertEq(
            assetToken.getBasket()[0].amount,
            IERC20(vm.parseAddress(assetToken.getBasket()[0].addr)).balanceOf(
                vault
            ) - beforeAmount
        );
    }

    function test_PauseIssuer() public {
        address assetTokenAddress = createAssetToken();
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        OrderInfo memory orderInfo = pmmQuoteMint();
        vm.startPrank(owner);
        assertEq(issuer.paused(), false);
        issuer.pause();
        assertEq(issuer.paused(), true);
        vm.stopPrank();
        vm.startPrank(ap);
        WETH.mint(ap, 10 ** WETH.decimals());
        WETH.approve(assetIssuerProxy, 10 ** WETH.decimals());
        vm.expectRevert();
        issuer.addMintRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
    }

    function test_RejectMint() public {
        address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = pmmQuoteMint();
        IERC20 inToken = IERC20(
            vm.parseAddress(orderInfo.order.inTokenset[0].addr)
        );
        (uint nonce, uint amountBeforeMint) = apAddMintRequest(
            assetTokenAddress,
            orderInfo
        );
        Request memory mintRequest = issuer.getMintRequest(nonce);
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        // vm.startPrank(vault);
        // uint tokenAmount = orderInfo.order.inTokenset[0].amount * orderInfo.order.inAmount / 10**8;
        // uint feeAmount = tokenAmount * 10000 / 10**8;
        // inToken.transfer(address(issuer), tokenAmount + feeAmount);
        // vm.stopPrank();
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo);
        assertEq(inToken.balanceOf(ap), amountBeforeMint);
        assertTrue(
            issuer.getMintRequest(nonce).status == RequestStatus.REJECTED
        );
        assertTrue(
            swap.getSwapRequest(mintRequest.orderHash).status ==
                SwapRequestStatus.REJECTED
        );
    }

    function test_RejectRedeem() public {
        address assetTokenAddress = test_Mint();
        OrderInfo memory orderInfo = pmmQuoteRedeem();
        (uint nonce, uint amountBeforeRedeem) = apAddRedeemRequest(
            assetTokenAddress,
            orderInfo
        );
        Request memory redeemRequest = issuer.getRedeemRequest(nonce);
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.rejectRedeemRequest(nonce);
        assertEq(IERC20(assetTokenAddress).balanceOf(ap), amountBeforeRedeem);
        assertTrue(
            issuer.getRedeemRequest(nonce).status == RequestStatus.REJECTED
        );
        assertTrue(
            swap.getSwapRequest(redeemRequest.orderHash).status ==
                SwapRequestStatus.REJECTED
        );
    }

    function test_RejectRebalance() public {
        address assetTokenAddress = test_Mint();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        OrderInfo memory orderInfo = pmmQuoteRebalance(assetTokenAddress);
        Token[] memory basket = assetToken.getBasket();
        Token[] memory tokenset = assetToken.getTokenset();
        uint256 vaultBeforeAmount = IERC20(vm.parseAddress(basket[0].addr))
            .balanceOf(vault);
        uint256 apBeforeAmount = assetToken.balanceOf(ap);
        uint nonce = addRebalanceRequest(assetTokenAddress, orderInfo);
        Request memory rebalanceRequest = rebalancer.getRebalanceRequest(nonce);
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        rebalancer.rejectRebalanceRequest(nonce);
        vm.stopPrank();
        assertEq(
            keccak256(abi.encode(assetToken.getBasket())),
            keccak256(abi.encode(basket))
        );
        assertEq(
            keccak256(abi.encode(assetToken.getTokenset())),
            keccak256(abi.encode(tokenset))
        );
        assertEq(apBeforeAmount, assetToken.balanceOf(ap));
        assertEq(
            vaultBeforeAmount,
            IERC20(vm.parseAddress(assetToken.getBasket()[0].addr)).balanceOf(
                vault
            )
        );
        assertTrue(
            rebalancer.getRebalanceRequest(nonce).status ==
                RequestStatus.REJECTED
        );
        assertTrue(
            swap.getSwapRequest(rebalanceRequest.orderHash).status ==
                SwapRequestStatus.REJECTED
        );
    }

    function test_RejectBurnFee() public {
        address assetTokenAddress = test_Mint();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        collectFeeTokenset(assetTokenAddress);
        assertEq(assetToken.getFeeTokenset().length, 1);
        OrderInfo memory orderInfo = pmmQuoteBurn(assetTokenAddress);
        Token[] memory feeTokenset = assetToken.getFeeTokenset();
        uint256 vaultBeforeAmount = IERC20(vm.parseAddress(feeTokenset[0].addr))
            .balanceOf(vault);
        uint nonce = addBurnFeeRequest(assetTokenAddress, orderInfo);
        Request memory burnFeeRequest = feeManager.getBurnFeeRequest(nonce);
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        feeManager.rejectBurnFeeRequest(nonce);
        vm.stopPrank();
        assertEq(
            keccak256(abi.encode(assetToken.getFeeTokenset())),
            keccak256(abi.encode(feeTokenset))
        );
        assertEq(
            vaultBeforeAmount,
            IERC20(vm.parseAddress(feeTokenset[0].addr)).balanceOf(vault)
        );
        assertTrue(
            feeManager.getBurnFeeRequest(nonce).status == RequestStatus.REJECTED
        );
        assertTrue(
            swap.getSwapRequest(burnFeeRequest.orderHash).status ==
                SwapRequestStatus.REJECTED
        );
    }

    function test_MintRange() public {
        address assetTokenAddress = createAssetToken();
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        OrderInfo memory orderInfo = pmmQuoteMint();
        WETH.mint(ap, (10 ** WETH.decimals() * (10 ** 8 + 10000)) / 10 ** 8);
        WETH.approve(
            assetIssuerProxy,
            (10 ** WETH.decimals() * (10 ** 8 + 10000)) / 10 ** 8
        );
        vm.startPrank(owner);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 400 * 10 ** 8, max: 10000 * 10 ** 8})
        );
        vm.stopPrank();
        vm.startPrank(ap);
        // vm.expectRevert(bytes("mint amount not in range"));
        issuer.addMintRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 100 * 10 ** 8, max: 200 * 10 ** 8})
        );
        vm.stopPrank();
        vm.startPrank(ap);
        vm.expectRevert(bytes("mint amount not in range"));
        issuer.addMintRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
    }

    function test_RedeemRange() public {
        address assetTokenAddress = test_Mint();
        AssetToken assetToken = AssetToken(assetTokenAddress);
        OrderInfo memory orderInfo = pmmQuoteRedeem();
        vm.startPrank(ap);
        assetToken.approve(assetIssuerProxy, orderInfo.order.inAmount);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 400 * 10 ** 8, max: 10000 * 10 ** 8})
        );
        vm.stopPrank();
        vm.startPrank(ap);
        vm.expectRevert(bytes("redeem amount not in range"));
        issuer.addRedeemRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 100 * 10 ** 8, max: 200 * 10 ** 8})
        );
        vm.stopPrank();
        vm.startPrank(ap);
        vm.expectRevert(bytes("redeem amount not in range"));
        issuer.addRedeemRequest(assetToken.id(), orderInfo);
        vm.stopPrank();
    }

    function test_RebalanceV2() public {
        Token[] memory tokenset_ = new Token[](2);
        tokenset_[0] = Token({
            chain: "TBSC_BNB",
            symbol: "TBSC_BNB",
            addr: "",
            decimals: 18,
            amount: 1412368749000018
        });
        tokenset_[1] = Token({
            chain: "SETH",
            symbol: "SETH",
            addr: "",
            decimals: 18,
            amount: 8379981918000000
        });
        Asset memory asset = Asset({
            id: 1,
            name: "ETHBNB",
            symbol: "ETHBNB",
            tokenset: tokenset_
        });
        maxFee = 10000;
        vm.startPrank(owner);
        address assetTokenAddress = factory.createAssetToken(
            asset,
            maxFee,
            assetIssuerProxy,
            assetRebalancerProxy,
            assetFeeManagerProxy
        );
        AssetToken assetToken = AssetToken(assetTokenAddress);
        issuer.setIssueFee(assetToken.id(), 10000);
        issuer.setIssueAmountRange(
            assetToken.id(),
            Range({min: 10 * 10 ** 8, max: 10000 * 10 ** 8})
        );
        vm.stopPrank();
        vm.startPrank(assetIssuerProxy);
        // vm.startPrank(owner);
        assetToken.mint(owner, 3313411);
        vm.stopPrank();
        string[] memory inAddressList = new string[](1);
        inAddressList[0] = "0xd1d1aDfD330B29D4ccF9E0d44E90c256Df597dc9";
        string[] memory outAddressList = new string[](1);
        outAddressList[0] = "0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63";
        Token[] memory inTokenset = new Token[](1);
        inTokenset[0] = Token({
            chain: "SETH",
            symbol: "SETH",
            addr: "",
            decimals: 18,
            amount: 134694404446823
        });
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: "TBSC_BNB",
            symbol: "TBSC_BNB",
            addr: "",
            decimals: 18,
            amount: 800375696545671
        });
        OrderInfo memory orderInfo = OrderInfo({
            order: Order({
                maker: 0xd1d1aDfD330B29D4ccF9E0d44E90c256Df597dc9,
                nonce: 1719484311801267893,
                inTokenset: inTokenset,
                outTokenset: outTokenset,
                inAddressList: inAddressList,
                outAddressList: outAddressList,
                inAmount: 100000000,
                outAmount: 98168567,
                deadline: 1719484491
            }),
            orderHash: 0xfefb8341af95c9457ef2c7bdab4bd01e5f41ffd54321238cf5dd31c7457b62a4,
            orderSign: hex"0bded5d095698775f2dd97f849e433de34bddb7080fcd49c0737641a3a95837e15db118736cc131293bff2fad70c8fe66de7229a2f08bb50b37a7a9dc352bc1d1b"
        });
        vm.startPrank(owner);
        swap.grantRole(
            swap.MAKER_ROLE(),
            0xd1d1aDfD330B29D4ccF9E0d44E90c256Df597dc9
        );
        rebalancer.addRebalanceRequest(
            assetToken.id(),
            assetToken.getBasket(),
            orderInfo
        );
        vm.stopPrank();
    }

    function test_SwapTakerAddress() public {
        vm.startPrank(owner);
        string[] memory receiverAddressList = new string[](2);
        receiverAddressList[0] = "0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63";
        receiverAddressList[1] = "0xe224fb2f5557a869e66d13a709093de8cdf99129";
        string[] memory senderAddressList = new string[](2);
        senderAddressList[0] = "0xe224fb2f5557a869e66d13a709093de8cdf99129";
        senderAddressList[1] = "0xc9b6174bDF1deE9Ba42Af97855Da322b91755E63";
        swap.setTakerAddresses(receiverAddressList, senderAddressList);
        (string[] memory receivers, string[] memory senders) = swap
            .getTakerAddresses();
        assertEq(abi.encode(receiverAddressList), abi.encode(receivers));
        assertEq(abi.encode(senderAddressList), abi.encode(senders));
    }

    function test_Swap() public {
        OrderInfo memory orderInfo = pmmQuoteMint();
        vm.startPrank(assetIssuerProxy);
        // vm.startPrank(owner);
        swap.addSwapRequest(orderInfo, false, false);
        vm.stopPrank();
    }

    function test_rollback() public {
        address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = pmmQuoteMint();
        apAddMintRequest(assetTokenAddress, orderInfo);
        vm.startPrank(pmm);
        bytes[] memory outTxHashs = new bytes[](1);
        outTxHashs[0] = "outTxhash";
        swap.makerConfirmSwapRequest(orderInfo, outTxHashs);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.rollbackSwapRequest(orderInfo);
        vm.stopPrank();
        SwapRequest memory swapRequest = swap.getSwapRequest(
            orderInfo.orderHash
        );
        assertTrue(swapRequest.status == SwapRequestStatus.PENDING);
    }

    function test_withdraw() public {
        WETH.mint(owner, 10 ** 18);
        vm.startPrank(owner);
        WETH.transfer(assetIssuerProxy, 10 ** 18);
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(WETH);
        tokenAddresses[1] = address(0);
        issuer.withdraw(tokenAddresses);
        assertEq(WETH.balanceOf(owner), 10 ** 18);
        vm.stopPrank();
        address assetTokenAddress = createAssetToken();
        OrderInfo memory orderInfo = pmmQuoteMint();
        (uint nonce, ) = apAddMintRequest(assetTokenAddress, orderInfo);
        vm.startPrank(owner);
        WETH.transfer(assetIssuerProxy, 10 ** 18);
        vm.expectRevert();
        issuer.withdraw(tokenAddresses);
        vm.stopPrank();
        vm.startPrank(pmm);
        swap.makerRejectSwapRequest(orderInfo);
        vm.stopPrank();
        vm.startPrank(owner);
        issuer.rejectMintRequest(nonce, orderInfo);
        issuer.withdraw(tokenAddresses);
        assertEq(WETH.balanceOf(owner), 10 ** 18);
    }

    function test_upgradeAssetToken() public {
        address assetTokenAddress = createAssetToken();
        uint assetID = factory.getAssetIDs()[0];

        vm.startPrank(owner);
        (
            address oldImplementation,
            address newImplementation,
            address oldProxyAdmin,
            address newProxyAdmin
        ) = factory.upgradeAssetToken(assetID, "AssetToken.sol");
        vm.stopPrank();
        assertFalse(
            oldImplementation == newImplementation,
            "Implementation address should change after upgrade"
        );
        assertEq(
            oldProxyAdmin,
            newProxyAdmin,
            "Proxy admin address should remain the same"
        );
    }

    function test_BurnFor() public {
        address tokenAddress = test_Mint();
        IAssetToken token = IAssetToken(tokenAddress);
        vm.startPrank(ap);
        token.approve(address(issuer), token.balanceOf(ap));
        issuer.burnFor(token.id(), token.balanceOf(ap));
        vm.stopPrank();
        assertEq(token.balanceOf(ap), 0);
        assertEq(token.balanceOf(address(issuer)), 0);
        Token[] memory tokens = token.getBasket();
        assertEq(tokens.length, 0);
    }
}
