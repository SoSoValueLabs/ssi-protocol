// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/Utils.sol";
import "../src/Interface.sol";
import {Test, console} from "forge-std/Test.sol";

contract UtilsTest is Test {
    // Test the stringToAddress function
    function test_StringToAddress() public {
        // Test valid address
        address expected = 0x1234567890123456789012345678901234567890;
        address result = Utils.stringToAddress("0x1234567890123456789012345678901234567890");
        assertEq(result, expected);

        // Test lowercase letters
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xabcdef0123456789abcdef0123456789abcdef01");
        assertEq(result, expected);

        // Test uppercase letters
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xABCDEF0123456789ABCDEF0123456789ABCDEF01");
        assertEq(result, expected);

        // Test mixed case
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xaBcDeF0123456789aBcDeF0123456789aBcDeF01");
        assertEq(result, expected);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    // Test error cases for the stringToAddress function
    function test_StringToAddress_InvalidLength() public {
        // Test too short
        vm.expectRevert("Invalid address length");
        Utils.stringToAddress("0x123");

        // Test too long
        vm.expectRevert("Invalid address length");
        Utils.stringToAddress("0x1234567890123456789012345678901234567890123");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_StringToAddress_InvalidPrefix() public {
        // Test prefix is not 0x
        vm.expectRevert("Invalid address prefix");
        Utils.stringToAddress("1x1234567890123456789012345678901234567890");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_HexCharToByte_InvalidChar() public {
        // Test invalid hex character
        vm.expectRevert("Invalid hex character");
        // We need to use a wrapper function to test the internal function
        this.callHexCharToByte("g");
    }

    // Wrapper function to test hexCharToByte
    function callHexCharToByte(string memory char) public pure {
        Utils.hexCharToByte(bytes(char)[0]);
    }

    // Test the containTokenset function
    function test_ContainTokenset() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Create a Token array that is contained in a
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // a should contain b
        assertTrue(Utils.containTokenset(a, b));

        // Modify the amount in b to exceed the amount in a
        b[0].amount = 150;
        assertFalse(Utils.containTokenset(a, b));

        // Create a Token that is not in a
        Token[] memory c = new Token[](1);
        c[0] = Token({
            chain: "SETH",
            symbol: "USDT",
            addr: "0x0000000000000000000000000000000000000000",
            decimals: 6,
            amount: 50
        });

        // a should not contain c
        assertFalse(Utils.containTokenset(a, c));
    }

    // Test the subTokenset function
    function test_SubTokenset() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Create a Token array to subtract
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // Calculate a - b
        Token[] memory result = Utils.subTokenset(a, b);

        // The result should have 2 elements
        assertEq(result.length, 2);

        // The first element should be WBTC with an amount of 50
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 50);

        // The second element should be WETH with an amount of 200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);

        // Test completely subtracting a Token
        b[0].amount = 100;
        result = Utils.subTokenset(a, b);

        // The result should have only 1 element
        assertEq(result.length, 1);

        // The element should be WETH with an amount of 200
        assertEq(result[0].symbol, "WETH");
        assertEq(result[0].amount, 200);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    // Test error cases for the subTokenset function
    function test_SubTokenset_InsufficientAmount() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // Create a Token array to subtract with an amount greater than in a
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // Should revert
        vm.expectRevert("a.amount less than b.amount");
        Utils.subTokenset(a, b);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_SubTokenset_NotContains() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // Create a Token array that is not in a
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 50
        });

        // Should revert
        vm.expectRevert("a not contains b");
        Utils.subTokenset(a, b);
    }

    // Test the addTokenset function
    function test_AddTokenset() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // Create a Token array to add, containing the same Token
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // Calculate a + b
        Token[] memory result = Utils.addTokenset(a, b);

        // The result should have 1 element
        assertEq(result.length, 1);

        // The element should be WBTC with an amount of 150
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 150);

        // Create a Token array to add, containing a different Token
        Token[] memory c = new Token[](1);
        c[0] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Calculate a + c
        result = Utils.addTokenset(a, c);

        // The result should have 2 elements
        assertEq(result.length, 2);

        // The first element should be WBTC with an amount of 100
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 100);

        // The second element should be WETH with an amount of 200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);
    }

    // Test the copyTokenset function
    function test_CopyTokenset() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Copy the Token array
        Token[] memory result = Utils.copyTokenset(a);

        // The result should have 2 elements
        assertEq(result.length, 2);

        // The first element should be WBTC with an amount of 100
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 100);

        // The second element should be WETH with an amount of 200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);

        // Modifying the original array should not affect the copied array
        a[0].amount = 150;
        assertEq(result[0].amount, 100);
    }

    // Test the muldivTokenset function
    function test_MuldivTokenset() public {
        // Create a Token array for testing
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Calculate a * 2 / 1
        Token[] memory result = Utils.muldivTokenset(a, 2, 1);

        // The result should have 2 elements
        assertEq(result.length, 2);

        // The first element should be WBTC with an amount of 200
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 200);

        // The second element should be WETH with an amount of 400
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 400);

        // Calculate a * 1 / 2
        result = Utils.muldivTokenset(a, 1, 2);

        // The result should have 2 elements
        assertEq(result.length, 2);

        // The first element should be WBTC with an amount of 50
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 50);

        // The second element should be WETH with an amount of 100
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 100);
    }

    // Test the isSameToken function
    function test_IsSameToken() public {
        // Create two identical Tokens (different amounts)
        Token memory a = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        Token memory b = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 200
        });

        // a and b should be the same Token (amount does not affect)
        assertTrue(Utils.isSameToken(a, b));

        // Modify the chain of b
        b.chain = "ETH";
        assertFalse(Utils.isSameToken(a, b));
        b.chain = "SETH";

        // Modify the symbol of b
        b.symbol = "BTC";
        assertFalse(Utils.isSameToken(a, b));
        b.symbol = "WBTC";

        // Modify the address of b
        b.addr = "0xabcdef0123456789abcdef0123456789abcdef01";
        assertFalse(Utils.isSameToken(a, b));
        b.addr = "0x1234567890123456789012345678901234567890";

        // Modify the decimals of b
        b.decimals = 18;
        assertFalse(Utils.isSameToken(a, b));
    }

    // Test the calcTokenHash function
    function test_CalcTokenHash() public {
        // Create two identical Tokens (different amounts)
        Token memory a = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        Token memory b = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 200
        });

        // The hashes of a and b should be the same (amount does not affect the hash)
        bytes32 hashA = Utils.calcTokenHash(a);
        bytes32 hashB = Utils.calcTokenHash(b);
        assertEq(hashA, hashB);

        // Modify the chain of b
        b.chain = "ETH";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.chain = "SETH";

        // Modify the symbol of b
        b.symbol = "BTC";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.symbol = "WBTC";

        // Modify the address of b
        b.addr = "0xabcdef0123456789abcdef0123456789abcdef01";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.addr = "0x1234567890123456789012345678901234567890";

        // Modify the decimals of b
        b.decimals = 18;
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
    }

    // Test the hasDuplicates function
    function test_HasDuplicates() public {
        // Create a Token array without duplicates
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // a should not have duplicates
        assertFalse(Utils.hasDuplicates(a));

        // Create a Token array with duplicates
        Token[] memory b = new Token[](3);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        b[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });
        b[2] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 300
        });

        // b should have duplicates
        assertTrue(Utils.hasDuplicates(b));
    }

    /// forge-config: default.allow_internal_expect_revert = true
    // Test the validateTokenset function
    function test_ValidateTokenset() public {
        // Create a valid Token array
        Token[] memory a = new Token[](2);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        a[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // Validation should succeed
        Utils.validateTokenset(a);

        // Create a Token array with duplicates
        Token[] memory b = new Token[](3);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        b[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });
        b[2] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 300
        });

        // Validation should fail
        vm.expectRevert("has dupliated tokens");
        Utils.validateTokenset(b);

        // Create a Token array with an amount of 0
        Token[] memory c = new Token[](2);
        c[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });
        c[1] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 0
        });

        // Validation should fail
        vm.expectRevert("token amount is zero");
        Utils.validateTokenset(c);
    }
}