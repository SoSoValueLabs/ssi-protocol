// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../src/RewardedVoting.sol";
import "../src/StakeToken.sol";
import "./MockPermitToken.sol";
import "./MockToken.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";

contract RewardedVotingTest is Test {
    RewardedVoting voting;
    StakeToken stakeToken;
    MockPermitToken payToken;
    MockToken underlying;

    address owner = vm.addr(0x1);
    address treasury = vm.addr(0x2);
    address airdropPool = vm.addr(0x3);

    uint256 proposerPk = 0x100;
    address proposer = vm.addr(proposerPk);

    uint256 voter1Pk = 0x200;
    address voter1 = vm.addr(voter1Pk);

    uint256 voter2Pk = 0x201;
    address voter2 = vm.addr(voter2Pk);

    uint256 voter3Pk = 0x202;
    address voter3 = vm.addr(voter3Pk);

    uint256 constant PAY_DECIMALS = 18;
    uint256 constant PAY_AMOUNT = 1000 * 1e18;
    uint256 constant VOTER_STAKE = 5000 * 1e18;

    function setUp() public {
        underlying = new MockToken("Underlying", "UND", 18);
        payToken = new MockPermitToken("Pay Token", "PAY", 18);

        vm.startPrank(owner);

        StakeToken stakeImpl = new StakeToken();
        stakeToken = StakeToken(payable(address(new ERC1967Proxy(
            address(stakeImpl),
            abi.encodeCall(StakeToken.initialize, ("Staked UND", "sUND", address(underlying), 3600 * 24 * 7, owner))
        ))));

        RewardedVoting votingImpl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        voting = RewardedVoting(address(new ERC1967Proxy(
            address(votingImpl),
            abi.encodeCall(RewardedVoting.initialize, (
                config, treasury, airdropPool, owner
            ))
        )));

        stakeToken.grantLockerRole(address(voting));
        vm.stopPrank();

        _setupProposer(proposer, PAY_AMOUNT * 10);
        _setupVoter(voter1, VOTER_STAKE);
        _setupVoter(voter2, VOTER_STAKE);
        _setupVoter(voter3, VOTER_STAKE);
    }

    function _setupProposer(address user, uint256 amount) internal {
        payToken.mint(user, amount);
        vm.prank(user);
        payToken.approve(address(voting), type(uint256).max);
    }

    function _setupVoter(address voter, uint256 amount) internal {
        underlying.mint(voter, amount);
        vm.startPrank(voter);
        underlying.approve(address(stakeToken), amount);
        stakeToken.stake(amount);
        vm.stopPrank();
    }

    function _createDefaultProposal(uint256 proposalId) internal {
        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, proposalId);
    }

    function _voteApprove(address voter, uint256 proposalId, uint256 amount) internal {
        vm.prank(voter);
        voting.vote(proposalId, amount, true);
    }

    function _voteReject(address voter, uint256 proposalId, uint256 amount) internal {
        vm.prank(voter);
        voting.vote(proposalId, amount, false);
    }

    function _skipVotingPeriod() internal {
        vm.warp(block.timestamp + voting.getVotingConfig().votingDuration + 1);
    }

    // ========== Initialization Tests ==========

    function _defaultConfig() internal view returns (RewardedVoting.VotingConfig memory) {
        return RewardedVoting.VotingConfig({
            votingToken: address(stakeToken),
            payToken: address(payToken),
            voterFeeBps: 500,
            protocolFeeBps: 2500,
            minApproveRatio: 8000,
            votingDuration: 24 hours,
            voteLockDuration: 48 hours,
            minVoteAmount: 3000 * 1e18,
            minPayAmount: 100 * 1e18,
            maxVoterRewardIfRejected: 100 * 1e18
        });
    }

    function testInitialize() public view {
        assertEq(voting.treasury(), treasury);
        assertEq(voting.airdropPool(), airdropPool);
        assertEq(voting.owner(), owner);

        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        assertEq(config.votingToken, address(stakeToken));
        assertEq(config.payToken, address(payToken));
        assertEq(config.voterFeeBps, 500);
        assertEq(config.protocolFeeBps, 2500);
        assertEq(config.minApproveRatio, 8000);
        assertEq(config.votingDuration, 24 hours);
        assertEq(config.voteLockDuration, 48 hours);
        assertEq(config.minVoteAmount, 3000 * 1e18);
        assertEq(config.minPayAmount, 100 * 1e18);
        assertEq(config.maxVoterRewardIfRejected, 100 * 1e18);
    }

    function testInitializeZeroVotingToken() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.votingToken = address(0);
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroPayToken() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.payToken = address(0);
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroTreasury() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, address(0), airdropPool, owner))
        );
    }

    function testInitializeZeroAirdropPool() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, address(0), owner))
        );
    }

    function testInitializeZeroVoterFeeBps() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.voterFeeBps = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "voterFeeBps must be > 0"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeExcessiveFeeBps() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.voterFeeBps = 5000;
        config.protocolFeeBps = 5001;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "total fee bps exceeds 100%"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeInvalidMinApproveRatio() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.minApproveRatio = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minApproveRatio out of range"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );

        config.minApproveRatio = 10001;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minApproveRatio out of range"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroVotingDuration() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.votingDuration = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "votingDuration must be > 0"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroVoteLockDuration() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.voteLockDuration = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "voteLockDuration must be > 0"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeVoteLockDurationLessThanVotingDuration() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.voteLockDuration = config.votingDuration - 1;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "voteLockDuration must be >= votingDuration"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroMinPayAmount() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.minPayAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minPayAmount must be > 0"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    function testInitializeZeroMinVoteAmount() public {
        RewardedVoting impl = new RewardedVoting();
        RewardedVoting.VotingConfig memory config = _defaultConfig();
        config.minVoteAmount = 0;
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minVoteAmount must be > 0"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RewardedVoting.initialize, (config, treasury, airdropPool, owner))
        );
    }

    // ========== Admin Tests ==========

    function testUpdateTreasury() public {
        address newTreasury = vm.addr(0x50);
        vm.prank(owner);
        voting.updateTreasury(newTreasury);
        assertEq(voting.treasury(), newTreasury);
    }

    function testUpdateTreasuryZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        voting.updateTreasury(address(0));
    }

    function testUpdateTreasuryOnlyOwner() public {
        vm.prank(proposer);
        vm.expectRevert();
        voting.updateTreasury(vm.addr(0x50));
    }

    function testUpdateAirdropPool() public {
        address newPool = vm.addr(0x51);
        vm.prank(owner);
        voting.updateAirdropPool(newPool);
        assertEq(voting.airdropPool(), newPool);
    }

    function testUpdateAirdropPoolZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardedVoting.ZeroAddress.selector);
        voting.updateAirdropPool(address(0));
    }

    function testPauseUnpause() public {
        vm.startPrank(owner);
        voting.pause();
        assertTrue(voting.paused());
        vm.stopPrank();

        vm.prank(proposer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        voting.createProposal(PAY_AMOUNT, 1);

        vm.prank(owner);
        voting.unpause();
        assertFalse(voting.paused());

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);
    }

    // ========== UpdateVoteConfig Tests ==========

    function testUpdateVoteConfig() public {
        RewardedVoting.VotingConfig memory oldConfig = voting.getVotingConfig();
        RewardedVoting.VotingConfig memory newConfig = RewardedVoting.VotingConfig({
            votingToken: oldConfig.votingToken,
            payToken: oldConfig.payToken,
            voterFeeBps: 1000,
            protocolFeeBps: 2000,
            minApproveRatio: 6000,
            votingDuration: 48 hours,
            voteLockDuration: 96 hours,
            minVoteAmount: 5000 * 1e18,
            minPayAmount: 200 * 1e18,
            maxVoterRewardIfRejected: 50 * 1e18
        });
        vm.prank(owner);
        voting.updateVotingConfig(newConfig);

        RewardedVoting.VotingConfig memory stored = voting.getVotingConfig();
        assertEq(stored.votingToken, oldConfig.votingToken);
        assertEq(stored.payToken, oldConfig.payToken);
        assertEq(stored.voterFeeBps, 1000);
        assertEq(stored.protocolFeeBps, 2000);
        assertEq(stored.minApproveRatio, 6000);
        assertEq(stored.votingDuration, 48 hours);
        assertEq(stored.voteLockDuration, 96 hours);
        assertEq(stored.minVoteAmount, 5000 * 1e18);
        assertEq(stored.minPayAmount, 200 * 1e18);
        assertEq(stored.maxVoterRewardIfRejected, 50 * 1e18);
    }

    function testUpdateVoteConfigOnlyOwner() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        vm.prank(proposer);
        vm.expectRevert();
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigChangeVotingTokenReverts() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.votingToken = vm.addr(0x99);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "votingToken is immutable"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigChangePayTokenReverts() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.payToken = vm.addr(0x99);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "payToken is immutable"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigZeroVoterFeeBps() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.voterFeeBps = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "voterFeeBps must be > 0"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigFeeOverflow() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.voterFeeBps = 5000;
        config.protocolFeeBps = 5001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "total fee bps exceeds 100%"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigInvalidMinApproveRatio() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.minApproveRatio = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minApproveRatio out of range"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigZeroVotingDuration() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.votingDuration = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "votingDuration must be > 0"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigLockDurationLessThanVotingDuration() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.votingDuration = 48 hours;
        config.voteLockDuration = 24 hours;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "voteLockDuration must be >= votingDuration"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigZeroMinPayAmount() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.minPayAmount = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minPayAmount must be > 0"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigZeroMinVoteAmount() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.minVoteAmount = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidConfig.selector, "minVoteAmount must be > 0"));
        voting.updateVotingConfig(config);
    }

    function testUpdateVoteConfigWhilePaused() public {
        vm.prank(owner);
        voting.pause();

        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.voterFeeBps = 1000;
        vm.prank(owner);
        voting.updateVotingConfig(config);

        assertEq(voting.getVotingConfig().voterFeeBps, 1000);
    }

    function testUpdateVoteConfigAffectsNewProposal() public {
        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.minPayAmount = 500 * 1e18;
        config.votingDuration = 48 hours;
        vm.prank(owner);
        voting.updateVotingConfig(config);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InsufficientProposalAmount.selector, 200 * 1e18, 500 * 1e18));
        voting.createProposal(200 * 1e18, 1);

        vm.prank(proposer);
        voting.createProposal(500 * 1e18, 1);

        (,,, uint256 votingEndTime,,,,,) = voting.proposals(1);
        assertEq(votingEndTime, block.timestamp + 48 hours);
    }

    function testUpdateVoteConfigDoesNotAffectInFlightProposal() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);

        RewardedVoting.VotingConfig memory config = voting.getVotingConfig();
        config.voterFeeBps = 2000;
        config.protocolFeeBps = 3000;
        config.minApproveRatio = 9999;
        config.minVoteAmount = 99999 * 1e18;
        config.maxVoterRewardIfRejected = 1;
        vm.prank(owner);
        voting.updateVotingConfig(config);

        _skipVotingPeriod();
        voting.resolveProposal(1);

        (,,RewardedVoting.ProposalState state,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertTrue(state == RewardedVoting.ProposalState.Approved);
        assertEq(dist.voterReward, PAY_AMOUNT * 500 / 10000);
        assertEq(dist.protocolFee, PAY_AMOUNT * 2500 / 10000);
    }

    // ========== Proposal Creation Tests ==========

    function testCreateProposal() public {
        uint256 balBefore = payToken.balanceOf(proposer);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);

        (
            address p_proposer,
            uint256 p_payAmount,
            RewardedVoting.ProposalState p_state,
            uint256 p_votingEndTime,
            ,,,,
        ) = voting.proposals(1);

        assertEq(p_proposer, proposer);
        assertEq(p_payAmount, PAY_AMOUNT);
        assertTrue(p_state == RewardedVoting.ProposalState.Voting);
        assertEq(p_votingEndTime, block.timestamp + voting.getVotingConfig().votingDuration);
        assertEq(payToken.balanceOf(proposer), balBefore - PAY_AMOUNT);
        assertEq(payToken.balanceOf(address(voting)), PAY_AMOUNT);
    }

    function testCreateProposalInsufficientAmount() public {
        uint256 minAmount = voting.getVotingConfig().minPayAmount;
        uint256 tooLow = minAmount - 1;

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(RewardedVoting.InsufficientProposalAmount.selector, tooLow, minAmount)
        );
        voting.createProposal(tooLow, 1);
    }

    function testCreateProposalDuplicateId() public {
        _createDefaultProposal(1);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalAlreadyExists.selector, 1));
        voting.createProposal(PAY_AMOUNT, 1);
    }

    function testCreateProposalWhenPaused() public {
        vm.prank(owner);
        voting.pause();

        vm.prank(proposer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        voting.createProposal(PAY_AMOUNT, 1);
    }

    // ========== Voting Tests ==========

    function testVoteApprove() public {
        _createDefaultProposal(1);
        uint256 voteAmount = 1000 * 1e18;

        _voteApprove(voter1, 1, voteAmount);

        (,,,,uint256 totalApprove, uint256 totalReject,,,) = voting.proposals(1);
        assertEq(totalApprove, voteAmount);
        assertEq(totalReject, 0);

        (bool hasVoted, uint256 supportWeight, uint256 rejectWeight,,) = voting.votes(1, voter1);
        assertTrue(hasVoted);
        assertEq(supportWeight, voteAmount);
        assertEq(rejectWeight, 0);

        assertEq(stakeToken.getAvailableBalance(voter1), VOTER_STAKE - voteAmount);
    }

    function testVoteReject() public {
        _createDefaultProposal(1);
        uint256 voteAmount = 1000 * 1e18;

        _voteReject(voter1, 1, voteAmount);

        (,,,,uint256 totalApprove, uint256 totalReject,,,) = voting.proposals(1);
        assertEq(totalApprove, 0);
        assertEq(totalReject, voteAmount);

        (, uint256 supportWeight, uint256 rejectWeight,,) = voting.votes(1, voter1);
        assertEq(supportWeight, 0);
        assertEq(rejectWeight, voteAmount);
    }

    function testVoteZeroAmount() public {
        _createDefaultProposal(1);

        vm.prank(voter1);
        vm.expectRevert(RewardedVoting.ZeroAmount.selector);
        voting.vote(1, 0, true);
    }

    function testVoteInsufficientVotingPower() public {
        _createDefaultProposal(1);

        vm.prank(voter1);
        vm.expectRevert(RewardedVoting.InsufficientVotingPower.selector);
        voting.vote(1, VOTER_STAKE + 1, true);
    }

    function testVoteAfterVotingEnds() public {
        _createDefaultProposal(1);
        _skipVotingPeriod();

        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.VotingPeriodEnded.selector, 1));
        voting.vote(1, 1000 * 1e18, true);
    }

    function testVoteNonExistentProposal() public {
        vm.prank(voter1);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalNotInVotingState.selector, 999));
        voting.vote(999, 1000 * 1e18, true);
    }

    function testVoteMultipleTimes() public {
        _createDefaultProposal(1);
        uint256 vote1 = 1000 * 1e18;
        uint256 vote2 = 500 * 1e18;

        _voteApprove(voter1, 1, vote1);
        _voteApprove(voter1, 1, vote2);

        (, uint256 supportWeight,,,) = voting.votes(1, voter1);
        assertEq(supportWeight, vote1 + vote2);

        (,,,,uint256 totalApprove,,,,) = voting.proposals(1);
        assertEq(totalApprove, vote1 + vote2);
    }

    function testVoteMultipleVoters() public {
        _createDefaultProposal(1);
        uint256 amount = 1000 * 1e18;

        _voteApprove(voter1, 1, amount);
        _voteApprove(voter2, 1, amount);
        _voteReject(voter3, 1, amount);

        (,,,,uint256 totalApprove, uint256 totalReject,,,) = voting.proposals(1);
        assertEq(totalApprove, amount * 2);
        assertEq(totalReject, amount);
    }

    function testVoteWhenPaused() public {
        _createDefaultProposal(1);

        vm.prank(owner);
        voting.pause();

        vm.prank(voter1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        voting.vote(1, 1000 * 1e18, true);
    }

    // ========== Resolution Tests ==========

    function testResolveApproved() public {
        _createDefaultProposal(1);

        uint256 voteAmount = 4000 * 1e18;
        _voteApprove(voter1, 1, voteAmount);

        _skipVotingPeriod();

        uint256 treasuryBefore = payToken.balanceOf(treasury);
        uint256 airdropBefore = payToken.balanceOf(airdropPool);

        voting.resolveProposal(1);

        (,,RewardedVoting.ProposalState state,,,,bool resolved, RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertTrue(state == RewardedVoting.ProposalState.Approved);
        assertTrue(resolved);

        uint256 expectedVoterReward = PAY_AMOUNT * 500 / 10000;
        uint256 expectedProtocolFee = PAY_AMOUNT * 2500 / 10000;
        uint256 expectedAirdrop = PAY_AMOUNT - expectedVoterReward - expectedProtocolFee;

        assertEq(dist.voterReward, expectedVoterReward);
        assertEq(dist.protocolFee, expectedProtocolFee);
        assertEq(dist.airdropReward, expectedAirdrop);

        assertEq(payToken.balanceOf(treasury), treasuryBefore + expectedProtocolFee);
        assertEq(payToken.balanceOf(airdropPool), airdropBefore + expectedAirdrop);
    }

    function testResolveRejectedLowApproval() public {
        _createDefaultProposal(1);

        _voteApprove(voter1, 1, 2000 * 1e18);
        _voteReject(voter2, 1, 2000 * 1e18);

        _skipVotingPeriod();

        uint256 proposerBefore = payToken.balanceOf(proposer);

        voting.resolveProposal(1);

        (,,RewardedVoting.ProposalState state,,,,bool resolved, RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertTrue(state == RewardedVoting.ProposalState.Rejected);
        assertTrue(resolved);

        uint256 rejectedCap = voting.getVotingConfig().maxVoterRewardIfRejected;
        uint256 rawVoterReward = PAY_AMOUNT * 500 / 10000;
        uint256 expectedVoterReward = rawVoterReward > rejectedCap ? rejectedCap : rawVoterReward;

        assertEq(dist.voterReward, expectedVoterReward);
        assertEq(dist.protocolFee, 0);
        assertEq(dist.airdropReward, 0);
        assertEq(payToken.balanceOf(proposer), proposerBefore + PAY_AMOUNT - expectedVoterReward);
    }

    function testResolveRejectedInsufficientTotalVotes() public {
        _createDefaultProposal(1);

        uint256 minVoteWeight = voting.getVotingConfig().minVoteAmount;
        uint256 tooFewVotes = minVoteWeight - 1;

        _voteApprove(voter1, 1, tooFewVotes);

        _skipVotingPeriod();

        voting.resolveProposal(1);

        (,,RewardedVoting.ProposalState state,,,,,,) = voting.proposals(1);
        assertTrue(state == RewardedVoting.ProposalState.Rejected);
    }

    function testResolveNoVotes() public {
        _createDefaultProposal(1);
        _skipVotingPeriod();

        uint256 proposerBefore = payToken.balanceOf(proposer);

        voting.resolveProposal(1);

        (,,RewardedVoting.ProposalState state,,,,bool resolved, RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertTrue(state == RewardedVoting.ProposalState.NoVotes);
        assertTrue(resolved);
        assertEq(dist.voterReward, 0);
        assertEq(dist.refund, PAY_AMOUNT);
        assertEq(payToken.balanceOf(proposer), proposerBefore + PAY_AMOUNT);
    }

    function testResolveBeforeVotingEnds() public {
        _createDefaultProposal(1);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.VotingPeriodNotEnded.selector, 1));
        voting.resolveProposal(1);
    }

    function testResolveAlreadyResolved() public {
        _createDefaultProposal(1);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalNotInVotingState.selector, 1));
        voting.resolveProposal(1);
    }

    function testResolveRejectedVoterRewardCap() public {
        _createDefaultProposal(1);

        _voteReject(voter1, 1, 4000 * 1e18);

        _skipVotingPeriod();

        voting.resolveProposal(1);

        (,,,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);

        uint256 rawReward = PAY_AMOUNT * 500 / 10000;
        uint256 cap = voting.getVotingConfig().maxVoterRewardIfRejected;
        assertEq(dist.voterReward, rawReward > cap ? cap : rawReward);
    }

    function testResolveWhenPaused() public {
        _createDefaultProposal(1);
        _skipVotingPeriod();

        vm.prank(owner);
        voting.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        voting.resolveProposal(1);
    }

    // ========== Reward Claim Tests ==========

    function testClaimReward() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        uint256 preview = voting.previewReward(1, voter1);
        uint256 balBefore = payToken.balanceOf(voter1);

        voting.claimRewardFor(1, voter1);

        assertEq(payToken.balanceOf(voter1), balBefore + preview);

        (,,,bool rewardClaimed, uint256 reward) = voting.votes(1, voter1);
        assertTrue(rewardClaimed);
        assertEq(reward, preview);
    }

    function testClaimRewardMultipleVoters() public {
        _createDefaultProposal(1);
        uint256 v1Amount = 3000 * 1e18;
        uint256 v2Amount = 1000 * 1e18;
        _voteApprove(voter1, 1, v1Amount);
        _voteApprove(voter2, 1, v2Amount);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        (,,,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);

        uint256 reward1 = voting.previewReward(1, voter1);
        uint256 reward2 = voting.previewReward(1, voter2);

        assertEq(reward1, v1Amount * dist.voterReward / (v1Amount + v2Amount));
        assertEq(reward2, v2Amount * dist.voterReward / (v1Amount + v2Amount));

        voting.claimRewardFor(1, voter1);
        voting.claimRewardFor(1, voter2);

        assertEq(payToken.balanceOf(voter1), reward1);
        assertEq(payToken.balanceOf(voter2), reward2);
    }

    function testClaimRewardAlreadyClaimed() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);
        voting.claimRewardFor(1, voter1);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.RewardAlreadyClaimed.selector, 1, voter1));
        voting.claimRewardFor(1, voter1);
    }

    function testClaimRewardZeroRounding() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _voteApprove(voter2, 1, 1);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        uint256 preview = voting.previewReward(1, voter2);
        assertEq(preview, 0);

        voting.claimRewardFor(1, voter2);

        (,,,bool rewardClaimed, uint256 reward) = voting.votes(1, voter2);
        assertTrue(rewardClaimed);
        assertEq(reward, 0);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.RewardAlreadyClaimed.selector, 1, voter2));
        voting.claimRewardFor(1, voter2);
    }

    function testClaimRewardNotVoted() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.NotVoted.selector, 1, voter2));
        voting.claimRewardFor(1, voter2);
    }

    function testClaimRewardNotResolved() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalNotResolved.selector, 1));
        voting.claimRewardFor(1, voter1);
    }

    function testPreviewReward() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        uint256 preview = voting.previewReward(1, voter1);
        (,,,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertEq(preview, dist.voterReward);
    }

    function testBatchClaimReward() public {
        _createDefaultProposal(1);
        _createDefaultProposal(2);

        // Vote 2500 on each proposal (total 5000 across both, within voter1's stake)
        // Both will be rejected (below MIN_VOTE_AMOUNT threshold) but voter gets rewards
        _voteApprove(voter1, 1, 2500 * 1e18);
        _voteApprove(voter1, 2, 2500 * 1e18);

        _skipVotingPeriod();
        voting.resolveProposal(1);
        voting.resolveProposal(2);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;

        uint256 balBefore = payToken.balanceOf(voter1);
        uint256 reward1 = voting.previewReward(1, voter1);
        uint256 reward2 = voting.previewReward(2, voter1);

        voting.batchClaimRewardFor(ids, voter1);

        assertEq(payToken.balanceOf(voter1), balBefore + reward1 + reward2);
    }

    // ========== View Function Tests ==========

    function testGetVotedCount() public {
        _createDefaultProposal(1);
        _createDefaultProposal(2);

        _voteApprove(voter1, 1, 1000 * 1e18);
        assertEq(voting.getVotedCount(voter1), 1);

        _voteApprove(voter1, 2, 1000 * 1e18);
        assertEq(voting.getVotedCount(voter1), 2);
    }

    function testGetClaimedCount() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        assertEq(voting.getClaimedCount(voter1), 0);
        voting.claimRewardFor(1, voter1);
        assertEq(voting.getClaimedCount(voter1), 1);
    }

    function testGetClaimedReward() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        uint256 reward = voting.previewReward(1, voter1);
        voting.claimRewardFor(1, voter1);

        assertEq(voting.getClaimedReward(voter1), reward);
    }

    function testListVotedRecords() public {
        _createDefaultProposal(1);
        _createDefaultProposal(2);

        _voteApprove(voter1, 1, 1000 * 1e18);
        _voteApprove(voter1, 2, 2000 * 1e18);

        (uint256[] memory ids, RewardedVoting.VoteRecord[] memory records) = voting.listVotedRecords(voter1, 0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(records[0].supportWeight, 1000 * 1e18);
        assertEq(records[1].supportWeight, 2000 * 1e18);
    }

    function testListVotedRecordsWithPreviewReward() public {
        _createDefaultProposal(1);
        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        (, RewardedVoting.VoteRecord[] memory records) = voting.listVotedRecords(voter1, 0, 1);
        assertGt(records[0].reward, 0);
    }

    function testListVotedRecordsInvalidRange() public {
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidRange.selector, 0, 1));
        voting.listVotedRecords(voter1, 0, 1);
    }

    function testListClaimedProposalIds() public {
        _createDefaultProposal(1);
        _createDefaultProposal(2);
        _voteApprove(voter1, 1, 2500 * 1e18);
        _voteApprove(voter1, 2, 2500 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);
        voting.resolveProposal(2);
        voting.claimRewardFor(1, voter1);
        voting.claimRewardFor(2, voter1);

        uint256[] memory ids = voting.listClaimedProposalIds(voter1, 0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function testListClaimedProposalIdsInvalidRange() public {
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidRange.selector, 0, 1));
        voting.listClaimedProposalIds(voter1, 0, 1);
    }

    // ========== Renew Proposal Tests ==========

    function _approveAndResolve(uint256 proposalId) internal {
        _voteApprove(voter1, proposalId, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(proposalId);
    }

    function testRenewProposal() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        uint256 renewAmount = PAY_AMOUNT;
        uint256 treasuryBefore = payToken.balanceOf(treasury);
        uint256 airdropBefore = payToken.balanceOf(airdropPool);

        vm.prank(proposer);
        voting.createProposal(renewAmount, 1);

        uint256 expectedVoterReward = renewAmount * 500 / 10000;
        uint256 expectedProtocolFee = renewAmount * 2500 / 10000;
        uint256 expectedAirdrop = renewAmount - expectedVoterReward - expectedProtocolFee;

        assertEq(payToken.balanceOf(treasury), treasuryBefore + expectedProtocolFee);
        assertEq(payToken.balanceOf(airdropPool), airdropBefore + expectedAirdrop);

        (,uint256 totalPay,,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);
        assertEq(totalPay, PAY_AMOUNT + renewAmount);

        uint256 origVoterReward = PAY_AMOUNT * 500 / 10000;
        assertEq(dist.voterReward, origVoterReward + expectedVoterReward);
    }

    function testRenewProposalNotApproved() public {
        _createDefaultProposal(1);

        // Voting state → ProposalAlreadyExists
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalAlreadyExists.selector, 1));
        voting.createProposal(PAY_AMOUNT, 1);

        // Rejected state → ProposalAlreadyExists
        _voteReject(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalAlreadyExists.selector, 1));
        voting.createProposal(PAY_AMOUNT, 1);

        // NoVotes state → ProposalAlreadyExists
        _createDefaultProposal(2);
        _skipVotingPeriod();
        voting.resolveProposal(2);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ProposalAlreadyExists.selector, 2));
        voting.createProposal(PAY_AMOUNT, 2);
    }

    function testRenewProposalInsufficientAmount() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        uint256 minAmount = voting.getVotingConfig().minPayAmount;
        uint256 tooLow = minAmount - 1;

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InsufficientProposalAmount.selector, tooLow, minAmount));
        voting.createProposal(tooLow, 1);
    }

    function testRenewProposalNotProposer() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        payToken.mint(voter1, PAY_AMOUNT);
        vm.startPrank(voter1);
        payToken.approve(address(voting), PAY_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.NotProposer.selector, 1));
        voting.createProposal(PAY_AMOUNT, 1);
        vm.stopPrank();
    }

    function testRenewProposalClaimDelta() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        uint256 firstReward = voting.previewReward(1, voter1);
        voting.claimRewardFor(1, voter1);
        assertEq(payToken.balanceOf(voter1), firstReward);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);

        uint256 newTotalReward = voting.previewReward(1, voter1);
        assertGt(newTotalReward, firstReward);

        uint256 balBefore = payToken.balanceOf(voter1);
        voting.claimRewardFor(1, voter1);
        assertEq(payToken.balanceOf(voter1), balBefore + (newTotalReward - firstReward));
    }

    function testRenewProposalMultipleVotersClaimDelta() public {
        _createDefaultProposal(1);
        uint256 v1Amount = 3000 * 1e18;
        uint256 v2Amount = 1000 * 1e18;
        _voteApprove(voter1, 1, v1Amount);
        _voteApprove(voter2, 1, v2Amount);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        voting.claimRewardFor(1, voter1);
        voting.claimRewardFor(1, voter2);
        uint256 v1First = payToken.balanceOf(voter1);
        uint256 v2First = payToken.balanceOf(voter2);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);

        uint256 v1NewTotal = voting.previewReward(1, voter1);
        uint256 v2NewTotal = voting.previewReward(1, voter2);

        voting.claimRewardFor(1, voter1);
        voting.claimRewardFor(1, voter2);

        assertEq(payToken.balanceOf(voter1), v1First + (v1NewTotal - v1First));
        assertEq(payToken.balanceOf(voter2), v2First + (v2NewTotal - v2First));
        assertEq(v1NewTotal * v2Amount, v2NewTotal * v1Amount);
    }

    function testRenewProposalMultipleRenewals() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        voting.claimRewardFor(1, voter1);
        uint256 claimed1 = payToken.balanceOf(voter1);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);
        voting.claimRewardFor(1, voter1);
        uint256 claimed2 = payToken.balanceOf(voter1);
        assertGt(claimed2, claimed1);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);
        voting.claimRewardFor(1, voter1);
        uint256 claimed3 = payToken.balanceOf(voter1);
        assertGt(claimed3, claimed2);

        uint256 perRenewReward = PAY_AMOUNT * 500 / 10000;
        assertEq(claimed3, claimed1 + perRenewReward * 2);
    }

    function testRenewProposalWhenPaused() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        vm.prank(owner);
        voting.pause();

        vm.prank(proposer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        voting.createProposal(PAY_AMOUNT, 1);
    }

    function testRenewProposalPreviewRewardUpdated() public {
        _createDefaultProposal(1);
        _approveAndResolve(1);

        uint256 rewardBefore = voting.previewReward(1, voter1);

        vm.prank(proposer);
        voting.createProposal(PAY_AMOUNT, 1);

        uint256 rewardAfter = voting.previewReward(1, voter1);
        assertEq(rewardAfter, rewardBefore * 2);
    }

    // ========== EIP-712 Meta-Transaction Tests ==========

    function testVoteFor() public {
        _createDefaultProposal(1);

        uint256 amount = 1000 * 1e18;
        bool support = true;
        uint256 nonce = voting.nonces(voter1);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = voting.hashVote(1, amount, support, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(voter1Pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        voting.voteFor(1, amount, support, nonce, deadline, signature);

        (, uint256 supportWeight,,,) = voting.votes(1, voter1);
        assertEq(supportWeight, amount);
        assertEq(voting.nonces(voter1), nonce + 1);
    }

    function testVoteForExpiredSignature() public {
        _createDefaultProposal(1);

        uint256 amount = 1000 * 1e18;
        uint256 nonce = voting.nonces(voter1);
        uint256 deadline = block.timestamp - 1;

        bytes32 digest = voting.hashVote(1, amount, true, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(voter1Pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.ExpiredSignature.selector, deadline));
        voting.voteFor(1, amount, true, nonce, deadline, signature);
    }

    function testVoteForInvalidNonce() public {
        _createDefaultProposal(1);

        uint256 amount = 1000 * 1e18;
        uint256 wrongNonce = 999;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = voting.hashVote(1, amount, true, wrongNonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(voter1Pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(RewardedVoting.InvalidNonce.selector, voter1, 0, wrongNonce));
        voting.voteFor(1, amount, true, wrongNonce, deadline, signature);
    }

    function testCreateProposalFor() public {
        uint256 payAmount = PAY_AMOUNT;
        uint256 proposalId = 42;
        uint256 deadline = block.timestamp + 1 hours;

        // Step 1: Create permit signature for payToken allowance
        bytes32 permitHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                payToken.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(
                    keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                    proposer,
                    address(voting),
                    payAmount,
                    payToken.nonces(proposer),
                    deadline
                ))
            )
        );
        (uint8 pv, bytes32 pr, bytes32 ps) = vm.sign(proposerPk, permitHash);

        // Step 2: Create EIP-712 meta-tx signature
        uint256 nonce = voting.nonces(proposer);
        bytes32 digest = voting.hashCreateProposal(payAmount, proposalId, pv, pr, ps, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(proposerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Reset allowance so permit is needed
        vm.prank(proposer);
        payToken.approve(address(voting), 0);

        voting.createProposalFor(payAmount, proposalId, pv, pr, ps, nonce, deadline, signature);

        (address p_proposer,,RewardedVoting.ProposalState p_state,,,,,,) = voting.proposals(proposalId);
        assertEq(p_proposer, proposer);
        assertTrue(p_state == RewardedVoting.ProposalState.Voting);
    }

    // ========== Fee Calculation Accuracy ==========

    function testFeeCalculationPrecision() public {
        uint256 payAmount = 1000 * 1e18;
        _createDefaultProposal(1);

        _voteApprove(voter1, 1, 4000 * 1e18);
        _skipVotingPeriod();
        voting.resolveProposal(1);

        (,,,,,,,RewardedVoting.ProposalDistribution memory dist,) = voting.proposals(1);

        assertEq(dist.voterReward, 50 * 1e18);
        assertEq(dist.protocolFee, 250 * 1e18);
        assertEq(dist.airdropReward, 700 * 1e18);
        assertEq(dist.voterReward + dist.protocolFee + dist.airdropReward, payAmount);
    }
}
