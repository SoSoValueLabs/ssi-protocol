// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import './Interface.sol';
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Utils} from './Utils.sol';

contract Swap is Initializable, UUPSUpgradeable, PausableUpgradeable, AccessControlUpgradeable, ISwap {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    string public chain;
    EnumerableSet.Bytes32Set orderHashs;
    mapping(bytes32 => SwapRequest) swapRequests;

    bytes32 public constant TAKER_ROLE = keccak256("TAKER_ROLE");
    bytes32 public constant MAKER_ROLE = keccak256("MAKER_ROLE");

    mapping(string => bool) outWhiteAddresses;
    string[] public takerReceivers;
    string[] public takerSenders;

    uint256 public constant MAX_MARKER_CONFIRM_DELAY = 1 hours;
    uint256 public constant EXPIRATION = 1 hours;

    EnumerableSet.Bytes32Set whiteListTokenHashs;
    mapping(bytes32 => Token) public whiteListTokens;

    event AddSwapRequest(address indexed taker, bool inByContract, bool outByContract, OrderInfo orderInfo);
    event MakerConfirmSwapRequest(address indexed maker, bytes32 orderHash);
    event ConfirmSwapRequest(address indexed taker, bytes32 orderHash);
    event MakerRejectSwapRequest(address indexed maker, bytes32 orderHash);
    event RollbackSwapRequest(address indexed taker, bytes32 orderHash);
    event SetTakerAddresses(string[] receivers, string[] senders);
    event CancelSwapRequest(address indexed taker, bytes32 orderHash);
    event ForceCancelSwapRequest(bytes32 orderHash);
    event AddWhiteListToken(Token token);
    event RemoveWhiteListToken(Token token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner,
        string memory chain_
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        chain = chain_;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function checkOrderInfo(OrderInfo memory orderInfo) public view returns (uint) {
        if (block.timestamp >= orderInfo.order.deadline) {
            return 1;
        }
        bytes32 orderHash = keccak256(abi.encode(orderInfo.order));
        if (orderHash != orderInfo.orderHash) {
            return 2;
        }
        if (!SignatureChecker.isValidSignatureNow(orderInfo.order.maker, orderHash, orderInfo.orderSign)) {
            return 3;
        }
        if (orderHashs.contains(orderHash)) {
            return 4;
        }
        if (orderInfo.order.inAddressList.length != orderInfo.order.inTokenset.length) {
            return 5;
        }
        if (orderInfo.order.outAddressList.length != orderInfo.order.outTokenset.length) {
            return 6;
        }
        if (!hasRole(MAKER_ROLE, orderInfo.order.maker)) {
            return 7;
        }
        for (uint i = 0; i < orderInfo.order.outAddressList.length; i++) {
            if (!outWhiteAddresses[orderInfo.order.outAddressList[i]]) {
                return 8;
            }
        }
        if (keccak256(abi.encode(orderInfo.order.chain)) != keccak256(abi.encode(chain))) {
            return 9;
        }
        for (uint i = 0; i < orderInfo.order.inTokenset.length; i++) {
            if (!whiteListTokenHashs.contains(Utils.calcTokenHash(orderInfo.order.inTokenset[i]))) {
                return 10;
            }
        }
        for (uint i = 0; i < orderInfo.order.outTokenset.length; i++) {
            if (!whiteListTokenHashs.contains(Utils.calcTokenHash(orderInfo.order.outTokenset[i]))) {
                return 11;
            }
        }
        return 0;
    }

    function validateOrderInfo(OrderInfo memory orderInfo) internal view {
        require(orderHashs.contains(orderInfo.orderHash), "order hash not exists");
        require(orderInfo.orderHash == keccak256(abi.encode(orderInfo.order)), "order hash invalid");
    }

    function getOrderHashs() external view returns (bytes32[] memory) {
        return orderHashs.values();
    }

    function getOrderHashLength() external view returns (uint256) {
        return orderHashs.length();
    }

    function getOrderHash(uint256 idx) external view returns (bytes32) {
        require(idx < orderHashs.length(), "out of range");
        return orderHashs.at(idx);
    }

    function checkTokenset(Token[] memory tokenset, string[] memory addressList) internal view {
        require(tokenset.length == addressList.length, "tokenset length not match addressList length");
        for (uint i = 0; i < tokenset.length; i++) {
            require(keccak256(bytes(tokenset[i].chain)) == keccak256(bytes(chain)), "chain not match");
            address tokenAddress = Utils.stringToAddress(tokenset[i].addr);
            require(tokenAddress != address(0), "zero token address");
            address receiveAddress = Utils.stringToAddress(addressList[i]);
            require(receiveAddress != address(0), "zero receive address");
        }
    }

    function addSwapRequest(OrderInfo memory orderInfo, bool inByContract, bool outByContract) external onlyRole(TAKER_ROLE) whenNotPaused {
        uint code = checkOrderInfo(orderInfo);
        require(code == 0, "order not valid");
        swapRequests[orderInfo.orderHash].status = SwapRequestStatus.PENDING;
        swapRequests[orderInfo.orderHash].requester = msg.sender;
        orderHashs.add(orderInfo.orderHash);
        if (inByContract) {
            checkTokenset(orderInfo.order.inTokenset, orderInfo.order.inAddressList);
        }
        if (outByContract) {
            checkTokenset(orderInfo.order.outTokenset, orderInfo.order.outAddressList);
        }
        swapRequests[orderInfo.orderHash].inByContract = inByContract;
        swapRequests[orderInfo.orderHash].outByContract = outByContract;
        swapRequests[orderInfo.orderHash].blocknumber = block.number;
        swapRequests[orderInfo.orderHash].requestTimestamp = block.timestamp;
        emit AddSwapRequest(msg.sender, inByContract, outByContract, orderInfo);
    }

    function getSwapRequest(bytes32 orderHash) external view returns (SwapRequest memory) {
        return swapRequests[orderHash];
    }

    function cancelSwapRequest(OrderInfo memory orderInfo) external onlyRole(TAKER_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        require(swapRequests[orderHash].requester == msg.sender, "not order taker");
        require(swapRequests[orderHash].status == SwapRequestStatus.PENDING, "swap request status is not pending");
        require(swapRequests[orderHash].requestTimestamp + MAX_MARKER_CONFIRM_DELAY <= block.timestamp, "swap request not timeout");
        swapRequests[orderHash].status = SwapRequestStatus.CANCEL;
        swapRequests[orderHash].blocknumber = block.number;
        emit CancelSwapRequest(msg.sender, orderHash);
    }

    function forceCancelSwapRequest(OrderInfo memory orderInfo) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        require(swapRequests[orderHash].status == SwapRequestStatus.PENDING || swapRequests[orderHash].status == SwapRequestStatus.MAKER_CONFIRMED,
            "swap request status is not pending or maker confirmed");
        require(swapRequests[orderHash].requestTimestamp + EXPIRATION <= block.timestamp, "swap request not expired");
        swapRequests[orderHash].status = SwapRequestStatus.FORCE_CANCEL;
        swapRequests[orderHash].blocknumber = block.number;
        emit ForceCancelSwapRequest(orderHash);
    }

    function makerRejectSwapRequest(OrderInfo memory orderInfo) external onlyRole(MAKER_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        require(orderInfo.order.maker == msg.sender, "not order maker");
        require(swapRequests[orderHash].status == SwapRequestStatus.PENDING, "swap request status is not pending");
        swapRequests[orderHash].status = SwapRequestStatus.REJECTED;
        swapRequests[orderHash].blocknumber = block.number;
        emit MakerRejectSwapRequest(msg.sender, orderHash);
    }

    function transferTokenset(address from, Token[] memory tokenset, uint256 amount, string[] memory toAddressList) internal {
        for (uint i = 0; i < tokenset.length; i++) {
            address tokenAddress = Utils.stringToAddress(tokenset[i].addr);
            address to = Utils.stringToAddress(toAddressList[i]);
            IERC20 token = IERC20(tokenAddress);
            uint tokenAmount = tokenset[i].amount * amount / 10**8;
            require(token.balanceOf(from) >= tokenAmount, "not enough balance");
            require(token.allowance(from, address(this)) >= tokenAmount, "not enough allowance");
            token.safeTransferFrom(from, to, tokenAmount);
        }
    }

    function makerConfirmSwapRequest(OrderInfo memory orderInfo, bytes[] memory outTxHashs) external onlyRole(MAKER_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        SwapRequest memory swapRequest = swapRequests[orderHash];
        require(orderInfo.order.maker == msg.sender, "not order maker");
        require(swapRequest.status == SwapRequestStatus.PENDING, "status error");
        if (swapRequest.outByContract) {
            transferTokenset(msg.sender, orderInfo.order.outTokenset, orderInfo.order.outAmount, orderInfo.order.outAddressList);
        } else {
            require(orderInfo.order.outTokenset.length == outTxHashs.length, "wrong outTxHashs length");
            swapRequests[orderHash].outTxHashs = outTxHashs;
        }
        swapRequests[orderHash].status = SwapRequestStatus.MAKER_CONFIRMED;
        swapRequests[orderHash].blocknumber = block.number;
        emit MakerConfirmSwapRequest(msg.sender, orderHash);
    }

    function rollbackSwapRequest(OrderInfo memory orderInfo) external onlyRole(TAKER_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        require(swapRequests[orderHash].requester == msg.sender, "not order taker");
        require(swapRequests[orderHash].status == SwapRequestStatus.MAKER_CONFIRMED, "swap request status is not maker_confirmed");
        require(!swapRequests[orderHash].outByContract, "out by contract cannot rollback");
        swapRequests[orderHash].status = SwapRequestStatus.PENDING;
        swapRequests[orderHash].blocknumber = block.number;
        emit RollbackSwapRequest(msg.sender, orderHash);
    }

    function confirmSwapRequest(OrderInfo memory orderInfo, bytes[] memory inTxHashs) external onlyRole(TAKER_ROLE) whenNotPaused {
        validateOrderInfo(orderInfo);
        bytes32 orderHash = orderInfo.orderHash;
        SwapRequest memory swapRequest = swapRequests[orderHash];
        require(swapRequest.requester == msg.sender, "not order taker");
        require(swapRequest.status == SwapRequestStatus.MAKER_CONFIRMED, "status error");
         if (swapRequest.inByContract) {
            transferTokenset(msg.sender, orderInfo.order.inTokenset, orderInfo.order.inAmount, orderInfo.order.inAddressList);
        } else {
            require(orderInfo.order.inTokenset.length == inTxHashs.length, "wrong inTxHashs length");
            swapRequests[orderHash].inTxHashs = inTxHashs;
        }
        swapRequests[orderHash].status = SwapRequestStatus.CONFIRMED;
        swapRequests[orderHash].blocknumber = block.number;
        emit ConfirmSwapRequest(msg.sender, orderHash);
    }

    function setTakerAddresses(string[] memory takerReceivers_, string[] memory takerSenders_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i < takerReceivers.length; i++) {
            outWhiteAddresses[takerReceivers[i]] = false;
        }
        delete takerReceivers;
        for (uint i = 0; i < takerReceivers_.length; i++) {
            takerReceivers.push(takerReceivers_[i]);
            outWhiteAddresses[takerReceivers[i]] = true;
        }
        delete takerSenders;
        for (uint i = 0; i < takerSenders_.length; i++) {
            takerSenders.push(takerSenders_[i]);
        }
        emit SetTakerAddresses(takerReceivers, takerSenders);
    }

    function getTakerAddresses() external view returns (string[] memory receivers, string[] memory senders) {
        return (takerReceivers, takerSenders);
    }

    function addWhiteListTokens(Token[] memory tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i < tokens.length; i++) {
            bytes32 tokenHash = Utils.calcTokenHash(tokens[i]);
            if (whiteListTokenHashs.add(tokenHash)) {
                whiteListTokens[tokenHash].chain = tokens[i].chain;
                whiteListTokens[tokenHash].symbol = tokens[i].symbol;
                whiteListTokens[tokenHash].addr = tokens[i].addr;
                whiteListTokens[tokenHash].decimals = tokens[i].decimals;
                emit AddWhiteListToken(tokens[i]);
            }
        }
    }

    function removeWhiteListTokens(Token[] memory tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i < tokens.length; i++) {
            bytes32 tokenHash = Utils.calcTokenHash(tokens[i]);
            if (whiteListTokenHashs.remove(tokenHash)) {
                delete whiteListTokens[tokenHash];
                emit RemoveWhiteListToken(tokens[i]);
            }
        }
    }

    function getWhiteListTokens() external view returns (Token[] memory tokens) {
        tokens = new Token[](whiteListTokenHashs.length());
        for (uint i = 0; i < tokens.length; i++) {
            tokens[i] = whiteListTokens[whiteListTokenHashs.at(i)];
        }
    }

    function getWhiteListTokenLength() external view returns (uint256) {
        return whiteListTokenHashs.length();
    }

    function getWhiteListToken(uint256 nonce) external view returns (Token memory token) {
        return whiteListTokens[whiteListTokenHashs.at(nonce)];
    }
}
