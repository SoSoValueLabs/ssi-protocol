// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/ChristmasAirdrop.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/Utils.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract ChristmasAirdropTest is Test {
    ChristmasAirdrop public airdrop;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
    MockERC20 public token4;

    address public owner = address(0x123);
    address public user1 = address(0x456);
    address public user2 = address(0x789);
    address public user3 = address(0x782);
    address public user4 = address(0x711);

    bytes32 public merkleRoot;
    bytes32[] public proof1;
    bytes32[] public proof2;
    bytes32[] public proof3;
    bytes32[] public proof4;
    bytes32[] public proof5;

    bytes32[] public leaves;
    uint256 public expirationTime;

    function setUp() public {
        vm.startPrank(owner);

        // 部署两个代币合约
        token1 = new MockERC20("Token1", "TK1", 1000 ether);
        token2 = new MockERC20("Token2", "TK2", 1000 ether);
        token3 = new MockERC20("Token3", "TK3", 1000 ether);
        token4 = new MockERC20("Token4", "TK4", 1000 ether);

        // 设置接收者、金额和代币地址
        address[] memory recipients = new address[](5);
        recipients[0] = user1;
        recipients[1] = user2;
        recipients[2] = user1;
        recipients[3] = user3;
        recipients[4] = user4;

        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
        amounts[2] = 300 ether;
        amounts[3] = 400 ether;
        amounts[4] = 500 ether;

        address[] memory tokens = new address[](5);
        tokens[0] = address(token1);
        tokens[1] = address(token2);
        tokens[2] = address(token2);
        tokens[3] = address(token3);
        tokens[4] = address(token4);

        console.log("recipients[0]:", recipients[0]);
        console.log("recipients[1]:", recipients[1]);
        console.log("recipients[2]:", recipients[2]);
        console.log("recipients[3]:", recipients[3]);
        console.log("recipients[4]:", recipients[4]);
        console.log("amounts[0]:", amounts[0]);
        console.log("amounts[1]:", amounts[1]);
        console.log("amounts[2]:", amounts[2]);
        console.log("amounts[3]:", amounts[3]);
        console.log("amounts[4]:", amounts[4]);
        console.log("tokens[0]:", tokens[0]);
        console.log("tokens[1]:", tokens[1]);
        console.log("tokens[2]:", tokens[2]);
        console.log("tokens[3]:", tokens[3]);
        console.log("tokens[4]:", tokens[4]);

        // 生成 Merkle 树
        leaves = new bytes32[](recipients.length);
        for (uint256 i = 0; i < recipients.length; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(recipients[i], tokens[i], amounts[i])
            );
        }
        merkleRoot = getMerkleRoot(leaves);
        console.logBytes32(merkleRoot);
        // 部署空投合约
        expirationTime = block.timestamp + 1 days;
        airdrop = new ChristmasAirdrop(merkleRoot, expirationTime);

        // 将代币转移到空投合约
        token1.transfer(address(airdrop), 100 ether);
        token2.transfer(address(airdrop), 200 ether);

        // 生成 Merkle 证明
        proof1 = getProof(leaves, 0);

        proof2 = getProof(leaves, 1);

        // console.log(recipients[0]);
        // for (uint256 i = 0; i < proof1.length; i++) {
        //     console.logBytes32(proof1[i]);
        // }

        vm.stopPrank();
    }

    function getMerkleRoot(
        bytes32[] memory leaves
    ) internal pure returns (bytes32) {
        require(leaves.length > 0, "No leaves provided");

        while (leaves.length > 1) {
            uint256 len = leaves.length;
            uint256 i = 0;
            for (; i + 1 < len; i += 2) {
                leaves[i / 2] = _hashPair(leaves[i], leaves[i + 1]);
            }
            if (i < len) {
                leaves[i / 2] = leaves[i];
                len = i / 2 + 1;
            } else {
                len = i / 2;
            }
            assembly {
                mstore(leaves, len)
            }
        }
        return leaves[0];
    }

    function testDeployment() public {
        assertEq(airdrop.merkleRoot(), merkleRoot);
        assertEq(airdrop.expirationTime(), expirationTime);
    }

    function testSetExpirationTime() public {
        uint256 newExpirationTime = block.timestamp + 2 days;
        vm.startPrank(owner);
        airdrop.setExpirationTime(newExpirationTime);
        assertEq(airdrop.expirationTime(), newExpirationTime);
        vm.stopPrank();
    }

    function testSetMerkleRoot() public {
        bytes32 newMerkleRoot = keccak256(abi.encodePacked("new root"));

        vm.startPrank(owner);
        airdrop.setMerkleRoot(newMerkleRoot);
        assertEq(airdrop.merkleRoot(), newMerkleRoot);
        vm.stopPrank();
    }

    function testClaimAirdropAfterExpiration() public {
        // 快进到过期时间之后
        vm.warp(expirationTime + 1);

        // user1 尝试领取空投，应当失败
        vm.prank(user1);
        vm.expectRevert("Airdrop has expired");
        airdrop.claim(address(token1), 100 ether, proof1);
    }

    function testClaimAirdrop() public {
        // user1 领取空投
        vm.prank(user1);
        airdrop.claim(address(token1), 100 ether, proof1);
        assertEq(token1.balanceOf(user1), 100 ether);

        // 再次领取
        // vm.startPrank(user1);
        // vm.expectRevert("Airdrop already claimed for this token");
        // airdrop.claim(address(token1), 100 ether, proof1);
        // vm.stopPrank();
    }

    function testClaimAirdropInvalidProof() public {
        vm.prank(user1);
        vm.expectRevert("Invalid Merkle Proof");
        airdrop.claim(address(token1), 100 ether, proof2);
    }

    function testBatchAirdrop() public {
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof1;
        proofs[1] = proof2;

        // owner 批量空投
        vm.prank(owner);
        airdrop.batchClaim(recipients, tokens, amounts, proofs);

        // 验证用户的代币余额
        assertEq(token1.balanceOf(user1), 100 ether);
        assertEq(token2.balanceOf(user2), 200 ether);

        // 再次批量空投，应当跳过已领取的用户
        vm.prank(owner);
        airdrop.batchClaim(recipients, tokens, amounts, proofs);

        assertEq(token1.balanceOf(user1), 100 ether);
        assertEq(token2.balanceOf(user2), 200 ether);
    }

    function testWithdrawTokens() public {
        // owner 提取剩余的 token1
        uint256 remaining = token1.balanceOf(address(airdrop));
        vm.prank(owner);
        airdrop.withdrawTokens(owner, address(token1), remaining);

        // 验证 owner 收到代币
        assertEq(token1.balanceOf(owner), remaining + (1000 ether - 100 ether));
    }

    // 工具函数：生成 Merkle 证明
    function getProof(
        bytes32[] memory leaves,
        uint256 index
    ) internal pure returns (bytes32[] memory proof) {
        uint256 n = leaves.length;
        proof = new bytes32[](0);
        while (n > 1) {
            if (index % 2 == 0 && index + 1 < n) {
                proof = append(proof, leaves[index + 1]);
            } else if (index % 2 == 1) {
                proof = append(proof, leaves[index - 1]);
            }
            index = index / 2;
            for (uint256 i = 0; i < n / 2; i++) {
                leaves[i] = _hashPair(leaves[2 * i], leaves[2 * i + 1]);
            }
            if (n % 2 == 1) {
                leaves[n / 2] = leaves[n - 1];
                n = n / 2 + 1;
            } else {
                n = n / 2;
            }
        }
    }

    // 工具函数：哈希两个节点
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return
            a < b
                ? keccak256(abi.encodePacked(a, b))
                : keccak256(abi.encodePacked(b, a));
    }

    // 工具函数：数组追加
    function append(
        bytes32[] memory array,
        bytes32 value
    ) internal pure returns (bytes32[] memory newArray) {
        newArray = new bytes32[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }
        newArray[array.length] = value;
    }
}
