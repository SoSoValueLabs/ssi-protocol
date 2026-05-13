// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {StakeToken} from "../src/StakeToken.sol";
import {RewardedVoting} from "../src/RewardedVoting.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RewardedVotingDeployerScript is Script {
    function setUp() public {}

    function run() public {
        address owner = vm.envAddress("OWNER");
        address underlying = vm.envAddress("UNDERLYING_TOKEN");
        string memory stakeTokenName = vm.envString("STAKE_TOKEN_NAME");
        string memory stakeTokenSymbol = vm.envString("STAKE_TOKEN_SYMBOL");
        uint48 cooldown = uint48(vm.envUint("STAKE_COOLDOWN"));

        address payToken = vm.envAddress("PAY_TOKEN");
        address treasury = vm.envAddress("TREASURY");
        address airdropPool = vm.envAddress("AIRDROP_POOL");
        uint256 voterFeeBps = vm.envUint("VOTER_FEE_BPS");
        uint256 protocolFeeBps = vm.envUint("PROTOCOL_FEE_BPS");
        uint256 minApproveRatio = vm.envUint("MIN_APPROVE_RATIO");
        uint256 votingDuration = vm.envUint("VOTING_DURATION");
        uint256 voteLockDuration = vm.envUint("VOTE_LOCK_DURATION");
        uint256 minVoteAmount = vm.envUint("MIN_VOTE_AMOUNT");
        uint256 minPayAmount = vm.envUint("MIN_PAY_AMOUNT");
        uint256 maxVoterRewardIfRejected = vm.envUint("MAX_VOTER_REWARD_IF_REJECTED");

        vm.startBroadcast();

        StakeToken stakeTokenImpl = new StakeToken();
        address stakeToken = address(new ERC1967Proxy(
            address(stakeTokenImpl),
            abi.encodeCall(StakeToken.initialize, (stakeTokenName, stakeTokenSymbol, underlying, cooldown, owner))
        ));

        RewardedVoting votingImpl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = RewardedVoting.VotingConfig({
            votingToken: stakeToken,
            payToken: payToken,
            voterFeeBps: voterFeeBps,
            protocolFeeBps: protocolFeeBps,
            minApproveRatio: minApproveRatio,
            votingDuration: votingDuration,
            voteLockDuration: voteLockDuration,
            minVoteAmount: minVoteAmount,
            minPayAmount: minPayAmount,
            maxVoterRewardIfRejected: maxVoterRewardIfRejected
        });
        address voting = address(new ERC1967Proxy(
            address(votingImpl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        ));

        try StakeToken(payable(stakeToken)).grantLockerRole(voting) {} catch {}

        vm.stopBroadcast();

        console.log(string.concat("stakeTokenImpl=", vm.toString(address(stakeTokenImpl))));
        console.log(string.concat("stakeToken=", vm.toString(stakeToken)));
        console.log(string.concat("votingImpl=", vm.toString(address(votingImpl))));
        console.log(string.concat("voting=", vm.toString(voting)));
        console.log(string.concat("votingIsLocker=", vm.toString(StakeToken(payable(stakeToken)).lockers(voting))));
    }
}
