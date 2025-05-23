// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import "./Interface.sol";
import {AssetController} from "./AssetController.sol";
import {Utils} from './Utils.sol';

// import "forge-std/console.sol";

contract AssetRebalancer is AssetController, IAssetRebalancer {
    Request[] rebalanceRequests;

    event AddRebalanceRequest(uint nonce);
    event RejectRebalanceRequest(uint nonce);
    event ConfirmRebalanceRequest(uint nonce);

    // rebalance

    function getRebalanceRequestLength() external view returns (uint256) {
        return rebalanceRequests.length;
    }

    function getRebalanceRequest(uint256 nonce) external view returns (Request memory) {
        return rebalanceRequests[nonce];
    }

    function addRebalanceRequest(uint256 assetID, Token[] memory basket, OrderInfo memory orderInfo) external onlyOwner returns (uint256) {
        IAssetFactory factory = IAssetFactory(factoryAddress);
        address assetTokenAddress = factory.assetTokens(assetID);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        address swapAddress = factory.swaps(assetID);
        ISwap swap = ISwap(swapAddress);
        require(assetToken.totalSupply() > 0, "zero supply");
        require(assetToken.feeCollected(), "has fee not collect");
        require(assetToken.hasRole(assetToken.REBALANCER_ROLE(), address(this)), "not a rebalancer");
        require(assetToken.rebalancing() == false, "is rebalancing");
        require(assetToken.issuing() == false, "is issuing");
        require(swap.checkOrderInfo(orderInfo) == 0, "order not valid");
        require(keccak256(abi.encode(assetToken.getBasket())) == keccak256(abi.encode(basket)), "underlying basket not match");
        Utils.validateTokenset(orderInfo.order.inTokenset);
        Utils.validateTokenset(orderInfo.order.outTokenset);
        Token[] memory inBasket = Utils.muldivTokenset(orderInfo.order.outTokenset, orderInfo.order.outAmount, 10**8);
        Token[] memory outBasket = Utils.muldivTokenset(orderInfo.order.inTokenset, orderInfo.order.inAmount, 10**8);
        require(Utils.containTokenset(basket, outBasket), "not enough balance to sell");
        Token[] memory newBasket = Utils.addTokenset(Utils.subTokenset(basket, outBasket), inBasket);
        Token[] memory newTokenset = Utils.muldivTokenset(newBasket, 10**assetToken.decimals(), assetToken.totalSupply());
        for (uint i = 0; i < newTokenset.length; i++) {
            require(newTokenset[i].amount > 0, "zero token in new tokenset");
        }
        require(!Utils.hasDuplicates(newTokenset), "duplicated tokens in new tokenset");
        rebalanceRequests.push(Request({
            nonce: rebalanceRequests.length,
            requester: msg.sender,
            assetTokenAddress: assetTokenAddress,
            amount: 0,
            swapAddress: swapAddress,
            orderHash: orderInfo.orderHash,
            status: RequestStatus.PENDING,
            requestTimestamp: block.timestamp,
            issueFee: 0
        }));
        swap.addSwapRequest(orderInfo, false, false);
        assetToken.lockRebalance();
        emit AddRebalanceRequest(rebalanceRequests.length - 1);
        return rebalanceRequests.length - 1;
    }

    function rejectRebalanceRequest(uint nonce) external onlyOwner {
        require(nonce < rebalanceRequests.length, "nonce too large");
        Request memory rebalanceRequest = rebalanceRequests[nonce];
        require(rebalanceRequest.status == RequestStatus.PENDING);
        ISwap swap = ISwap(rebalanceRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(rebalanceRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.REJECTED || swapRequest.status == SwapRequestStatus.CANCEL || swapRequest.status == SwapRequestStatus.FORCE_CANCEL);
        rebalanceRequests[nonce].status = RequestStatus.REJECTED;
        IAssetToken assetToken = IAssetToken(rebalanceRequest.assetTokenAddress);
        assetToken.unlockRebalance();
        emit RejectRebalanceRequest(nonce);
    }

    function confirmRebalanceRequest(uint nonce, OrderInfo memory orderInfo, bytes[] memory inTxHashs) external onlyOwner {
        require(nonce < rebalanceRequests.length, "nonce too large");
        Request memory rebalanceRequest = rebalanceRequests[nonce];
        checkRequestOrderInfo(rebalanceRequest, orderInfo);
        require(rebalanceRequest.status == RequestStatus.PENDING);
        ISwap swap = ISwap(rebalanceRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(rebalanceRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.MAKER_CONFIRMED);
        rebalanceRequests[nonce].status = RequestStatus.CONFIRMED;
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        Order memory order = orderInfo.order;
        Token[] memory inBasket = Utils.muldivTokenset(order.outTokenset, order.outAmount, 10**8);
        Token[] memory outBasket = Utils.muldivTokenset(order.inTokenset, order.inAmount, 10**8);
        IAssetToken assetToken = IAssetToken(rebalanceRequest.assetTokenAddress);
        assetToken.rebalance(inBasket, outBasket);
        assetToken.unlockRebalance();
        emit ConfirmRebalanceRequest(nonce);
    }
}