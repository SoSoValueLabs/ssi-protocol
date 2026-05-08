// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import {ILockable} from "./Interface.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

/// @title RewardedVoting
/// @notice A paid proposal + token-weighted voting system with voter rewards.
/// @dev
/// Workflow:
/// - Proposer deposits `payToken` to create a proposal (directly or via EIP-712 + `permit`).
/// - Voters lock `votingToken` voting power for a fixed duration and vote approve/reject (directly or via EIP-712).
/// - After voting ends, anyone can resolve: distributes fees and refunds depending on outcome.
/// - Voters can claim a pro-rata share of the voter-reward pool after resolution.
///
/// Security notes:
/// - Voting power is enforced via `ILockable.getAvailableBalance` and `ILockable.lock`.
/// - Uses `ReentrancyGuardTransientUpgradeable` and `SafeERC20`.
/// - UUPS upgrade authorization is restricted to owner.
contract RewardedVoting is Initializable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardTransientUpgradeable, EIP712Upgradeable, NoncesUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Basis points charged from `payAmount` and reserved for voter rewards.
    uint256 public constant VOTER_FEE_BPS = 500;
    /// @notice Basis points charged from `payAmount` and sent to `treasury` on approval.
    uint256 public constant PROTOCOL_FEE_BPS = 2500;
    /// @notice Basis points denominator (100% = 10,000 bps).
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @notice Minimum approval ratio required to approve a proposal (in bps).
    uint256 public constant MIN_APPROVE_RATIO = 8000;
    /// @notice Voting window length for each proposal.
    uint256 public constant VOTING_DURATION = 24 hours;
    /// @notice Lock duration applied to voting power on each vote.
    uint256 public constant VOTE_LOCK_DURATION = 48 hours;
    /// @notice Minimum total vote weight (scaled by `votingToken` decimals) required for approval path.
    uint256 public constant MIN_VOTE_AMOUNT = 3000;
    /// @notice Minimum amount of `payToken` required to create a proposal.
    uint256 public constant MIN_PAY_AMOUNT = 100;
    /// @notice Maximum amount of `payToken` voter reward if proposal is rejected.
    uint256 public constant MAX_VOTER_REWARD_IF_REJECTED = 100;

    /// @dev EIP-712 typehash for `createProposalFor`.
    bytes32 public constant CREATE_PROPOSAL_TYPE_HASH = keccak256("CreateProposal(uint256 payAmount,uint256 proposalId,uint8 v,bytes32 r,bytes32 s,uint256 nonce,uint256 deadline)");
    /// @dev EIP-712 typehash for `voteFor`.
    bytes32 public constant VOTE_TYPE_HASH = keccak256("Vote(uint256 proposalId,uint256 amount,bool support,uint256 nonce,uint256 deadline)");

    /// @notice Lifecycle states of a proposal.
    enum ProposalState {
        NonExistent,
        /// @notice Voting is open; votes can be cast and proposal can not be resolved yet.
        Voting,
        /// @notice Proposal passed; funds have been distributed according to approval path.
        Approved,
        /// @notice Proposal failed (or no votes); refunds (if any) have been processed.
        Rejected
    }

    /// @notice Proposal metadata and voting totals.
    struct Proposal {
        /// @notice Proposal creator whose `payToken` deposit is pulled.
        address proposer;
        /// @notice Total deposited amount in `payToken`.
        uint256 payAmount;
        /// @notice Current state of the proposal.
        ProposalState state;
        /// @notice Timestamp when voting ends (inclusive behavior defined by checks in `_vote/resolveProposal`).
        uint256 votingEndTime;
        /// @notice Total approve vote weight accumulated.
        uint256 totalApproveWeight;
        /// @notice Total reject vote weight accumulated.
        uint256 totalRejectWeight;
        /// @notice Whether the proposal has been resolved and payouts/refunds executed.
        bool resolved;
        /// @notice Voter reward pool in `payToken`, fixed when resolved (basis for per-voter `previewReward`).
        uint256 voterReward;
        /// @notice Protocol/platform fee in `payToken` sent to `treasury` when approved; zero otherwise.
        uint256 protocolFee;
        /// @notice Amount in `payToken` sent to `airdropPool` when approved (`payAmount - voterReward - protocolFee`); zero otherwise.
        uint256 airdropReward;
    }

    /// @notice Per-proposal vote aggregation for a given voter.
    struct VoteRecord {
        /// @notice Whether the voter has ever voted on this proposal (used for indexing).
        bool hasVoted;
        /// @notice Total weight the voter cast in support of approval.
        uint256 supportWeight;
        /// @notice Total weight the voter cast in support of rejection.
        uint256 rejectWeight;
        /// @notice Whether the voter has claimed reward for this proposal.
        bool rewardClaimed;
        /// @notice Cached reward amount computed at claim time (or previewed for UI).
        uint256 reward;
    }

    /// @dev Aggregated indexes to support voter history queries.
    struct VoterClaimInfo {
        /// @notice Ordered list of proposal ids the voter has voted on.
        uint256[] votedProposalIds;
        /// @notice Ordered list of proposal ids for which the voter has claimed rewards.
        uint256[] claimedProposalIds;
        /// @notice Cumulative rewards claimed by the voter across all proposals (in `payToken`).
        uint256 claimedReward;
    }

    /// @notice Token used to measure and lock voting power. Must implement `ILockable` and `IERC20Metadata`.
    address public votingToken;
    /// @notice Token deposited by proposers and used for rewards/refunds.
    address public payToken;
    /// @notice Fee recipient when proposals are approved.
    address public treasury;
    /// @notice Recipient of the non-voter fees when proposals are approved.
    address public airdropPool;
    /// @notice Cached decimals of `votingToken`.
    uint8 public votingTokenDecimals;
    /// @notice Cached decimals of `payToken`.
    uint8 public payTokenDecimals;

    /// @notice Mapping of proposal id to proposal data.
    mapping(uint256 proposalId => Proposal proposal) public proposals;
    /// @notice Mapping of proposal id to voter address to vote record.
    mapping(uint256 proposalId => mapping(address voter => VoteRecord voteRecord)) public votes;
    mapping(address voter => VoterClaimInfo voterClaimInfo) private voterClaimInfos;

    /// @notice Emitted when a proposal is created and proposer deposit is collected.
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, uint256 payAmount);
    /// @notice Emitted when a voter casts (or adds to) a vote on a proposal.
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    /// @notice Emitted when a proposal is resolved and final outcome is set.
    event ProposalResolved(uint256 indexed proposalId, ProposalState outcome);
    /// @notice Emitted when a voter claims their reward for a proposal.
    event RewardClaimed(uint256 indexed proposalId, address indexed voter, uint256 amount);
    /// @notice Emitted when treasury address is updated.
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    /// @notice Emitted when airdrop pool address is updated.
    event AirdropPoolUpdated(address oldAirdropPool, address newAirdropPool);

    error ProposalNotInVotingState(uint256 proposalId);
    error VotingPeriodEnded(uint256 proposalId);
    error VotingPeriodNotEnded(uint256 proposalId);
    error InsufficientVotingPower();
    error InsufficientProposalAmount(uint256 amount, uint256 minimum);
    error ProposalNotResolved(uint256 proposalId);
    error RewardAlreadyClaimed(uint256 proposalId, address voter);
    error ZeroAddress();
    error ZeroAmount();
    error NotVoted(uint256 proposalId, address voter);
    error ExpiredSignature(uint256 deadline);
    error InvalidRange(uint256 begin, uint256 end);
    error ProposalAlreadyExists(uint256 proposalId);
    error InvalidNonce(address signer, uint256 expected, uint256 provided);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable contract.
    /// @dev Sets token addresses, pricing, destinations and EIP-712 domain.
    /// @param votingToken_ Token used to measure/lock voting power (must implement `ILockable`).
    /// @param payToken_ Token deposited by proposers and paid out as rewards/refunds.
    /// @param treasury_ Treasury that receives platform fee on approval.
    /// @param airdropPool_ Receiver of the remaining pay amount on approval (after fees).
    /// @param owner_ Owner for admin controls and UUPS upgrades.
    function initialize(
        address votingToken_,
        address payToken_,
        address treasury_,
        address airdropPool_,
        address owner_
    ) public initializer {
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuardTransient_init();
        __EIP712_init("RewardedVoting", "1.0.0");
        __Nonces_init();
        if (votingToken_ == address(0)) {
            revert ZeroAddress();
        }
        votingToken = votingToken_;
        votingTokenDecimals = IERC20Metadata(votingToken_).decimals();
        if (payToken_ == address(0)) {
            revert ZeroAddress();
        }
        payToken = payToken_;
        payTokenDecimals = IERC20Metadata(payToken_).decimals();
        if (treasury_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        emit TreasuryUpdated(address(0), treasury_);
        if (airdropPool_ == address(0)) {
            revert ZeroAddress();
        }
        airdropPool = airdropPool_;
        emit AirdropPoolUpdated(address(0), airdropPool_);
    }

    /// @dev Verifies EIP-712 meta-tx signature, deadline, nonce; consumes nonce for `signer`.
    function _verifyAndConsumeMetaTx(bytes32 digest, uint256 nonce, uint256 deadline, bytes calldata signature)
        internal
        returns (address signer)
    {
        if (deadline < block.timestamp) revert ExpiredSignature(deadline);
        signer = ECDSA.recover(digest, signature);
        uint256 expectedNonce = nonces(signer);
        if (nonce != expectedNonce) revert InvalidNonce(signer, expectedNonce, nonce);
        _useNonce(signer);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Pauses proposal creation, voting, resolution and reward claims.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract.
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /// @notice Updates `treasury`.
    /// @param newTreasury New treasury address (must be non-zero).
    function updateTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert ZeroAddress();
        }
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Updates `airdropPool`.
    /// @param newAirdropPool New airdrop pool address (must be non-zero).
    function updateAirdropPool(address newAirdropPool) external onlyOwner {
        if (newAirdropPool == address(0)) {
            revert ZeroAddress();
        }
        emit AirdropPoolUpdated(airdropPool, newAirdropPool);
        airdropPool = newAirdropPool;
    }

    /// @dev Creates a proposal and transfers proposer deposit to this contract.
    /// @param payAmount Amount of `payToken` to deposit.
    /// @param proposalId Proposal id to create.
    /// @param proposer Proposal creator whose funds are pulled.
    function _createProposal(uint256 payAmount, uint256 proposalId, address proposer) internal {
        uint256 minPayAmount = MIN_PAY_AMOUNT * 10 ** payTokenDecimals;
        if (payAmount < minPayAmount) {
            revert InsufficientProposalAmount(payAmount, minPayAmount);
        }
        if (proposals[proposalId].state != ProposalState.NonExistent) {
            revert ProposalAlreadyExists(proposalId);
        }

        proposals[proposalId] = Proposal({
            proposer: proposer,
            payAmount: payAmount,
            state: ProposalState.Voting,
            votingEndTime: block.timestamp + VOTING_DURATION,
            totalApproveWeight: 0,
            totalRejectWeight: 0,
            resolved: false,
            voterReward: 0,
            protocolFee: 0,
            airdropReward: 0
        });

        IERC20(payToken).safeTransferFrom(proposer, address(this), payAmount);
        emit ProposalCreated(proposalId, proposer, payAmount);
    }

    /// @notice Creates a proposal by transferring `payToken` from caller.
    /// @param payAmount Amount of `payToken` to deposit.
    /// @param proposalId Proposal id to create.
    function createProposal(uint256 payAmount, uint256 proposalId) external nonReentrant whenNotPaused {
        _createProposal(payAmount, proposalId, msg.sender);
    }

    /// @dev Returns EIP-712 digest for `createProposalFor`.
    /// Typed data details (EIP-712):
    /// - Domain:
    ///   - name: "RewardedVoting"
    ///   - version: "1.0.0"
    ///   - chainId: current chain id
    ///   - verifyingContract: this contract address
    /// - PrimaryType: CreateProposal
    /// - TypeHash: `CREATE_PROPOSAL_TYPE_HASH`
    /// - Fields (in order):
    ///   - payAmount (uint256)
    ///   - proposalId (uint256)
    ///   - v (uint8)    (ERC-2612 permit signature v)
    ///   - r (bytes32)  (ERC-2612 permit signature r)
    ///   - s (bytes32)  (ERC-2612 permit signature s)
    ///   - nonce (uint256)    (must equal `nonces(signer)` at signing time)
    ///   - deadline (uint256) (must be >= current timestamp when submitted)
    function hashCreateProposal(uint256 payAmount, uint256 proposalId, uint8 v, bytes32 r, bytes32 s, uint256 nonce, uint256 deadline) public view returns (bytes32 digest) {
        digest = _hashTypedDataV4(keccak256(abi.encode(CREATE_PROPOSAL_TYPE_HASH, payAmount, proposalId, v, r, s, nonce, deadline)));
    }

    /// @notice Creates a proposal on behalf of a signer using EIP-712 signature and ERC-2612 `permit`.
    /// @dev
    /// This call uses TWO signatures:
    /// - An EIP-712 signature (`signature`) authorizing the meta-transaction itself (checked by this contract).
    /// - An ERC-2612 `permit` signature (passed as `v,r,s`) granting allowance for pulling `payToken`.
    ///
    /// How to construct the EIP-712 call parameters:
    /// - Read `nonce = nonces(signer)` from this contract.
    /// - Choose `deadline` (unix timestamp) and ensure it is not expired at submission time.
    /// - Prepare the typed data with domain described in `hashCreateProposal` and message fields exactly matching
    ///   the function arguments (including the permit `v,r,s` values).
    /// - Call `hashCreateProposal` to get the typed data hash.
    /// - Sign the typed data hash to produce `signature` (65-byte `r||s||v`).
    ///
    /// Notes:
    /// - `signature` is NOT the same as permit signature; do not mix them.
    /// - `nonce` is consumed by this contract via `_useNonce(signer)` (independent from token permit nonces).
    /// @param payAmount Amount of `payToken` to deposit.
    /// @param proposalId Proposal id to create.
    /// @param v Signature v of permit signature.
    /// @param r Signature r of permit signature.
    /// @param s Signature s of permit signature.
    /// @param nonce Expected nonce (must match `NoncesUpgradeable` for signer).
    /// @param deadline Signature expiry timestamp.
    /// @param signature ECDSA signature over typed data of createProposal.
    function createProposalFor(uint256 payAmount, uint256 proposalId, uint8 v, bytes32 r, bytes32 s, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant whenNotPaused {
        address signer = _verifyAndConsumeMetaTx(hashCreateProposal(payAmount, proposalId, v, r, s, nonce, deadline), nonce, deadline, signature);
        try IERC20Permit(payToken).permit(signer, address(this), payAmount, deadline, v, r, s) {} catch {}
        _createProposal(payAmount, proposalId, signer);
    }

    /// @dev Casts (or adds to) a vote on a proposal, locking voting power for `VOTE_LOCK_DURATION`.
    function _vote(uint256 proposalId, uint256 amount, bool support, address voter) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotInVotingState(proposalId);
        if (block.timestamp > proposal.votingEndTime) revert VotingPeriodEnded(proposalId);
        if (amount == 0) revert ZeroAmount();
        if (ILockable(votingToken).getAvailableBalance(voter) < amount) revert InsufficientVotingPower();

        ILockable(votingToken).lock(voter, amount, block.timestamp + VOTE_LOCK_DURATION);

        VoteRecord storage voteRecord = votes[proposalId][voter];

        if (support) {
            voteRecord.supportWeight += amount;
            proposal.totalApproveWeight += amount;
        } else {
            voteRecord.rejectWeight += amount;
            proposal.totalRejectWeight += amount;
        }

        if (!voteRecord.hasVoted) {
            voteRecord.hasVoted = true;
            voterClaimInfos[voter].votedProposalIds.push(proposalId);
        }

        emit Voted(proposalId, voter, support, amount);
    }

    /// @notice Votes on a proposal using caller's voting power.
    /// @param proposalId Proposal id.
    /// @param amount Voting weight to lock and cast.
    /// @param support True to approve, false to reject.
    function vote(uint256 proposalId, uint256 amount, bool support) external nonReentrant whenNotPaused {
        _vote(proposalId, amount, support, msg.sender);
    }

    /// @dev Returns EIP-712 digest for `voteFor`.
    /// Typed data details (EIP-712):
    /// - Domain:
    ///   - name: "RewardedVoting"
    ///   - version: "1.0.0"
    ///   - chainId: current chain id
    ///   - verifyingContract: this contract address
    /// - PrimaryType: Vote
    /// - TypeHash: `VOTE_TYPE_HASH`
    /// - Fields (in order):
    ///   - proposalId (uint256)
    ///   - amount (uint256)
    ///   - support (bool)
    ///   - nonce (uint256)    (must equal `nonces(signer)` at signing time)
    ///   - deadline (uint256) (must be >= current timestamp when submitted)
    function hashVote(uint256 proposalId, uint256 amount, bool support, uint256 nonce, uint256 deadline) public view returns (bytes32 digest) {
        digest = _hashTypedDataV4(keccak256(abi.encode(VOTE_TYPE_HASH, proposalId, amount, support, nonce, deadline)));
    }

    /// @notice Votes on behalf of a signer using an EIP-712 signature.
    /// @dev
    /// How to construct the call parameters:
    /// - Read `nonce = nonces(signer)` from this contract.
    /// - Choose `deadline` (unix timestamp) and ensure it is not expired at submission time.
    /// - Prepare typed data with domain described in `hashVote` and message fields:
    ///   `{ proposalId, amount, support, nonce, deadline }`.
    /// - Call `hashVote` to get the typed data hash.
    /// - Sign the typed data hash to produce `signature` (65-byte `r||s||v`).
    ///
    /// Notes:
    /// - The signer does NOT need to approve ERC20; voting power is enforced/locked via `ILockable`.
    /// - `nonce` is consumed by this contract via `_useNonce(signer)`.
    /// @param proposalId Proposal id.
    /// @param amount Voting weight to lock and cast.
    /// @param support True to approve, false to reject.
    /// @param nonce Expected nonce (must match `NoncesUpgradeable` for signer).
    /// @param deadline Signature expiry timestamp.
    /// @param signature ECDSA signature over typed data of vote.
    function voteFor(uint256 proposalId, uint256 amount, bool support, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant whenNotPaused {
        address signer = _verifyAndConsumeMetaTx(hashVote(proposalId, amount, support, nonce, deadline), nonce, deadline, signature);
        _vote(proposalId, amount, support, signer);
    }

    /// @notice Resolves a proposal after voting ends and executes payout/refund logic.
    /// @dev
    /// - If no votes, proposal is rejected and proposer is fully refunded (`voterReward`/`protocolFee`/`airdropReward` all zero).
    /// - Otherwise records `voterReward` (voter pool), and on approval also `protocolFee` and `airdropReward` matching transfers.
    /// - If approval conditions are met, `protocolFee` goes to `treasury`, `airdropReward` to `airdropPool`.
    /// - If rejected with votes, proposer is refunded minus `voterReward`; per-voter shares use stored `voterReward`.
    /// Anyone can call this after voting ends.
    /// @param proposalId Proposal id.
    function resolveProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotInVotingState(proposalId);
        if (block.timestamp <= proposal.votingEndTime) revert VotingPeriodNotEnded(proposalId);

        uint256 totalVoteWeight = proposal.totalApproveWeight + proposal.totalRejectWeight;

        if (totalVoteWeight == 0) {
            proposal.state = ProposalState.Rejected;
            proposal.resolved = true;
            proposal.voterReward = 0;
            proposal.protocolFee = 0;
            proposal.airdropReward = 0;
            IERC20(payToken).safeTransfer(proposal.proposer, proposal.payAmount);
            emit ProposalResolved(proposalId, ProposalState.Rejected);
            return;
        }

        uint256 voterRewardAmt = (proposal.payAmount * VOTER_FEE_BPS) / BPS_DENOMINATOR;

        uint256 minVoteWeight = MIN_VOTE_AMOUNT * 10 ** votingTokenDecimals;
        if (totalVoteWeight >= minVoteWeight && proposal.totalApproveWeight * BPS_DENOMINATOR / totalVoteWeight >= MIN_APPROVE_RATIO) {
            proposal.state = ProposalState.Approved;
            uint256 protocolFeeAmt = (proposal.payAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
            uint256 airdropAmt = proposal.payAmount - voterRewardAmt - protocolFeeAmt;

            proposal.voterReward = voterRewardAmt;
            proposal.protocolFee = protocolFeeAmt;
            proposal.airdropReward = airdropAmt;

            IERC20(payToken).safeTransfer(treasury, protocolFeeAmt);
            IERC20(payToken).safeTransfer(airdropPool, airdropAmt);
        } else {
            proposal.state = ProposalState.Rejected;
            uint256 rejectedCap = MAX_VOTER_REWARD_IF_REJECTED * 10 ** payTokenDecimals;
            if (voterRewardAmt > rejectedCap) voterRewardAmt = rejectedCap;

            proposal.voterReward = voterRewardAmt;
            proposal.protocolFee = 0;
            proposal.airdropReward = 0;

            uint256 refund = proposal.payAmount - voterRewardAmt;
            IERC20(payToken).safeTransfer(proposal.proposer, refund);
        }

        proposal.resolved = true;
        emit ProposalResolved(proposalId, proposal.state);
    }

    /// @notice Previews the reward a voter can claim for a resolved proposal.
    /// @param proposalId Proposal id.
    /// @param voter Voter address.
    /// @return reward Pro-rata share of `proposal.voterReward` based on voter's total weight.
    function previewReward(uint256 proposalId, address voter) public view returns (uint256 reward) {
        Proposal memory proposal = proposals[proposalId];
        if (!proposal.resolved) revert ProposalNotResolved(proposalId);
        if (voter == address(0)) revert ZeroAddress();

        VoteRecord memory record = votes[proposalId][voter];
        if (record.supportWeight == 0 && record.rejectWeight == 0) revert NotVoted(proposalId, voter);

        uint256 totalVoteWeight = proposal.totalApproveWeight + proposal.totalRejectWeight;
        reward = (record.supportWeight + record.rejectWeight) * proposal.voterReward / totalVoteWeight;
    }

    /// @notice Claims reward for `voter` for a resolved proposal.
    /// @dev Can be called by anyone; reward is always paid to `voter`.
    /// @param proposalId Proposal id.
    /// @param voter Voter address that receives the reward.
    function claimRewardFor(uint256 proposalId, address voter) public nonReentrant whenNotPaused {
        VoteRecord storage record = votes[proposalId][voter];
        if (record.rewardClaimed) revert RewardAlreadyClaimed(proposalId, voter);

        uint256 reward = previewReward(proposalId, voter);

        record.reward = reward;
        record.rewardClaimed = true;

        voterClaimInfos[voter].claimedProposalIds.push(proposalId);
        voterClaimInfos[voter].claimedReward += reward;

        if (reward > 0) {
            IERC20(payToken).safeTransfer(voter, reward);
        }

        emit RewardClaimed(proposalId, voter, reward);
    }

    /// @notice Claims rewards for multiple proposals for a voter.
    /// @param proposalIds Proposal ids to claim.
    /// @param voter Voter address that receives rewards.
    function batchClaimRewardFor(uint256[] memory proposalIds, address voter) external {
        for (uint256 i = 0; i < proposalIds.length; i++) {
            claimRewardFor(proposalIds[i], voter);
        }
    }

    /// @notice Returns how many proposals `voter` has participated in.
    function getVotedCount(address voter) external view returns (uint256) {
        return voterClaimInfos[voter].votedProposalIds.length;
    }

    /// @notice Returns how many proposal rewards `voter` has claimed.
    function getClaimedCount(address voter) external view returns (uint256) {
        return voterClaimInfos[voter].claimedProposalIds.length;
    }

    /// @notice Returns total amount of rewards claimed by `voter` across proposals.
    function getClaimedReward(address voter) external view returns (uint256) {
        return voterClaimInfos[voter].claimedReward;
    }

    /// @notice Returns voted proposal ids and corresponding vote records in a range.
    /// @dev If a proposal is already resolved and reward not claimed, `reward` is populated with `previewReward`.
    /// @param voter Voter address.
    /// @param begin Start index (inclusive) in the voter's voted list.
    /// @param end End index (exclusive) in the voter's voted list.
    /// @return proposalIds Proposal ids in the requested range.
    /// @return voteRecords Vote records aligned with `proposalIds`.
    function listVotedRecords(address voter, uint256 begin, uint256 end) external view returns (uint256[] memory proposalIds, VoteRecord[] memory voteRecords) {
        if (begin >= end || begin >= voterClaimInfos[voter].votedProposalIds.length || end > voterClaimInfos[voter].votedProposalIds.length) revert InvalidRange(begin, end);
        proposalIds = new uint256[](end - begin);
        voteRecords = new VoteRecord[](end - begin);
        for (uint256 i = begin; i < end; i++) {
            uint256 proposalId = voterClaimInfos[voter].votedProposalIds[i];
            proposalIds[i - begin] = proposalId;
            VoteRecord memory voteRecord = votes[proposalId][voter];
            if (!voteRecord.rewardClaimed && proposals[proposalId].resolved) {
                voteRecord.reward = previewReward(proposalId, voter);
            }
            voteRecords[i - begin] = voteRecord;
        }
    }

    /// @notice Returns claimed proposal ids for `voter` in a range.
    /// @param voter Voter address.
    /// @param begin Start index (inclusive) in the claimed list.
    /// @param end End index (exclusive) in the claimed list.
    /// @return proposalIds Claimed proposal ids in the requested range.
    function listClaimedProposalIds(address voter, uint256 begin, uint256 end) external view returns (uint256[] memory) {
        if (begin >= end || begin >= voterClaimInfos[voter].claimedProposalIds.length || end > voterClaimInfos[voter].claimedProposalIds.length) revert InvalidRange(begin, end);
        uint256[] memory proposalIds = new uint256[](end - begin);
        for (uint256 i = begin; i < end; i++) {
            proposalIds[i - begin] = voterClaimInfos[voter].claimedProposalIds[i];
        }
        return proposalIds;
    }
}