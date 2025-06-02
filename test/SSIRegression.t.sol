// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./MockToken.sol";
import "../src/Interface.sol";
import "../src/Swap.sol";
import "../src/AssetIssuer.sol";
import "../src/AssetRebalancer.sol";
import "../src/AssetFeeManager.sol";
import "../src/AssetFactory.sol";
import {FundManagerTest} from "./AssetManager.t.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Test, console} from "forge-std/Test.sol";

contract SSIRegressionTest is FundManagerTest {
    function setUp() public override {
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 blockNumber = vm.envUint("BLOCK_NUMBER");
        vm.createSelectFork(rpcUrl);
        vm.rollFork(blockNumber);

        vm.etch(pmm, "");
        vm.resetNonce(pmm);
        vm.etch(ap, "");
        vm.resetNonce(ap);

        chain = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).chain();
        owner = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).owner();
        vault = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D).vault();

        vm.startPrank(owner);
        swap = Swap(0xF909bfa750721501B4F8433588FaE5cE303Db08B);
        swap.upgradeToAndCall(address(new Swap()), "");
        factory = AssetFactory(0xb04eB6b64137d1673D46731C8f84718092c50B0D);
        factory.upgradeToAndCall(address(new AssetFactory()), "");
        issuer = AssetIssuer(0x0306acEb4c20FF33480d90038F8b375cC6A6b66e);
        issuer.upgradeToAndCall(address(new AssetIssuer()), "");
        rebalancer = AssetRebalancer(0x84663e30973D552ac357FD04F3Ac6ebbD495Ab15);
        rebalancer.upgradeToAndCall(address(new AssetRebalancer()), "");
        feeManager = AssetFeeManager(0x2E469365030F068eCB1176a0D5600bA470Cf07A9);
        feeManager.upgradeToAndCall(address(new AssetFeeManager()), "");
        vm.stopPrank();

        WBTC = new MockToken("Wrapped BTC", "WBTC", 8);
        WETH = new MockToken("Wrapped ETH", "WETH", 18);
        vm.startPrank(owner);

        swap.grantRole(swap.MAKER_ROLE(), pmm);
        string[] memory outWhiteAddresses = new string[](2);
        outWhiteAddresses[0] = vm.toString(address(issuer));
        outWhiteAddresses[1] = vm.toString(vault);
        swap.setTakerAddresses(outWhiteAddresses, outWhiteAddresses);
        Token[] memory whiteListTokens = new Token[](2);
        whiteListTokens[0] = Token({
            chain: chain,
            symbol: WBTC.symbol(),
            addr: vm.toString(address(WBTC)),
            decimals: WBTC.decimals(),
            amount: 0
        });
        whiteListTokens[1] = Token({
            chain: chain,
            symbol: WETH.symbol(),
            addr: vm.toString(address(WETH)),
            decimals: WETH.decimals(),
            amount: 0
        });
        swap.addWhiteListTokens(whiteListTokens);
        vm.stopPrank();
    }
}