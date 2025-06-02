// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/AssetIssuer.sol";
import {Test, console} from "forge-std/Test.sol";

contract SwapTest is Test {
    address wlp = 0x1D1109898060Bcd80936cd7522F3812f9ca81cd6;
    address pmm = 0x0978F131401D1BF137e65e2A1fa11DE700B1F3c5;
    address owner = 0xd463D3d8333b7AD6a14d00e1700C80AF5A37F751;
    address mag7 = 0x9E6A46f294bB67c20F1D1E7AfB0bBEf614403B55;
    AssetIssuer assetIssuer;
    Swap swap;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        vm.createSelectFork(rpcUrl);
        vm.rollFork(30743020);
        swap = Swap(0xF909bfa750721501B4F8433588FaE5cE303Db08B);
        assetIssuer = AssetIssuer(0x0306acEb4c20FF33480d90038F8b375cC6A6b66e);
        vm.startPrank(owner);
        swap.upgradeToAndCall(address(new Swap()), "");
        assetIssuer.upgradeToAndCall(address(new AssetIssuer()), "");
        vm.stopPrank();
    }

    function test_forceCancelAndReject() public {
        OrderInfo memory orderInfo = test_createOrderInfo();
        uint256 beforeBalance = IERC20(mag7).balanceOf(wlp);
        uint256 totalSupply = IERC20(mag7).totalSupply();
        Token[] memory basketBefore = IAssetToken(mag7).getBasket();
        Token[] memory tokensetBefore = IAssetToken(mag7).getTokenset();
        vm.startPrank(owner);
        swap.forceCancelSwapRequest(orderInfo);
        assetIssuer.rejectRedeemRequest(55);
        vm.stopPrank();
        assertEq(uint8(swap.getSwapRequest(orderInfo.orderHash).status), uint8(SwapRequestStatus.FORCE_CANCEL));
        assertEq(uint8(assetIssuer.getRedeemRequest(55).status), uint8(RequestStatus.REJECTED));
        assertEq(IERC20(mag7).balanceOf(wlp), beforeBalance + 8500 * 10 ** 8);
        assertEq(totalSupply, IERC20(mag7).totalSupply());
        Token[] memory basket = IAssetToken(mag7).getBasket();
        for (uint i = 0; i < basket.length; i++) {
            assertEq(basket[i].amount, basketBefore[i].amount);
            assertEq(keccak256(bytes(basket[i].chain)), keccak256(bytes(basketBefore[i].chain)));
            assertEq(keccak256(bytes(basket[i].symbol)), keccak256(bytes(basketBefore[i].symbol)));
            assertEq(keccak256(bytes(basket[i].addr)), keccak256(bytes(basketBefore[i].addr)));
            assertEq(basket[i].decimals, basketBefore[i].decimals);
        }
        Token[] memory tokenset = IAssetToken(mag7).getTokenset();
        for (uint i = 0; i < tokenset.length; i++) {
            assertEq(tokenset[i].amount, tokensetBefore[i].amount);
            assertEq(keccak256(bytes(tokenset[i].chain)), keccak256(bytes(tokensetBefore[i].chain)));
            assertEq(keccak256(bytes(tokenset[i].symbol)), keccak256(bytes(tokensetBefore[i].symbol)));
            assertEq(keccak256(bytes(tokenset[i].addr)), keccak256(bytes(tokensetBefore[i].addr)));
            assertEq(tokenset[i].decimals, tokensetBefore[i].decimals);
        }
    }

    function test_createOrderInfo() public view returns (OrderInfo memory) {
        // Create inTokenset array
        Token[] memory inTokenset = new Token[](7);
        inTokenset[0] = Token({
            chain: "BTC",
            symbol: "BTC",
            addr: "",
            decimals: 8,
            amount: 247
        });
        inTokenset[1] = Token({
            chain: "ETH",
            symbol: "ETH",
            addr: "",
            decimals: 18,
            amount: 49676885860462
        });
        inTokenset[2] = Token({
            chain: "BSC_BNB",
            symbol: "BSC_BNB",
            addr: "",
            decimals: 18,
            amount: 130329110965628
        });
        inTokenset[3] = Token({
            chain: "SOL",
            symbol: "SOL",
            addr: "",
            decimals: 9,
            amount: 529104
        });
        inTokenset[4] = Token({
            chain: "XRP",
            symbol: "XRP",
            addr: "",
            decimals: 6,
            amount: 36563
        });
        inTokenset[5] = Token({
            chain: "DOGE",
            symbol: "DOGE",
            addr: "",
            decimals: 8,
            amount: 41786562
        });
        inTokenset[6] = Token({
            chain: "ADA",
            symbol: "ADA",
            addr: "",
            decimals: 6,
            amount: 104663
        });

        // Create outTokenset array
        Token[] memory outTokenset = new Token[](1);
        outTokenset[0] = Token({
            chain: "BASE_ETH",
            symbol: "BASE_USDC",
            addr: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            decimals: 6,
            amount: 100000000
        });

        // Create inAddressList array
        string[] memory inAddressList = new string[](7);
        inAddressList[0] = "1MdW67Mz9AecuBwNyKSbfiCJCf46E2up58";
        inAddressList[1] = "0xfF5c4fC8B6431aB69585f2249Fe9915F7890ea9F";
        inAddressList[2] = "0xfF5c4fC8B6431aB69585f2249Fe9915F7890ea9F";
        inAddressList[3] = "3n3rCSSLHbxhVVa3UCaprJhL5xVkkqt9WSH58VCY7wXy";
        inAddressList[4] = "rNxp4h8apvRis6mJf9Sh8C6iRxfrDWN7AV:435281349";
        inAddressList[5] = "DAqbP9z6nbccktAVzv7FMs7Qj6HqwKHeEF";
        inAddressList[6] = "addr1vxj4wgzaldng22aydvh3qa3x3xejkygmchauphpxzfjc2hce4w82g";

        // Create outAddressList array
        string[] memory outAddressList = new string[](1);
        outAddressList[0] = "0x0306acEb4c20FF33480d90038F8b375cC6A6b66e";

        // Create Order struct
        Order memory order = Order({
            chain: "BASE_ETH",
            maker: 0x0978F131401D1BF137e65e2A1fa11DE700B1F3c5,
            nonce: 1747365105739,
            inTokenset: inTokenset,
            outTokenset: outTokenset,
            inAddressList: inAddressList,
            outAddressList: outAddressList,
            inAmount: 850000000000,
            outAmount: 1000000,
            deadline: 1748252236,
            requester: 0x1D1109898060Bcd80936cd7522F3812f9ca81cd6
        });

        // Create OrderInfo struct
        OrderInfo memory orderInfo = OrderInfo({
            order: order,
            orderHash: 0xbf28b32fcfd646bc205227d111ab88fc0184f42bd33bc4c4cf0522774832f6bb,
            orderSign: hex"0f70eef57459a7e484ee15a379edfa18593a297106dbab4465534569f6fbacb2420440219b30a3d82243c64a56a988e58a12ffe269fc8421b1ab0f18fde013931b"
        });

        assertEq(keccak256(abi.encode(orderInfo.order)), orderInfo.orderHash);
        assertTrue(SignatureChecker.isValidSignatureNow(pmm, orderInfo.orderHash, orderInfo.orderSign));

        return orderInfo;
    }
}