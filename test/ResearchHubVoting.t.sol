// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/ResearchHubVoting.sol";
import "../src/StakeToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract ResearchHubVotingTest is Test {
    address owner = vm.addr(0x1);
    address issuer = vm.addr(0x2);
    address voter1 = vm.addr(0x10);
    address voter2 = vm.addr(0x11);

    StakeToken stakeToken;
    ResearchHubVoting voting;

    uint256 constant STAKE_AMOUNT = 100 ether;
    uint256 constant PROPOSAL_ID = 1;

    function setUp() public {
        vm.deal(voter1, 1000 ether);
        vm.deal(voter2, 1000 ether);

        vm.startPrank(owner);
        StakeToken stakeImpl = new StakeToken();
        stakeToken = StakeToken(payable(address(new ERC1967Proxy(
            address(stakeImpl),
            abi.encodeCall(StakeToken.initialize, ("Staked SOSO", "sSOSO", address(0), 3600 * 24 * 7, owner))
        ))));

        ResearchHubVoting votingImpl = new ResearchHubVoting();
        voting = ResearchHubVoting(address(new ERC1967Proxy(
            address(votingImpl),
            abi.encodeCall(ResearchHubVoting.initialize, (address(stakeToken), owner))
        )));

        stakeToken.grantLockerRole(address(voting));
        voting.grantIssuerRole(issuer);
        vm.stopPrank();

        vm.prank(voter1);
        stakeToken.stake{value: STAKE_AMOUNT}(STAKE_AMOUNT);
        vm.prank(voter2);
        stakeToken.stake{value: STAKE_AMOUNT}(STAKE_AMOUNT);
    }

    function _createProposal() internal {
        vm.prank(issuer);
        voting.createProposal(PROPOSAL_ID);
    }

    // ========== Initialization ==========

    function testInitializeState() public view {
        assertEq(address(voting.voteToken()), address(stakeToken));
        assertEq(voting.owner(), owner);
    }

    function testInitializeZeroVoteToken() public {
        ResearchHubVoting impl = new ResearchHubVoting();
        vm.expectRevert(ResearchHubVoting.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(ResearchHubVoting.initialize, (address(0), owner)));
    }

    // ========== Proposal Creation ==========

    function testCreateProposal() public {
        vm.expectEmit(true, true, false, false);
        emit ResearchHubVoting.ProposalCreated(PROPOSAL_ID, issuer);

        _createProposal();

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.issuer, issuer);
        assertEq(uint8(p.state), uint8(ResearchHubVoting.ProposalState.Voting));
        assertEq(p.voterCount, 0);
        assertEq(p.totalVotes, 0);
    }

    function testCreateProposalDuplicateReverts() public {
        _createProposal();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.ProposalAlreadyExists.selector, PROPOSAL_ID));
        voting.createProposal(PROPOSAL_ID);
    }

    // ========== Issuer authorization ==========

    function testCreateProposalUnauthorizedReverts() public {
        address stranger = vm.addr(0xBEEF);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.NotAuthorizedIssuer.selector, stranger));
        voting.createProposal(PROPOSAL_ID);
    }

    function testGrantIssuerRole() public {
        address newIssuer = vm.addr(0xC0FFEE);
        assertFalse(voting.issuers(newIssuer));

        vm.expectEmit(true, false, false, false);
        emit ResearchHubVoting.IssuerRoleGranted(newIssuer);
        vm.prank(owner);
        voting.grantIssuerRole(newIssuer);

        assertTrue(voting.issuers(newIssuer));

        vm.prank(newIssuer);
        voting.createProposal(PROPOSAL_ID);
        assertEq(voting.getProposal(PROPOSAL_ID).issuer, newIssuer);
    }

    function testRevokeIssuerRole() public {
        assertTrue(voting.issuers(issuer));

        vm.expectEmit(true, false, false, false);
        emit ResearchHubVoting.IssuerRoleRevoked(issuer);
        vm.prank(owner);
        voting.revokeIssuerRole(issuer);

        assertFalse(voting.issuers(issuer));

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.NotAuthorizedIssuer.selector, issuer));
        voting.createProposal(PROPOSAL_ID);
    }

    function testGrantIssuerRoleOnlyOwner() public {
        vm.prank(issuer);
        vm.expectRevert();
        voting.grantIssuerRole(vm.addr(0xD00D));
    }

    function testGrantIssuerRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(ResearchHubVoting.ZeroAddress.selector);
        voting.grantIssuerRole(address(0));
    }

    // ========== Voting ==========

    function testVoteLocksAndCounts() public {
        _createProposal();

        vm.expectEmit(true, true, false, true);
        emit ResearchHubVoting.Voted(PROPOSAL_ID, voter1, 10 ether, 10 ether);

        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 1);
        assertEq(p.totalVotes, 10 ether);
        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 10 ether);

        // sSOSO locked: available balance reduced, locked recorded against the voting contract.
        assertEq(stakeToken.getAvailableBalance(voter1), STAKE_AMOUNT - 10 ether);
        assertEq(stakeToken.lockedBalances(address(voting), voter1), 10 ether);

        // participation recorded once, with proposal info and the voter's amount
        (
            uint256[] memory participated,
            ResearchHubVoting.Proposal[] memory infos,
            uint256[] memory amounts
        ) = voting.getParticipatedProposals(voter1);
        assertEq(participated.length, 1);
        assertEq(participated[0], PROPOSAL_ID);
        assertEq(infos.length, 1);
        assertEq(infos[0].issuer, issuer);
        assertEq(infos[0].totalVotes, 10 ether);
        assertEq(uint8(infos[0].state), uint8(ResearchHubVoting.ProposalState.Voting));
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 10 ether);
    }

    function testVoteAccumulatesSingleParticipation() public {
        _createProposal();

        vm.startPrank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);
        voting.vote(PROPOSAL_ID, 5 ether);
        vm.stopPrank();

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 1);
        assertEq(p.totalVotes, 15 ether);
        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 15 ether);
        assertEq(voting.getParticipatedCount(voter1), 1);
    }

    function testVoteMultipleVoters() public {
        _createProposal();

        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);
        vm.prank(voter2);
        voting.vote(PROPOSAL_ID, 20 ether);

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 2);
        assertEq(p.totalVotes, 30 ether);
    }

    function testGetParticipatedProposalsAcrossMultiple() public {
        uint256 pid2 = 2;
        vm.startPrank(issuer);
        voting.createProposal(PROPOSAL_ID);
        voting.createProposal(pid2);
        vm.stopPrank();

        vm.startPrank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);
        voting.vote(pid2, 25 ether);
        vm.stopPrank();

        // end the second proposal to vary state
        vm.prank(issuer);
        voting.endVoting(pid2);

        (
            uint256[] memory ids,
            ResearchHubVoting.Proposal[] memory infos,
            uint256[] memory amounts
        ) = voting.getParticipatedProposals(voter1);

        assertEq(ids.length, 2);
        assertEq(infos.length, 2);
        assertEq(amounts.length, 2);

        assertEq(ids[0], PROPOSAL_ID);
        assertEq(amounts[0], 10 ether);
        assertEq(uint8(infos[0].state), uint8(ResearchHubVoting.ProposalState.Voting));

        assertEq(ids[1], pid2);
        assertEq(amounts[1], 25 ether);
        assertEq(infos[1].totalVotes, 25 ether);
        assertEq(uint8(infos[1].state), uint8(ResearchHubVoting.ProposalState.VotingEnded));
    }

    function testVoteZeroAmountReverts() public {
        _createProposal();
        vm.prank(voter1);
        vm.expectRevert(ResearchHubVoting.ZeroAmount.selector);
        voting.vote(PROPOSAL_ID, 0);
    }

    function testVoteNonExistentProposalReverts() public {
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.ProposalNotVoting.selector, PROPOSAL_ID));
        voting.vote(PROPOSAL_ID, 10 ether);
    }

    function testVoteExceedingAvailableReverts() public {
        _createProposal();
        vm.prank(voter1);
        vm.expectRevert("insufficient available");
        voting.vote(PROPOSAL_ID, STAKE_AMOUNT + 1);
    }

    function testLockedVotesBlockUnstake() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 90 ether);

        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(StakeToken.InsufficientAvailableBalance.selector, voter1, 10 ether, 50 ether)
        );
        stakeToken.unstake(50 ether);
    }

    // ========== Withdraw (unlock) during voting ==========

    function testWithdrawPartialDuringVoting() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit ResearchHubVoting.VoteWithdrawn(PROPOSAL_ID, voter1, 4 ether, 6 ether);

        vm.prank(voter1);
        voting.withdrawVote(PROPOSAL_ID, 4 ether);

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 1);
        assertEq(p.totalVotes, 6 ether);
        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 6 ether);
        assertEq(stakeToken.getAvailableBalance(voter1), STAKE_AMOUNT - 6 ether);
    }

    function testWithdrawFullDecrementsVoterCount() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.prank(voter1);
        voting.withdrawVote(PROPOSAL_ID, 10 ether);

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 0);
        assertEq(p.totalVotes, 0);
        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 0);
        assertEq(stakeToken.getAvailableBalance(voter1), STAKE_AMOUNT);
    }

    function testWithdrawExceedsVotedReverts() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.prank(voter1);
        vm.expectRevert(
            abi.encodeWithSelector(ResearchHubVoting.ExceedsVotedAmount.selector, PROPOSAL_ID, voter1, 10 ether, 11 ether)
        );
        voting.withdrawVote(PROPOSAL_ID, 11 ether);
    }

    function testReVoteAfterFullWithdrawNoDuplicateParticipation() public {
        _createProposal();
        vm.startPrank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);
        voting.withdrawVote(PROPOSAL_ID, 10 ether);
        voting.vote(PROPOSAL_ID, 5 ether);
        vm.stopPrank();

        // hasVoted gates the participation push: recorded once even after withdraw + re-vote.
        assertEq(voting.getParticipatedCount(voter1), 1);
        assertTrue(voting.hasVoted(PROPOSAL_ID, voter1));
        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(p.voterCount, 1);
        assertEq(p.totalVotes, 5 ether);
    }

    // ========== Ending voting ==========

    function testEndVotingOnlyIssuer() public {
        _createProposal();
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.NotIssuer.selector, PROPOSAL_ID));
        voting.endVoting(PROPOSAL_ID);
    }

    function testEndVotingEmitsAndBlocksVote() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit ResearchHubVoting.VotingEnded(PROPOSAL_ID, issuer, 10 ether, 1);

        vm.prank(issuer);
        voting.endVoting(PROPOSAL_ID);

        ResearchHubVoting.Proposal memory p = voting.getProposal(PROPOSAL_ID);
        assertEq(uint8(p.state), uint8(ResearchHubVoting.ProposalState.VotingEnded));

        vm.prank(voter2);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.ProposalNotVoting.selector, PROPOSAL_ID));
        voting.vote(PROPOSAL_ID, 5 ether);
    }

    function testEndVotingTwiceReverts() public {
        _createProposal();
        vm.startPrank(issuer);
        voting.endVoting(PROPOSAL_ID);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.ProposalNotVoting.selector, PROPOSAL_ID));
        voting.endVoting(PROPOSAL_ID);
        vm.stopPrank();
    }

    function testWithdrawAllowedAfterVotingEnded() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.prank(issuer);
        voting.endVoting(PROPOSAL_ID);

        // After end, voter can only withdraw (unlock).
        vm.prank(voter1);
        voting.withdrawVote(PROPOSAL_ID, 10 ether);

        assertEq(stakeToken.getAvailableBalance(voter1), STAKE_AMOUNT);
        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 0);

        // and can then unstake the freed balance
        vm.prank(voter1);
        stakeToken.unstake(10 ether);
        assertEq(stakeToken.balanceOf(voter1), STAKE_AMOUNT - 10 ether);
    }

    // ========== Lock/unlock event timing for off-chain weight ==========

    function testLockUnlockEmitsTokenEventsForWeight() public {
        _createProposal();

        vm.expectEmit(true, true, false, true);
        emit StakeToken.BalanceLocked(address(voting), voter1, 10 ether);
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        vm.warp(block.timestamp + 3 days);

        vm.expectEmit(true, true, false, true);
        emit StakeToken.BalanceUnlocked(address(voting), voter1, 10 ether);
        vm.prank(voter1);
        voting.withdrawVote(PROPOSAL_ID, 10 ether);
    }

    // ========== EIP-712 voteFor / withdrawVoteFor ==========

    uint256 constant VOTER1_PK = 0x10; // matches voter1 = vm.addr(0x10)

    function _signVote(uint256 pk, uint256 pid, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory)
    {
        bytes32 digest = voting.hashVote(pid, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signWithdraw(uint256 pk, uint256 pid, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        returns (bytes memory)
    {
        bytes32 digest = voting.hashWithdrawVote(pid, amount, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function testVoteForLocksAndIncrementsNonce() public {
        _createProposal();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = voting.nonces(voter1);
        bytes memory sig = _signVote(VOTER1_PK, PROPOSAL_ID, 10 ether, nonce, deadline);

        // a relayer (voter2) submits voter1's signed vote
        vm.prank(voter2);
        voting.voteFor(PROPOSAL_ID, 10 ether, nonce, deadline, sig);

        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 10 ether);
        assertEq(voting.getProposal(PROPOSAL_ID).totalVotes, 10 ether);
        assertEq(voting.getProposal(PROPOSAL_ID).voterCount, 1);
        assertEq(stakeToken.lockedBalances(address(voting), voter1), 10 ether);
        assertEq(voting.nonces(voter1), nonce + 1);
    }

    function testWithdrawVoteForUnlocks() public {
        _createProposal();
        vm.prank(voter1);
        voting.vote(PROPOSAL_ID, 10 ether);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = voting.nonces(voter1);
        bytes memory sig = _signWithdraw(VOTER1_PK, PROPOSAL_ID, 4 ether, nonce, deadline);

        vm.prank(voter2);
        voting.withdrawVoteFor(PROPOSAL_ID, 4 ether, nonce, deadline, sig);

        assertEq(voting.getVotes(PROPOSAL_ID, voter1), 6 ether);
        assertEq(stakeToken.getAvailableBalance(voter1), STAKE_AMOUNT - 6 ether);
        assertEq(voting.nonces(voter1), nonce + 1);
    }

    function testVoteForExpiredSignatureReverts() public {
        _createProposal();
        vm.warp(1000);
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = voting.nonces(voter1);
        bytes memory sig = _signVote(VOTER1_PK, PROPOSAL_ID, 10 ether, nonce, deadline);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.ExpiredSignature.selector, deadline));
        voting.voteFor(PROPOSAL_ID, 10 ether, nonce, deadline, sig);
    }

    function testVoteForInvalidNonceReverts() public {
        _createProposal();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 expected = voting.nonces(voter1);
        uint256 wrongNonce = expected + 1;
        bytes memory sig = _signVote(VOTER1_PK, PROPOSAL_ID, 10 ether, wrongNonce, deadline);
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.InvalidNonce.selector, voter1, expected, wrongNonce));
        voting.voteFor(PROPOSAL_ID, 10 ether, wrongNonce, deadline, sig);
    }

    function testVoteForReplayReverts() public {
        _createProposal();
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = voting.nonces(voter1);
        bytes memory sig = _signVote(VOTER1_PK, PROPOSAL_ID, 10 ether, nonce, deadline);

        voting.voteFor(PROPOSAL_ID, 10 ether, nonce, deadline, sig);

        // nonce consumed: replay now expects nonce+1
        vm.expectRevert(abi.encodeWithSelector(ResearchHubVoting.InvalidNonce.selector, voter1, nonce + 1, nonce));
        voting.voteFor(PROPOSAL_ID, 10 ether, nonce, deadline, sig);
    }

    receive() external payable {}
}
