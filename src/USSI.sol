// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import './Interface.sol';
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// import "forge-std/console.sol";

contract USSI is Initializable, OwnableUpgradeable, AccessControlUpgradeable, ERC20Upgradeable, UUPSUpgradeable, PausableUpgradeable {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    enum HedgeOrderType { NONE, MINT, REDEEM, TOKEN_MINT }
    enum HedgeOrderStatus { NONE, PENDING, REJECTED, CONFIRMED, CANCELED }

    struct HedgeOrder {
        string chain;
        HedgeOrderType orderType;
        uint256 assetID;
        address redeemToken;
        uint256 nonce;
        uint256 inAmount;
        uint256 outAmount;
        uint256 deadline;
        address requester;
        address receiver;
        address token;
        address vault;
    }

    EnumerableSet.Bytes32Set orderHashs;
    mapping(bytes32 => HedgeOrder) public hedgeOrders;
    mapping(bytes32 => HedgeOrderStatus) public orderStatus;
    mapping(bytes32 => uint256) public requestTimestamps;

    EnumerableSet.UintSet supportAssetIDs;

    address public redeemToken;
    address public orderSigner;
    address public factoryAddress;

    bytes32 public constant PARTICIPANT_ROLE = keccak256("PARTICIPANT_ROLE");

    mapping(bytes32 => bytes32) public redeemTxHashs;

    string public chain;

    uint256 public constant MAX_MINT_DELAY = 1 days;
    uint256 public constant MAX_REDEEM_DELAY = 7 days;

    EnumerableSet.AddressSet supportTokens;
    address public vault;
    mapping(address => address) public vaultRoutes;
    EnumerableSet.AddressSet routeRequesters;
    mapping(address => uint256) public mintPendingAmounts;
    mapping(address => uint256) public redeemPendingAmounts;

    event AddAssetID(uint256 assetID);
    event RemoveAssetID(uint256 assetID);
    event AddToken(address token);
    event RemoveToken(address token);
    event UpdateOrderSigner(address oldOrderSigner, address orderSigner);
    event UpdateRedeemToken(address oldRedeemToken, address redeemToken);
    event ApplyMint(HedgeOrder hedgeOrder);
    event RejectMint(bytes32 orderHash);
    event ConfirmMint(bytes32 orderHash);
    event ApplyRedeem(HedgeOrder hedgeOrder);
    event RejectRedeem(bytes32 orderHash);
    event ConfirmRedeem(bytes32 orderHash);
    event CancelMint(bytes32 orderHash);
    event CancelRedeem(bytes32 orderHash);
    event UpdateVault(address oldVault, address vault);
    event AddVaultRoute(address requester, address vault);
    event RemoveVaultRoute(address requester);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, address orderSigner_, address factoryAddress_, address redeemToken_, string memory chain_) public initializer {
        __Ownable_init(owner);
        __AccessControl_init();
        __ERC20_init("USSI", "USSI");
        __UUPSUpgradeable_init();
        __Pausable_init();
        require(factoryAddress_ != address(0), "zero factory address");
        require(redeemToken_ != address(0), "zero redeem token address");
        require(orderSigner_ != address(0), "zero order signer address");
        factoryAddress = factoryAddress_;
        redeemToken = redeemToken_;
        orderSigner = orderSigner_;
        chain = chain_;
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function decimals() public pure override(ERC20Upgradeable) returns (uint8) {
        return 8;
    }

    function getSupportAssetIDs() external view returns (uint256[] memory assetIDs) {
        assetIDs = new uint256[](supportAssetIDs.length());
        for (uint i = 0; i < assetIDs.length; i++) {
            assetIDs[i] = supportAssetIDs.at(i);
        }
    }

    function addSupportAsset(uint256 assetID) external onlyOwner {
        require(IAssetFactory(factoryAddress).hasAssetID(assetID), "asset not exists");
        require(!supportAssetIDs.contains(assetID), "already contains assetID");
        supportAssetIDs.add(assetID);
        emit AddAssetID(assetID);
    }

    function removeSupportAsset(uint256 assetID) external onlyOwner {
        require(IAssetFactory(factoryAddress).hasAssetID(assetID), "asset not exists");
        require(supportAssetIDs.contains(assetID), "assetID is not supported");
        supportAssetIDs.remove(assetID);
        emit RemoveAssetID(assetID);
    }

    function getSupportTokens() external view returns (address[] memory tokens) {
        tokens = new address[](supportTokens.length());
        for (uint i = 0; i < tokens.length; i++) {
            tokens[i] = supportTokens.at(i);
        }
    }

    function addSupportToken(address token) external onlyOwner {
        require(token != address(0), "token is zero address");
        require(!supportTokens.contains(token), "already contains token");
        supportTokens.add(token);
        emit AddToken(token);
    }

    function removeSupportToken(address token) external onlyOwner {
        require(token != address(0), "token is zero address");
        require(supportTokens.contains(token), "token is not supported");
        supportTokens.remove(token);
        emit RemoveToken(token);
    }

    function updateVault(address vault_) external onlyOwner {
        address oldVault = vault;
        require(vault_ != address(0), "vault is zero address");
        require(vault_ != vault, "vault not change");
        vault = vault_;
        emit UpdateVault(oldVault, vault);
    }

    function getVaultRoute(address requester) public view returns (address) {
        if (vaultRoutes[requester] == address(0)) {
            return vault;
        }
        return vaultRoutes[requester];
    }

    function addVaultRoute(address requester, address vault_) external onlyOwner {
        require(vault_ != address(0), "vault is zero address");
        require(vaultRoutes[requester] != vault_, "vault route not change");
        vaultRoutes[requester] = vault_;
        routeRequesters.add(requester);
        emit AddVaultRoute(requester, vault_);
    }

    function removeVaultRoute(address requester) external onlyOwner {
        require(vaultRoutes[requester] != address(0), "vault route not exists");
        delete vaultRoutes[requester];
        routeRequesters.remove(requester);
        emit RemoveVaultRoute(requester);
    }

    // @dev only for off-chain use
    function getVaultRoutes() external view returns (address[] memory requesters, address[] memory vaults) {
        requesters = new address[](routeRequesters.length());
        vaults = new address[](routeRequesters.length());
        for (uint i = 0; i < routeRequesters.length(); i++) {
            requesters[i] = routeRequesters.at(i);
            vaults[i] = vaultRoutes[routeRequesters.at(i)];
        }
    }

    function updateOrderSigner(address orderSigner_) external onlyOwner {
        address oldOrderSigner = orderSigner;
        require(orderSigner_ != address(0), "orderSigner is zero address");
        require(orderSigner_ != orderSigner, "orderSigner not change");
        orderSigner = orderSigner_;
        emit UpdateOrderSigner(oldOrderSigner, orderSigner);
    }

    function updateRedeemToken(address redeemToken_) external onlyOwner {
        address oldRedeemToken = redeemToken;
        require(redeemToken_ != address(0), "redeem token is zero address");
        require(redeemToken_ != redeemToken, "redeem token not change");
        redeemToken = redeemToken_;
        emit UpdateRedeemToken(oldRedeemToken, redeemToken);
    }

    function checkHedgeOrder(HedgeOrder calldata hedgeOrder, bytes32 orderHash, bytes calldata orderSignature) public view {
        require(keccak256(abi.encode(chain)) == keccak256(abi.encode(hedgeOrder.chain)), "chain not match");
        require(hedgeOrder.orderType != HedgeOrderType.NONE, "order type is none");
        if (hedgeOrder.orderType == HedgeOrderType.MINT) {
            require(supportAssetIDs.contains(hedgeOrder.assetID), "assetID not supported");
        }
        if (hedgeOrder.orderType == HedgeOrderType.REDEEM) {
            require(hedgeOrder.receiver != address(0), "receiver is zero address");
            require(redeemToken == hedgeOrder.redeemToken, "redeem token not supported");
        }
        if (hedgeOrder.orderType == HedgeOrderType.TOKEN_MINT) {
            require(hedgeOrder.token != address(0), "token is zero address");
            require(supportTokens.contains(hedgeOrder.token), "token not supported");
        }
        require(block.timestamp <= hedgeOrder.deadline, "expired");
        require(!orderHashs.contains(orderHash), "order already exists");
        require(SignatureChecker.isValidSignatureNow(orderSigner, orderHash, orderSignature), "signature not valid");
    }

    function setHedgeOrder(bytes32 orderHash, HedgeOrder calldata hedgeOrder) internal {
        HedgeOrder storage hedgeOrder_ = hedgeOrders[orderHash];
        hedgeOrder_.chain = hedgeOrder.chain;
        hedgeOrder_.orderType = hedgeOrder.orderType;
        hedgeOrder_.assetID = hedgeOrder.assetID;
        hedgeOrder_.redeemToken = redeemToken;
        hedgeOrder_.nonce = hedgeOrder.nonce;
        hedgeOrder_.inAmount = hedgeOrder.inAmount;
        hedgeOrder_.outAmount = hedgeOrder.outAmount;
        hedgeOrder_.deadline = hedgeOrder.deadline;
        hedgeOrder_.requester = hedgeOrder.requester;
        hedgeOrder_.receiver = hedgeOrder.receiver;
        hedgeOrder_.token = hedgeOrder.token;
        hedgeOrder_.vault = hedgeOrder.vault;
        orderHashs.add(orderHash);
    }

    function applyMint(HedgeOrder calldata hedgeOrder, bytes calldata orderSignature) external onlyRole(PARTICIPANT_ROLE) whenNotPaused {
        require(hedgeOrder.requester == msg.sender, "msg sender is not requester");
        bytes32 orderHash = keccak256(abi.encode(hedgeOrder));
        checkHedgeOrder(hedgeOrder, orderHash, orderSignature);
        require(hedgeOrder.orderType == HedgeOrderType.MINT || hedgeOrder.orderType == HedgeOrderType.TOKEN_MINT, "order type not match");
        IERC20 token;
        if (hedgeOrder.orderType == HedgeOrderType.MINT) {
            // cannot hedge when underlying is changing
            IAssetToken assetToken = IAssetToken(IAssetFactory(factoryAddress).assetTokens(hedgeOrder.assetID));
            require(!assetToken.rebalancing(), "asset token is rebalancing");
            require(assetToken.feeCollected(), "asset token has fee not collected");
            token = IERC20(address(assetToken));
        } else {
            token = IERC20(hedgeOrder.token);
            require(hedgeOrder.vault != address(0), "vault is zero address");
            require(getVaultRoute(hedgeOrder.requester) == hedgeOrder.vault, "vault not match");
        }
        setHedgeOrder(orderHash, hedgeOrder);
        orderStatus[orderHash] = HedgeOrderStatus.PENDING;
        requestTimestamps[orderHash] = block.timestamp;
        mintPendingAmounts[address(token)] += hedgeOrder.inAmount;
        require(token.allowance(hedgeOrder.requester, address(this)) >= hedgeOrder.inAmount, "not enough allowance");
        token.safeTransferFrom(hedgeOrder.requester, address(this), hedgeOrder.inAmount);
        emit ApplyMint(hedgeOrder);
    }

    function cancelMint(bytes32 orderHash) external onlyRole(PARTICIPANT_ROLE) whenNotPaused {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        require(requestTimestamps[orderHash] + MAX_MINT_DELAY <= block.timestamp, "not timeout");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(msg.sender == hedgeOrder.requester, "not requester");
        require(hedgeOrder.orderType == HedgeOrderType.MINT || hedgeOrder.orderType == HedgeOrderType.TOKEN_MINT, "order type not match");
        orderStatus[orderHash] = HedgeOrderStatus.CANCELED;
        IERC20 token;
        if (hedgeOrder.orderType == HedgeOrderType.MINT) {
            token = IERC20(IAssetFactory(factoryAddress).assetTokens(hedgeOrder.assetID));
        } else {
            token = IERC20(hedgeOrder.token);
        }
        mintPendingAmounts[address(token)] -= hedgeOrder.inAmount;
        token.safeTransfer(hedgeOrder.requester, hedgeOrder.inAmount);
        emit CancelMint(orderHash);
    }

    function rejectMint(bytes32 orderHash) external onlyOwner {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(hedgeOrder.orderType == HedgeOrderType.MINT || hedgeOrder.orderType == HedgeOrderType.TOKEN_MINT, "order type not match");
        orderStatus[orderHash] = HedgeOrderStatus.REJECTED;
        IERC20 token;
        if (hedgeOrder.orderType == HedgeOrderType.MINT) {
            token = IERC20(IAssetFactory(factoryAddress).assetTokens(hedgeOrder.assetID));
        } else {
            token = IERC20(hedgeOrder.token);
        }
        mintPendingAmounts[address(token)] -= hedgeOrder.inAmount;
        token.safeTransfer(hedgeOrder.requester, hedgeOrder.inAmount);
        emit RejectMint(orderHash);
    }

    function confirmMint(bytes32 orderHash) external onlyOwner {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(hedgeOrder.orderType == HedgeOrderType.MINT || hedgeOrder.orderType == HedgeOrderType.TOKEN_MINT, "order type not match");
        _mint(hedgeOrder.requester, hedgeOrder.outAmount);
        orderStatus[orderHash] = HedgeOrderStatus.CONFIRMED;
        if (hedgeOrder.orderType == HedgeOrderType.MINT) {
            IERC20 assetToken = IERC20(IAssetFactory(factoryAddress).assetTokens(hedgeOrder.assetID));
            IAssetIssuer issuer = IAssetIssuer(IAssetFactory(factoryAddress).issuers(hedgeOrder.assetID));
            if (assetToken.allowance(address(this), address(issuer)) < hedgeOrder.inAmount) {
                assetToken.forceApprove(address(issuer), hedgeOrder.inAmount);
            }
            issuer.burnFor(hedgeOrder.assetID, hedgeOrder.inAmount);
            mintPendingAmounts[address(assetToken)] -= hedgeOrder.inAmount;
        } else {
            require(hedgeOrder.vault != address(0), "vault is zero address");
            IERC20(hedgeOrder.token).safeTransfer(hedgeOrder.vault, hedgeOrder.inAmount);
            mintPendingAmounts[hedgeOrder.token] -= hedgeOrder.inAmount;
        }
        emit ConfirmMint(orderHash);
    }

    function applyRedeem(HedgeOrder calldata hedgeOrder, bytes calldata orderSignature) external onlyRole(PARTICIPANT_ROLE) whenNotPaused {
        require(hedgeOrder.requester == msg.sender, "msg sender is not requester");
        bytes32 orderHash = keccak256(abi.encode(hedgeOrder));
        checkHedgeOrder(hedgeOrder, orderHash, orderSignature);
        require(hedgeOrder.orderType == HedgeOrderType.REDEEM, "order type not match");
        require(allowance(hedgeOrder.requester, address(this)) >= hedgeOrder.inAmount, "not enough allowance");
        setHedgeOrder(orderHash, hedgeOrder);
        orderStatus[orderHash] = HedgeOrderStatus.PENDING;
        requestTimestamps[orderHash] = block.timestamp;
        redeemPendingAmounts[address(this)] += hedgeOrder.inAmount;
        redeemPendingAmounts[hedgeOrder.redeemToken] += hedgeOrder.outAmount;
        IERC20(address(this)).safeTransferFrom(hedgeOrder.requester, address(this), hedgeOrder.inAmount);
        emit ApplyRedeem(hedgeOrder);
    }

    function cancelRedeem(bytes32 orderHash) external onlyRole(PARTICIPANT_ROLE) whenNotPaused {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        require(requestTimestamps[orderHash] + MAX_REDEEM_DELAY <= block.timestamp, "not timeout");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(msg.sender == hedgeOrder.requester, "not requester");
        require(hedgeOrder.orderType == HedgeOrderType.REDEEM, "order type not match");
        orderStatus[orderHash] = HedgeOrderStatus.CANCELED;
        redeemPendingAmounts[address(this)] -= hedgeOrder.inAmount;
        redeemPendingAmounts[hedgeOrder.redeemToken] -= hedgeOrder.outAmount;
        IERC20(address(this)).safeTransfer(hedgeOrder.requester, hedgeOrder.inAmount);
        emit CancelRedeem(orderHash);
    }

    function rejectRedeem(bytes32 orderHash) external onlyOwner {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(hedgeOrder.orderType == HedgeOrderType.REDEEM, "order type not match");
        orderStatus[orderHash] = HedgeOrderStatus.REJECTED;
        redeemPendingAmounts[address(this)] -= hedgeOrder.inAmount;
        redeemPendingAmounts[hedgeOrder.redeemToken] -= hedgeOrder.outAmount;
        IERC20(address(this)).safeTransfer(hedgeOrder.requester, hedgeOrder.inAmount);
        emit RejectRedeem(orderHash);
    }

    function confirmRedeem(bytes32 orderHash, bytes32 txHash) external onlyOwner {
        require(orderHashs.contains(orderHash), "order not exists");
        require(orderStatus[orderHash] == HedgeOrderStatus.PENDING, "order is not pending");
        HedgeOrder storage hedgeOrder = hedgeOrders[orderHash];
        require(hedgeOrder.orderType == HedgeOrderType.REDEEM, "order type not match");
        orderStatus[orderHash] = HedgeOrderStatus.CONFIRMED;
        if (txHash == bytes32(0)) {
            require(IERC20(hedgeOrder.redeemToken).balanceOf(address(this)) >= hedgeOrder.outAmount, "not enough redeem token");
            IERC20(hedgeOrder.redeemToken).safeTransfer(hedgeOrder.requester, hedgeOrder.outAmount);
        } else {
            redeemTxHashs[orderHash] = txHash;
        }
        redeemPendingAmounts[address(this)] -= hedgeOrder.inAmount;
        redeemPendingAmounts[hedgeOrder.redeemToken] -= hedgeOrder.outAmount;
        _burn(address(this), hedgeOrder.inAmount);
        emit ConfirmRedeem(orderHash);
    }

    function rescueToken(address token) external onlyOwner {
        require(token != address(0), "token is zero address");
        require(vault != address(0), "vault is zero address");
        uint256 rescueAmount = IERC20(token).balanceOf(address(this));
        require(rescueAmount > mintPendingAmounts[token] + redeemPendingAmounts[token], "nothing to rescue");
        rescueAmount -= mintPendingAmounts[token] + redeemPendingAmounts[token];
        IERC20(token).safeTransfer(vault, rescueAmount);
    }

    function getOrderHashs() external view returns (bytes32[] memory orderHashs_) {
        orderHashs_ = new bytes32[](orderHashs.length());
        for (uint i = 0; i < orderHashs.length(); i++) {
            orderHashs_[i] = orderHashs.at(i);
        }
    }

    function getOrderHashLength() external view returns (uint256) {
        return orderHashs.length();
    }

    function getOrderHash(uint256 nonce) external view returns (bytes32) {
        return orderHashs.at(nonce);
    }
}