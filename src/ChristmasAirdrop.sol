// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "forge-std/console.sol";

contract ChristmasAirdrop is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    bytes32 public merkleRoot;
    mapping(address => mapping(address => uint256)) public hasClaimed;
    uint256 public expirationTime;

    event AirdropClaimed(
        address indexed claimant,
        address indexed token,
        uint256 amount
    );
    event MerkleRootUpdated(bytes32 indexed newMerkleRoot);
    event TokensWithdrawn(address to, address indexed token, uint256 amount);
    event ExpirationTimeUpdated(uint256 newExpirationTime);

    constructor(
        address owner,
        bytes32 _merkleRoot,
        uint256 _expirationTime
    ) Ownable(owner) {
        merkleRoot = _merkleRoot;
        expirationTime = _expirationTime;
    }

    function setExpirationTime(uint256 _newExpirationTime) external onlyOwner {
        expirationTime = _newExpirationTime;
        emit ExpirationTimeUpdated(_newExpirationTime);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootUpdated(_merkleRoot);
    }

    function _claim(
        address recipient,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        require(block.timestamp <= expirationTime, "Airdrop has expired");
        uint256 claimed = hasClaimed[recipient][token];
        require(amount > claimed, "Already claimed");
        uint256 claimableAmount = amount - claimed;
        bytes32 leaf = keccak256(abi.encodePacked(recipient, token, amount));
        require(
            MerkleProof.verify(proof, merkleRoot, leaf),
            "Invalid Merkle Proof"
        );
        if (claimableAmount > 0) {
            hasClaimed[recipient][token] = amount;
            IERC20(token).safeTransfer(recipient, claimableAmount);
            emit AirdropClaimed(recipient, token, claimableAmount);
        }
    }

    function claim(
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        _claim(msg.sender, token, amount, proof);
    }

    function batchClaim(
        address[] calldata recipients,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        require(
            recipients.length == tokens.length &&
                recipients.length == amounts.length &&
                recipients.length == proofs.length,
            "Input arrays length mismatch"
        );
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            address token = tokens[i];
            uint256 amount = amounts[i];
            bytes32[] calldata proof = proofs[i];
            uint256 claimed = hasClaimed[recipient][token];
            uint256 claimableAmount = amount - claimed;
            if (claimableAmount > 0) {
                _claim(recipient, token, amount, proof);
            }
        }
    }

    function withdrawTokens(
        address token,
        uint256 amount
    ) external onlyOwner nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Insufficient token balance");
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokensWithdrawn(msg.sender, token, amount);
    }
}
