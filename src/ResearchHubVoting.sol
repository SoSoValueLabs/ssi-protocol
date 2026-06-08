// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {ILockable} from "./Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

/// @title ResearchHubVoting
/// @notice Approval-only voting for asset issuance proposals.
///         An issuer creates a proposal; anyone votes "approve" by locking voting tokens
///         (sSOSO `StakeToken`, via `ILockable.lock`). Voters can withdraw (unlock) their
///         votes at any time. The issuer may end voting at any time; once ended, voters can
///         only withdraw.
/// @dev
/// - Voting power is locked/released through `ILockable.lock(user, amount)` / `unlock(user, amount)`.
///   This contract must be granted the locker role on the voting token.
/// - On-chain bookkeeping (`voterCount`, `totalVotes`, per-voter `votes`) is a live snapshot.
///   Authoritative per-voter weight (amount x duration) is computed off-chain from the
///   `Voted` / `VoteWithdrawn` events (which carry block timestamps) together with the token's
///   `BalanceLocked` / `BalanceUnlocked` events.
contract ResearchHubVoting is Initializable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardTransientUpgradeable {
    /// @notice Lifecycle states of a proposal.
    enum ProposalState {
        /// @notice Proposal does not exist (default).
        NonExistent,
        /// @notice Voting is open: votes can be cast or withdrawn.
        Voting,
        /// @notice Voting ended by the issuer: only withdrawals are allowed.
        VotingEnded
    }

    /// @notice Proposal metadata and live voting totals.
    struct Proposal {
        /// @notice Creator of the proposal (the issuer); only this address can end voting.
        address issuer;
        /// @notice Current lifecycle state.
        ProposalState state;
        /// @notice Number of voters currently holding a non-zero vote (incremented on 0->positive, decremented on positive->0).
        uint256 voterCount;
        /// @notice Sum of all currently locked votes (decreases on withdrawal).
        uint256 totalVotes;
    }

    /// @notice Voting token that supports balance locking (sSOSO `StakeToken`).
    ILockable public voteToken;

    /// @notice Addresses authorized to create issuance proposals.
    mapping(address => bool) public issuers;

    /// @notice Proposal id => proposal data.
    mapping(uint256 => Proposal) public proposals;
    /// @notice Proposal id => voter => current vote amount (also used as the "currently voting" flag).
    mapping(uint256 => mapping(address => uint256)) public votes;
    /// @notice Proposal id => voter => whether the voter has ever voted on this proposal.
    /// @dev Gates the one-time `_participated` push so a voter who fully withdraws and votes
    ///      again is not recorded twice.
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev Voter => list of proposal ids the voter has participated in (pushed once, on first vote).
    mapping(address => uint256[]) private _participated;

    /// @notice Emitted when a proposal is created.
    event ProposalCreated(uint256 indexed proposalId, address indexed issuer);
    /// @notice Emitted when a voter casts (or adds to) an approve vote, locking `amount`.
    /// @param totalVoted The voter's resulting total vote amount on this proposal.
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 amount, uint256 totalVoted);
    /// @notice Emitted when a voter withdraws part/all of their vote, unlocking `amount`.
    /// @param totalVoted The voter's remaining total vote amount on this proposal.
    event VoteWithdrawn(uint256 indexed proposalId, address indexed voter, uint256 amount, uint256 totalVoted);
    /// @notice Emitted when the issuer ends voting.
    event VotingEnded(uint256 indexed proposalId, address indexed issuer, uint256 totalVotes, uint256 voterCount);
    /// @notice Emitted when an address is granted the issuer role.
    event IssuerRoleGranted(address indexed issuer);
    /// @notice Emitted when an address has its issuer role revoked.
    event IssuerRoleRevoked(address indexed issuer);

    error ZeroAddress();
    error ZeroAmount();
    error ProposalAlreadyExists(uint256 proposalId);
    error ProposalNotVoting(uint256 proposalId);
    error ProposalNotExist(uint256 proposalId);
    error NotIssuer(uint256 proposalId);
    error NotAuthorizedIssuer(address account);
    error ExceedsVotedAmount(uint256 proposalId, address voter, uint256 voted, uint256 requested);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable contract.
    /// @param voteToken_ Voting token supporting `ILockable` (must be non-zero).
    /// @param owner_ Owner for admin controls and UUPS upgrades (must be non-zero).
    function initialize(address voteToken_, address owner_) public initializer {
        if (voteToken_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuardTransient_init();
        voteToken = ILockable(voteToken_);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Pauses voting, withdrawals and proposal creation.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes `account` to create issuance proposals.
    function grantIssuerRole(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        issuers[account] = true;
        emit IssuerRoleGranted(account);
    }

    /// @notice Revokes `account`'s authorization to create issuance proposals.
    function revokeIssuerRole(address account) external onlyOwner {
        issuers[account] = false;
        emit IssuerRoleRevoked(account);
    }

    /// @notice Restricts a function to authorized issuers.
    modifier onlyIssuer() {
        if (!issuers[msg.sender]) revert NotAuthorizedIssuer(msg.sender);
        _;
    }

    /// @notice Creates a new asset issuance proposal. The caller becomes the proposal issuer.
    /// @dev Caller must be an authorized issuer (`grantIssuerRole`).
    /// @param proposalId Proposal id to create (must not already exist).
    function createProposal(uint256 proposalId) external onlyIssuer whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.NonExistent) revert ProposalAlreadyExists(proposalId);
        proposal.issuer = msg.sender;
        proposal.state = ProposalState.Voting;
        emit ProposalCreated(proposalId, msg.sender);
    }

    /// @notice Casts (or adds to) an approve vote by locking `amount` of voting power.
    /// @param proposalId Proposal id (must be in `Voting` state).
    /// @param amount Voting weight to lock (must be > 0; must not exceed available balance).
    function vote(uint256 proposalId, uint256 amount) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotVoting(proposalId);
        if (amount == 0) revert ZeroAmount();

        voteToken.lock(msg.sender, amount);

        if (votes[proposalId][msg.sender] == 0) {
            proposal.voterCount += 1;
        }
        if (!hasVoted[proposalId][msg.sender]) {
            hasVoted[proposalId][msg.sender] = true;
            _participated[msg.sender].push(proposalId);
        }
        votes[proposalId][msg.sender] += amount;
        proposal.totalVotes += amount;

        emit Voted(proposalId, msg.sender, amount, votes[proposalId][msg.sender]);
    }

    /// @notice Withdraws part/all of the caller's vote, unlocking `amount` of voting power.
    /// @dev Allowed while voting is open (retract vote) and after it ends (release only).
    /// @param proposalId Proposal id (must exist).
    /// @param amount Amount to withdraw (must be > 0 and <= caller's current vote).
    function withdrawVote(uint256 proposalId, uint256 amount) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state == ProposalState.NonExistent) revert ProposalNotExist(proposalId);
        if (amount == 0) revert ZeroAmount();
        uint256 voted = votes[proposalId][msg.sender];
        if (amount > voted) revert ExceedsVotedAmount(proposalId, msg.sender, voted, amount);

        voteToken.unlock(msg.sender, amount);

        uint256 remaining = voted - amount;
        votes[proposalId][msg.sender] = remaining;
        proposal.totalVotes -= amount;
        if (remaining == 0) {
            proposal.voterCount -= 1;
        }

        emit VoteWithdrawn(proposalId, msg.sender, amount, remaining);
    }

    /// @notice Ends voting for a proposal. Only the proposal's issuer can call.
    /// @dev After ending, `vote` reverts but `withdrawVote` remains available.
    /// @param proposalId Proposal id (must be in `Voting` state).
    function endVoting(uint256 proposalId) external whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotVoting(proposalId);
        if (msg.sender != proposal.issuer) revert NotIssuer(proposalId);
        proposal.state = ProposalState.VotingEnded;
        emit VotingEnded(proposalId, proposal.issuer, proposal.totalVotes, proposal.voterCount);
    }

    /// @notice Returns the full proposal record.
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /// @notice Returns `voter`'s current vote amount on `proposalId`.
    function getVotes(uint256 proposalId, address voter) external view returns (uint256) {
        return votes[proposalId][voter];
    }

    /// @notice Returns the list of distinct proposal ids `voter` has participated in.
    function getParticipatedProposals(address voter) external view returns (uint256[] memory) {
        return _participated[voter];
    }

    /// @notice Returns how many participation entries `voter` has.
    function getParticipatedCount(address voter) external view returns (uint256) {
        return _participated[voter].length;
    }
}
