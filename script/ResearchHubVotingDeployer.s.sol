// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {StakeToken} from "../src/StakeToken.sol";
import {ResearchHubVoting} from "../src/ResearchHubVoting.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys `ResearchHubVoting` behind an ERC1967 (UUPS) proxy.
/// @dev Required env:
///      - OWNER        : owner of the voting contract (admin + UUPS upgrades)
///      - VOTE_TOKEN   : sSOSO StakeToken address used to lock voting power
///      Optional env:
///      - ISSUER       : address to authorize as issuer (default: skip)
///      - GRANT_LOCKER : grant the voting contract the locker role on VOTE_TOKEN (default: true).
///                       Requires the broadcaster to be the StakeToken owner.
contract ResearchHubVotingDeployerScript is Script {
    function setUp() public {}

    function run() public {
        address owner = vm.envAddress("OWNER");
        address voteToken = vm.envAddress("VOTE_TOKEN");
        address issuer = vm.envOr("ISSUER", address(0));
        bool grantLocker = vm.envOr("GRANT_LOCKER", true);

        vm.startBroadcast();

        ResearchHubVoting votingImpl = new ResearchHubVoting();
        address voting = address(new ERC1967Proxy(
            address(votingImpl),
            abi.encodeCall(ResearchHubVoting.initialize, (voteToken, owner))
        ));

        // Let the voting contract lock/unlock voting power on the StakeToken.
        if (grantLocker) {
            try StakeToken(payable(voteToken)).grantLockerRole(voting) {} catch {}
        }
        // Optionally authorize an initial issuer (only succeeds if broadcaster == owner).
        if (issuer != address(0)) {
            try ResearchHubVoting(voting).grantIssuerRole(issuer) {} catch {}
        }

        vm.stopBroadcast();

        console.log(string.concat("votingImpl=", vm.toString(address(votingImpl))));
        console.log(string.concat("voting=", vm.toString(voting)));
        console.log(string.concat("voteToken=", vm.toString(voteToken)));
        console.log(string.concat("votingIsLocker=", vm.toString(StakeToken(payable(voteToken)).lockers(voting))));
        if (issuer != address(0)) {
            console.log(string.concat("issuerAuthorized=", vm.toString(ResearchHubVoting(voting).issuers(issuer))));
        }
    }
}
