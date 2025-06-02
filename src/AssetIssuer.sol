// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import "./Interface.sol";
import {AssetController} from "./AssetController.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Utils} from './Utils.sol';

// import "forge-std/console.sol";

contract AssetIssuer is AssetController, IAssetIssuer {
    using SafeERC20 for IERC20;
    using SafeERC20 for IAssetToken;
    // participians
    using EnumerableSet for EnumerableSet.AddressSet;
    mapping(uint256 assetID => EnumerableSet.AddressSet) private _participants;
    using EnumerableMap for EnumerableMap.UintToUintMap;
    // issue fee
    EnumerableMap.UintToUintMap private _issueFees;
    // issue min amount
    EnumerableMap.UintToUintMap private _minAmounts;
    // issue max amount
    EnumerableMap.UintToUintMap private _maxAmounts;

    Request[] mintRequests;
    Request[] redeemRequests;

    uint256 public constant feeDecimals = 8;

    mapping(address => mapping(address => uint256)) public claimables;
    mapping(address => uint256) public tokenClaimables;

    event SetIssueAmountRange(uint indexed assetID, uint min, uint max);
    event SetIssueFee(uint indexed assetID, uint issueFee);
    event AddParticipant(uint indexed assetID, address participant);
    event RemoveParticipant(uint indexed assetID, address participant);
    event AddMintRequest(uint nonce);
    event RejectMintRequest(uint nonce, bool force);
    event ConfirmMintRequest(uint nonce);
    event AddRedeemRequest(uint nonce);
    event RejectRedeemRequest(uint nonce);
    event ConfirmRedeemRequest(uint nonce, bool force);
    event CancelMintRequest(uint nonce, bool force);
    event CancelRedeemRequest(uint nonce);

    function getIssueAmountRange(uint256 assetID) external view returns (Range memory) {
        require(_minAmounts.contains(assetID) && _maxAmounts.contains(assetID), "issue amount range not set");
        return Range({
            min: _minAmounts.get(assetID),
            max: _maxAmounts.get(assetID)
        });
    }

    function setIssueAmountRange(uint256 assetID, Range calldata issueAmountRange) external onlyOwner {
        require(issueAmountRange.min <= issueAmountRange.max && issueAmountRange.max > 0 && issueAmountRange.min > 0, "wrong range");
        _minAmounts.set(assetID, issueAmountRange.min);
        _maxAmounts.set(assetID, issueAmountRange.max);
        emit SetIssueAmountRange(assetID, _minAmounts.get(assetID), _maxAmounts.get(assetID));
    }

    function getIssueFee(uint256 assetID) external view returns (uint256) {
        require(_issueFees.contains(assetID), "issue fee not set");
        return _issueFees.get(assetID);
    }

    function setIssueFee(uint256 assetID, uint256 issueFee) external onlyOwner {
        require(issueFee < 10**feeDecimals, "issueFee should less than 1");
        _issueFees.set(assetID, issueFee);
        emit SetIssueFee(assetID, _issueFees.get(assetID));
    }

    // mint
    function getMintRequestLength() external view returns (uint256) {
        return mintRequests.length;
    }

    function getMintRequest(uint256 nonce) external view returns (Request memory) {
        return mintRequests[nonce];
    }

    function addMintRequest(uint256 assetID, OrderInfo memory orderInfo, uint256 maxIssueFee) external whenNotPaused returns (uint) {
        require(_issueFees.get(assetID) <= maxIssueFee, "current issue fee larger than max issue fee");
        require(orderInfo.order.requester == msg.sender, "msg sender not order requester");
        require(_participants[assetID].contains(msg.sender), "msg sender not a participant");
        require(_minAmounts.contains(assetID) && _maxAmounts.contains(assetID), "issue amount range not set");
        require(_issueFees.contains(assetID), "issue fee not set");
        IAssetFactory factory = IAssetFactory(factoryAddress);
        address assetTokenAddress = factory.assetTokens(assetID);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        address swapAddress = factory.swaps(assetID);
        ISwap swap = ISwap(swapAddress);
        require(assetToken.feeCollected(), "has fee not collect");
        require(assetToken.rebalancing() == false, "is rebalancing");
        require(swap.checkOrderInfo(orderInfo) == 0, "order not valid");
        Order memory order = orderInfo.order;
        require(keccak256(abi.encode(assetToken.getTokenset())) == keccak256(abi.encode(order.outTokenset)), "tokenset not match");
        require(order.outAmount >= _minAmounts.get(assetID) && order.outAmount <= _maxAmounts.get(assetID), "mint amount not in range");
        Token[] memory inTokenset = order.inTokenset;
        uint256 issueFee = _issueFees.get(assetID);
        mintRequests.push(Request({
            nonce: mintRequests.length,
            requester: msg.sender,
            assetTokenAddress: assetTokenAddress,
            amount: order.outAmount,
            swapAddress: swapAddress,
            orderHash: orderInfo.orderHash,
            status: RequestStatus.PENDING,
            requestTimestamp: block.timestamp,
            issueFee: issueFee
        }));
        for (uint i = 0; i < inTokenset.length; i++) {
            require(keccak256(bytes(inTokenset[i].chain)) == keccak256(bytes(factory.chain())), "chain not match");
            address tokenAddress = Utils.stringToAddress(inTokenset[i].addr);
            IERC20 inToken = IERC20(tokenAddress);
            uint inTokenAmount = inTokenset[i].amount * order.inAmount / 10**8;
            uint feeTokenAmount = inTokenAmount * issueFee / 10**feeDecimals;
            uint transferAmount = inTokenAmount + feeTokenAmount;
            require(inToken.balanceOf(msg.sender) >= transferAmount, "not enough balance");
            require(inToken.allowance(msg.sender, address(this)) >= transferAmount, "not enough allowance");
            inToken.safeTransferFrom(msg.sender, address(this), transferAmount);
        }
        swap.addSwapRequest(orderInfo, true, false);
        assetToken.lockIssue();
        emit AddMintRequest(mintRequests.length - 1);
        return mintRequests.length - 1;
    }

    // function cancelMintRequest(uint nonce, OrderInfo memory orderInfo, bool force) external whenNotPaused {
    //     require(orderInfo.order.requester == msg.sender, "not order requester");
    //     require(nonce < mintRequests.length, "nonce too large");
    //     Request memory mintRequest = mintRequests[nonce];
    //     checkRequestOrderInfo(mintRequest, orderInfo);
    //     require(mintRequest.status == RequestStatus.PENDING);
    //     ISwap swap = ISwap(mintRequest.swapAddress);
    //     swap.cancelSwapRequest(orderInfo);
    //     mintRequests[nonce].status = RequestStatus.CANCEL;
    //     Order memory order = orderInfo.order;
    //     Token[] memory inTokenset = order.inTokenset;
    //     IAssetFactory factory = IAssetFactory(factoryAddress);
    //     for (uint i = 0; i < inTokenset.length; i++) {
    //         require(keccak256(bytes(inTokenset[i].chain)) == keccak256(bytes(factory.chain())), "chain not match");
    //         address tokenAddress = Utils.stringToAddress(inTokenset[i].addr);
    //         IERC20 inToken = IERC20(tokenAddress);
    //         uint inTokenAmount = inTokenset[i].amount * order.inAmount / 10**8;
    //         uint feeTokenAmount = inTokenAmount * mintRequest.issueFee / 10**feeDecimals;
    //         uint transferAmount = inTokenAmount + feeTokenAmount;
    //         require(inToken.balanceOf(address(this)) >= transferAmount, "not enough balance");
    //         if (!force) {
    //             inToken.safeTransfer(mintRequest.requester, transferAmount);
    //         } else {
    //             claimables[tokenAddress][mintRequest.requester] += transferAmount;
    //             tokenClaimables[tokenAddress] += transferAmount;
    //         }
    //     }
    //     IAssetToken assetToken = IAssetToken(mintRequest.assetTokenAddress);
    //     assetToken.unlockIssue();
    //     emit CancelMintRequest(nonce, force);
    // }

    function rejectMintRequest(uint nonce, OrderInfo memory orderInfo, bool force) external onlyOwner {
        require(nonce < mintRequests.length, "nonce too large");
        Request memory mintRequest = mintRequests[nonce];
        checkRequestOrderInfo(mintRequest, orderInfo);
        require(mintRequest.status == RequestStatus.PENDING);
        ISwap swap = ISwap(mintRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(mintRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.REJECTED || swapRequest.status == SwapRequestStatus.CANCEL || swapRequest.status == SwapRequestStatus.FORCE_CANCEL, "swap request is not rejected/cancelled/force cancelled");  
        mintRequests[nonce].status = RequestStatus.REJECTED;
        Order memory order = orderInfo.order;
        Token[] memory inTokenset = order.inTokenset;
        IAssetFactory factory = IAssetFactory(factoryAddress);
        for (uint i = 0; i < inTokenset.length; i++) {
            require(keccak256(bytes(inTokenset[i].chain)) == keccak256(bytes(factory.chain())), "chain not match");
            address tokenAddress = Utils.stringToAddress(inTokenset[i].addr);
            IERC20 inToken = IERC20(tokenAddress);
            uint inTokenAmount = inTokenset[i].amount * order.inAmount / 10**8;
            uint feeTokenAmount = inTokenAmount * mintRequest.issueFee / 10**feeDecimals;
            uint transferAmount = inTokenAmount + feeTokenAmount;
            require(inToken.balanceOf(address(this)) >= transferAmount, "not enough balance");
            if (!force) {
                inToken.safeTransfer(mintRequest.requester, transferAmount);
            } else {
                claimables[tokenAddress][mintRequest.requester] += transferAmount;
                tokenClaimables[tokenAddress] += transferAmount;
            }
        }
        IAssetToken assetToken = IAssetToken(mintRequest.assetTokenAddress);
        assetToken.unlockIssue();
        emit RejectMintRequest(nonce, force);
    }

    function confirmMintRequest(uint nonce, OrderInfo memory orderInfo, bytes[] memory inTxHashs) external onlyOwner {
        require(nonce < mintRequests.length, "nonce too large");
        Request memory mintRequest = mintRequests[nonce];
        checkRequestOrderInfo(mintRequest, orderInfo);
        require(mintRequest.status == RequestStatus.PENDING);
        ISwap swap = ISwap(mintRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(mintRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.MAKER_CONFIRMED);
        mintRequests[nonce].status = RequestStatus.CONFIRMED;
        for (uint i = 0; i < orderInfo.order.inTokenset.length; i++) {
            address tokenAddress = Utils.stringToAddress(orderInfo.order.inTokenset[i].addr);
            IERC20(tokenAddress).forceApprove(address(swap), orderInfo.order.inTokenset[i].amount * orderInfo.order.inAmount / 10**8);
        }
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        Token[] memory inTokenset = orderInfo.order.inTokenset;
        IAssetFactory factory = IAssetFactory(factoryAddress);
        address vault = factory.vault();
        string memory chain = factory.chain();
        Order memory order = orderInfo.order;
        for (uint i = 0; i < inTokenset.length; i++) {
            require(keccak256(bytes(inTokenset[i].chain)) == keccak256(bytes(chain)), "chain not match");
            address tokenAddress = Utils.stringToAddress(inTokenset[i].addr);
            IERC20 inToken = IERC20(tokenAddress);
            uint inTokenAmount = inTokenset[i].amount * order.inAmount / 10**8;
            uint feeTokenAmount = inTokenAmount * mintRequest.issueFee / 10**feeDecimals;
            if (feeTokenAmount > 0) {
                require(inToken.balanceOf(address(this)) >= feeTokenAmount, "not enough balance");
                inToken.safeTransfer(vault, feeTokenAmount);
            }
        }
        IAssetToken assetToken = IAssetToken(mintRequest.assetTokenAddress);
        assetToken.mint(mintRequest.requester, mintRequest.amount);
        assetToken.unlockIssue();
        emit ConfirmMintRequest(nonce);
    }

    // redeem

    function getRedeemRequestLength() external view returns (uint256) {
        return redeemRequests.length;
    }

    function getRedeemRequest(uint256 nonce) external view returns (Request memory) {
        return redeemRequests[nonce];
    }

    function addRedeemRequest(uint256 assetID, OrderInfo memory orderInfo, uint256 maxIssueFee) external whenNotPaused returns (uint256) {
        require(_issueFees.get(assetID) <= maxIssueFee, "current issue fee larger than max issue fee");
        require(orderInfo.order.requester == msg.sender, "msg sender not order requester");
        require(_participants[assetID].contains(msg.sender), "msg sender not a participant");
        require(_minAmounts.contains(assetID) && _maxAmounts.contains(assetID), "issue amount range not set");
        require(_issueFees.contains(assetID), "issue fee not set");
        IAssetFactory factory = IAssetFactory(factoryAddress);
        address assetTokenAddress = factory.assetTokens(assetID);
        IAssetToken assetToken = IAssetToken(assetTokenAddress);
        address swapAddress = factory.swaps(assetID);
        ISwap swap = ISwap(swapAddress);
        require(assetToken.hasRole(assetToken.ISSUER_ROLE(), address(this)), "not a issuer");
        require(assetToken.feeCollected(), "has fee not collect");
        require(assetToken.rebalancing() == false, "is rebalancing");
        require(swap.checkOrderInfo(orderInfo) == 0, "order not valid");
        Order memory order = orderInfo.order;
        require(keccak256(abi.encode(assetToken.getTokenset())) == keccak256(abi.encode(order.inTokenset)), "tokenset not match");
        require(order.inAmount >= _minAmounts.get(assetID) && order.inAmount <= _maxAmounts.get(assetID), "redeem amount not in range");
        require(assetToken.balanceOf(msg.sender) >= order.inAmount, "not enough asset token balance");
        require(assetToken.allowance(msg.sender, address(this)) >= order.inAmount, "not enough asset token allowance");
        Token[] memory outTokenset = order.outTokenset;
        for (uint i = 0; i < outTokenset.length; i++) {
            require(keccak256(bytes(outTokenset[i].chain)) == keccak256(bytes(factory.chain())), "chain not match");
            require(Utils.stringToAddress(order.outAddressList[i]) == address(this), "out address not valid");
        }
        redeemRequests.push(Request({
            nonce: redeemRequests.length,
            requester: msg.sender,
            assetTokenAddress: assetTokenAddress,
            amount: order.inAmount,
            swapAddress: swapAddress,
            orderHash: orderInfo.orderHash,
            status: RequestStatus.PENDING,
            requestTimestamp: block.timestamp,
            issueFee: _issueFees.get(assetID)
        }));
        assetToken.safeTransferFrom(msg.sender, address(this), order.inAmount);
        swap.addSwapRequest(orderInfo, false, true);
        assetToken.lockIssue();
        emit AddRedeemRequest(redeemRequests.length - 1);
        return redeemRequests.length - 1;
    }

    // function cancelRedeemRequest(uint nonce, OrderInfo memory orderInfo) external whenNotPaused {
    //     require(orderInfo.order.requester == msg.sender, "not order requester");
    //     require(nonce < redeemRequests.length, "nonce too large");
    //     Request memory redeemRequest = redeemRequests[nonce];
    //     checkRequestOrderInfo(redeemRequest, orderInfo);
    //     require(redeemRequest.status == RequestStatus.PENDING, "redeem request is not pending");
    //     ISwap swap = ISwap(redeemRequest.swapAddress);
    //     swap.cancelSwapRequest(orderInfo);
    //     redeemRequests[nonce].status = RequestStatus.CANCEL;
    //     IAssetToken assetToken = IAssetToken(redeemRequest.assetTokenAddress);
    //     assetToken.safeTransfer(redeemRequest.requester, redeemRequest.amount);
    //     assetToken.unlockIssue();
    //     emit CancelRedeemRequest(nonce);
    // }

    function rejectRedeemRequest(uint nonce) external onlyOwner {
        require(nonce < redeemRequests.length, "nonce too large");
        Request memory redeemRequest = redeemRequests[nonce];
        require(redeemRequest.status == RequestStatus.PENDING, "redeem request is not pending");
        ISwap swap = ISwap(redeemRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(redeemRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.REJECTED || swapRequest.status == SwapRequestStatus.CANCEL || swapRequest.status == SwapRequestStatus.FORCE_CANCEL, "swap request is not rejected/cancelled/force cancelled");
        IAssetToken assetToken = IAssetToken(redeemRequest.assetTokenAddress);
        require(assetToken.balanceOf(address(this)) >= redeemRequest.amount, "not enough asset token to transfer");
        redeemRequests[nonce].status = RequestStatus.REJECTED;
        assetToken.safeTransfer(redeemRequest.requester, redeemRequest.amount);
        assetToken.unlockIssue();
        emit RejectRedeemRequest(nonce);
    }

    function confirmRedeemRequest(uint nonce, OrderInfo memory orderInfo, bytes[] memory inTxHashs, bool force) external onlyOwner {
        require(nonce < redeemRequests.length, "nonce too large");
        Request memory redeemRequest = redeemRequests[nonce];
        checkRequestOrderInfo(redeemRequest, orderInfo);
        require(redeemRequest.status == RequestStatus.PENDING);
        ISwap swap = ISwap(redeemRequest.swapAddress);
        SwapRequest memory swapRequest = swap.getSwapRequest(redeemRequest.orderHash);
        require(swapRequest.status == SwapRequestStatus.MAKER_CONFIRMED);
        redeemRequests[nonce].status = RequestStatus.CONFIRMED;
        swap.confirmSwapRequest(orderInfo, inTxHashs);
        IAssetToken assetToken = IAssetToken(redeemRequest.assetTokenAddress);
        require(assetToken.balanceOf(address(this)) >= redeemRequest.amount, "not enough asset token to burn");
        Order memory order = orderInfo.order;
        Token[] memory outTokenset = order.outTokenset;
        address vault = IAssetFactory(factoryAddress).vault();
        for (uint i = 0; i < outTokenset.length; i++) {
            address tokenAddress = Utils.stringToAddress(outTokenset[i].addr);
            IERC20 outToken = IERC20(tokenAddress);
            uint outTokenAmount = outTokenset[i].amount * order.outAmount / 10**8;
            uint feeTokenAmount = outTokenAmount * redeemRequest.issueFee / 10**feeDecimals;
            uint transferAmount = outTokenAmount - feeTokenAmount;
            require(outToken.balanceOf(address(this)) >= outTokenAmount, "not enough balance");
            if (!force) {
                outToken.safeTransfer(redeemRequest.requester, transferAmount);
            } else {
                claimables[tokenAddress][redeemRequest.requester] += transferAmount;
                tokenClaimables[tokenAddress] += transferAmount;
            }
            outToken.safeTransfer(vault, feeTokenAmount);
        }
        assetToken.burn(redeemRequest.amount);
        assetToken.unlockIssue();
        emit ConfirmRedeemRequest(nonce, force);
    }

    function isParticipant(uint256 assetID, address participant) external view returns (bool) {
        return _participants[assetID].contains(participant);
    }

    function getParticipants(uint256 assetID) external view returns (address[] memory) {
        address[] memory participants = new address[](_participants[assetID].length());
        for (uint i = 0; i < participants.length; i++) {
            participants[i] = _participants[assetID].at(i);
        }
        return participants;
    }

    function getParticipantLength(uint256 assetID) external view returns (uint256) {
        return _participants[assetID].length();
    }

    function getParticipant(uint256 assetID, uint256 idx) external view returns (address) {
        require(idx < _participants[assetID].length(), "out of range");
        return _participants[assetID].at(idx);
    }

    function addParticipant(uint256 assetID, address participant) external onlyOwner {
        if (_participants[assetID].add(participant)) {
            emit AddParticipant(assetID, participant);
        }
    }

    function removeParticipant(uint256 assetID, address participant) external onlyOwner {
        if (_participants[assetID].remove(participant)) {
            emit RemoveParticipant(assetID, participant);
        }
    }

    function withdraw(address[] memory tokenAddresses) external onlyOwner {
        IAssetFactory factory = IAssetFactory(factoryAddress);
        uint256[] memory assetIDs = factory.getAssetIDs();
        for (uint i = 0; i < assetIDs.length; i++) {
            IAssetToken assetToken = IAssetToken(factory.assetTokens(assetIDs[i]));
            require(!assetToken.issuing(), "is issuing");
        }
        for (uint i = 0; i < tokenAddresses.length; i++) {
            address tokenAddress = tokenAddresses[i];
            if (tokenAddress != address(0)) {
                IERC20 token = IERC20(tokenAddress);
                if (token.balanceOf(address(this)) > tokenClaimables[tokenAddress]) {
                    token.safeTransfer(owner(), token.balanceOf(address(this)) - tokenClaimables[tokenAddress]);
                }
            }
        }
    }

    function burnFor(uint256 assetID, uint256 amount) external whenNotPaused {
        IAssetFactory factory = IAssetFactory(factoryAddress);
        IAssetToken assetToken = IAssetToken(factory.assetTokens(assetID));
        require(assetToken.allowance(msg.sender, address(this)) >= amount, "not enough allowance");
        require(assetToken.feeCollected(), "asset token has fee not collected");
        assetToken.lockIssue();
        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        assetToken.burn(amount);
        assetToken.unlockIssue();
    }

    function claim(address token) external whenNotPaused {
        require(claimables[token][msg.sender] > 0, "nothing to claim");
        uint256 amount = claimables[token][msg.sender];
        claimables[token][msg.sender] = 0;
        tokenClaimables[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}