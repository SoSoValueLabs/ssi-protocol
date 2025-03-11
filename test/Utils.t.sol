// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/Utils.sol";
import "../src/Interface.sol";
import {Test, console} from "forge-std/Test.sol";

contract UtilsTest is Test {
    // 测试stringToAddress函数
    function test_StringToAddress() public {
        // 测试有效地址
        address expected = 0x1234567890123456789012345678901234567890;
        address result = Utils.stringToAddress("0x1234567890123456789012345678901234567890");
        assertEq(result, expected);

        // 测试小写字母
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xabcdef0123456789abcdef0123456789abcdef01");
        assertEq(result, expected);

        // 测试大写字母
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xABCDEF0123456789ABCDEF0123456789ABCDEF01");
        assertEq(result, expected);

        // 测试混合大小写
        expected = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        result = Utils.stringToAddress("0xaBcDeF0123456789aBcDeF0123456789aBcDeF01");
        assertEq(result, expected);
    }

    // 测试stringToAddress函数的错误情况
    function test_StringToAddress_InvalidLength() public {
        // 测试长度不足
        vm.expectRevert("Invalid address length");
        Utils.stringToAddress("0x123");

        // 测试长度过长
        vm.expectRevert("Invalid address length");
        Utils.stringToAddress("0x1234567890123456789012345678901234567890123");
    }

    function test_StringToAddress_InvalidPrefix() public {
        // 测试前缀不是0x
        vm.expectRevert("Invalid address prefix");
        Utils.stringToAddress("1x1234567890123456789012345678901234567890");
    }

    function test_HexCharToByte_InvalidChar() public {
        // 测试无效的十六进制字符
        vm.expectRevert("Invalid hex character");
        // 我们需要通过一个包装函数来测试内部函数
        this.callHexCharToByte("g");
    }

    // 包装函数，用于测试hexCharToByte
    function callHexCharToByte(string memory char) public pure {
        Utils.hexCharToByte(bytes(char)[0]);
    }

    // 测试containTokenset函数
    function test_ContainTokenset() public {
        // 创建测试用的Token数组
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

        // 创建包含在a中的Token数组
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // a应该包含b
        assertTrue(Utils.containTokenset(a, b));

        // 修改b中的金额，使其超过a中的金额
        b[0].amount = 150;
        assertFalse(Utils.containTokenset(a, b));

        // 创建不在a中的Token
        Token[] memory c = new Token[](1);
        c[0] = Token({
            chain: "SETH",
            symbol: "USDT",
            addr: "0x0000000000000000000000000000000000000000",
            decimals: 6,
            amount: 50
        });

        // a不应该包含c
        assertFalse(Utils.containTokenset(a, c));
    }

    // 测试subTokenset函数
    function test_SubTokenset() public {
        // 创建测试用的Token数组
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

        // 创建要减去的Token数组
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // 计算a - b
        Token[] memory result = Utils.subTokenset(a, b);

        // 结果应该有2个元素
        assertEq(result.length, 2);

        // 第一个元素应该是WBTC，金额为50
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 50);

        // 第二个元素应该是WETH，金额为200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);

        // 测试完全减去一个Token
        b[0].amount = 100;
        result = Utils.subTokenset(a, b);

        // 结果应该只有1个元素
        assertEq(result.length, 1);

        // 元素应该是WETH，金额为200
        assertEq(result[0].symbol, "WETH");
        assertEq(result[0].amount, 200);
    }

    // 测试subTokenset函数的错误情况
    function test_SubTokenset_InsufficientAmount() public {
        // 创建测试用的Token数组
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // 创建要减去的Token数组，金额大于a中的金额
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // 应该抛出错误
        vm.expectRevert("a.amount less than b.amount");
        Utils.subTokenset(a, b);
    }

    function test_SubTokenset_NotContains() public {
        // 创建测试用的Token数组
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // 创建不在a中的Token数组
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 50
        });

        // 应该抛出错误
        vm.expectRevert("a not contains b");
        Utils.subTokenset(a, b);
    }

    // 测试addTokenset函数
    function test_AddTokenset() public {
        // 创建测试用的Token数组
        Token[] memory a = new Token[](1);
        a[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 100
        });

        // 创建要添加的Token数组，包含相同的Token
        Token[] memory b = new Token[](1);
        b[0] = Token({
            chain: "SETH",
            symbol: "WBTC",
            addr: "0x1234567890123456789012345678901234567890",
            decimals: 8,
            amount: 50
        });

        // 计算a + b
        Token[] memory result = Utils.addTokenset(a, b);

        // 结果应该有1个元素
        assertEq(result.length, 1);

        // 元素应该是WBTC，金额为150
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 150);

        // 创建要添加的Token数组，包含不同的Token
        Token[] memory c = new Token[](1);
        c[0] = Token({
            chain: "SETH",
            symbol: "WETH",
            addr: "0xabcdef0123456789abcdef0123456789abcdef01",
            decimals: 18,
            amount: 200
        });

        // 计算a + c
        result = Utils.addTokenset(a, c);

        // 结果应该有2个元素
        assertEq(result.length, 2);

        // 第一个元素应该是WBTC，金额为100
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 100);

        // 第二个元素应该是WETH，金额为200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);
    }

    // 测试copyTokenset函数
    function test_CopyTokenset() public {
        // 创建测试用的Token数组
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

        // 复制Token数组
        Token[] memory result = Utils.copyTokenset(a);

        // 结果应该有2个元素
        assertEq(result.length, 2);

        // 第一个元素应该是WBTC，金额为100
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 100);

        // 第二个元素应该是WETH，金额为200
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 200);

        // 修改原数组不应该影响复制的数组
        a[0].amount = 150;
        assertEq(result[0].amount, 100);
    }

    // 测试muldivTokenset函数
    function test_MuldivTokenset() public {
        // 创建测试用的Token数组
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

        // 计算a * 2 / 1
        Token[] memory result = Utils.muldivTokenset(a, 2, 1);

        // 结果应该有2个元素
        assertEq(result.length, 2);

        // 第一个元素应该是WBTC，金额为200
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 200);

        // 第二个元素应该是WETH，金额为400
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 400);

        // 计算a * 1 / 2
        result = Utils.muldivTokenset(a, 1, 2);

        // 结果应该有2个元素
        assertEq(result.length, 2);

        // 第一个元素应该是WBTC，金额为50
        assertEq(result[0].symbol, "WBTC");
        assertEq(result[0].amount, 50);

        // 第二个元素应该是WETH，金额为100
        assertEq(result[1].symbol, "WETH");
        assertEq(result[1].amount, 100);
    }

    // 测试isSameToken函数
    function test_IsSameToken() public {
        // 创建两个相同的Token
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

        // a和b应该是相同的Token（金额不影响）
        assertTrue(Utils.isSameToken(a, b));

        // 修改b的链
        b.chain = "ETH";
        assertFalse(Utils.isSameToken(a, b));
        b.chain = "SETH";

        // 修改b的符号
        b.symbol = "BTC";
        assertFalse(Utils.isSameToken(a, b));
        b.symbol = "WBTC";

        // 修改b的地址
        b.addr = "0xabcdef0123456789abcdef0123456789abcdef01";
        assertFalse(Utils.isSameToken(a, b));
        b.addr = "0x1234567890123456789012345678901234567890";

        // 修改b的小数位数
        b.decimals = 18;
        assertFalse(Utils.isSameToken(a, b));
    }

    // 测试calcTokenHash函数
    function test_CalcTokenHash() public {
        // 创建两个相同的Token（金额不同）
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

        // a和b的哈希应该相同（金额不影响哈希）
        bytes32 hashA = Utils.calcTokenHash(a);
        bytes32 hashB = Utils.calcTokenHash(b);
        assertEq(hashA, hashB);

        // 修改b的链
        b.chain = "ETH";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.chain = "SETH";

        // 修改b的符号
        b.symbol = "BTC";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.symbol = "WBTC";

        // 修改b的地址
        b.addr = "0xabcdef0123456789abcdef0123456789abcdef01";
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
        b.addr = "0x1234567890123456789012345678901234567890";

        // 修改b的小数位数
        b.decimals = 18;
        hashB = Utils.calcTokenHash(b);
        assertTrue(hashA != hashB);
    }

    // 测试hasDuplicates函数
    function test_HasDuplicates() public {
        // 创建没有重复的Token数组
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

        // a不应该有重复
        assertFalse(Utils.hasDuplicates(a));

        // 创建有重复的Token数组
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

        // b应该有重复
        assertTrue(Utils.hasDuplicates(b));
    }

    // 测试validateTokenset函数
    function test_ValidateTokenset() public {
        // 创建有效的Token数组
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

        // 验证应该成功
        Utils.validateTokenset(a);

        // 创建有重复的Token数组
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

        // 验证应该失败
        vm.expectRevert("has dupliated tokens");
        Utils.validateTokenset(b);

        // 创建有金额为0的Token数组
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

        // 验证应该失败
        vm.expectRevert("token amount is zero");
        Utils.validateTokenset(c);
    }
}
