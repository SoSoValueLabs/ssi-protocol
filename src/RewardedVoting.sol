// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import {ILockable} from "./Interface.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
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
///         All fee rates, durations, thresholds and token addresses are configurable
///         at initialization via `VotingConfig` and readable via `getVotingConfig()`.
/// @dev
/// Workflow:
/// - Proposer deposits `payToken` (≥ `minPayAmount`) to create a proposal (directly or via EIP-712 + `permit`).
/// - Voters lock `votingToken` voting power for `voteLockDuration` and vote approve/reject (directly or via EIP-712).
/// - After `votingDuration` elapses, anyone can resolve: distributes fees and refunds depending on outcome.
///   - Approved (totalVotes ≥ `minVoteAmount` AND approve ratio ≥ `minApproveRatio`):
///     `voterFeeBps` → voter reward pool, `protocolFeeBps` → treasury, remainder → airdropPool.
///   - Rejected with votes: voter reward = min(`voterFeeBps` share, `maxVoterRewardIfRejected`), rest refunded to proposer.
///   - No votes: full refund to proposer.
/// - Voters can claim a pro-rata share of the voter-reward pool after resolution.
///
/// Security notes:
/// - Voting power is enforced via `ILockable.getAvailableBalance` and `ILockable.lock`.
/// - Uses `ReentrancyGuardTransientUpgradeable` and `SafeERC20`.
/// - UUPS upgrade authorization is restricted to owner.
contract RewardedVoting is Initializable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardTransientUpgradeable, EIP712Upgradeable, NoncesUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Basis points denominator (100% = 10,000 bps).
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @dev EIP-712 typehash for `createProposalFor`.
    bytes32 public constant CREATE_PROPOSAL_TYPE_HASH = keccak256("CreateProposal(uint256 payAmount,uint256 proposalId,uint8 v,bytes32 r,bytes32 s,uint256 nonce,uint256 deadline)");
    /// @dev EIP-712 typehash for `voteFor`.
    bytes32 public constant VOTE_TYPE_HASH = keccak256("Vote(uint256 proposalId,uint256 amount,bool support,uint256 nonce,uint256 deadline)");

    /// @notice Configuration parameters set at initialization and immutable thereafter.
    /// @dev All amount fields (`minVoteAmount`, `minPayAmount`, `maxVoterRewardIfRejected`)
    ///      are stored in full decimals (i.e. already scaled by `10 ** token.decimals()`).
    struct VotingConfig {
        /// @notice Token used to measure and lock voting power (must implement `ILockable`).
        address votingToken;
        /// @notice Token deposited by proposers and used for rewards/refunds.
        address payToken;
        /// @notice Basis points charged from `payAmount` and reserved for voter rewards.
        uint256 voterFeeBps;
        /// @notice Basis points charged from `payAmount` and sent to `treasury` on approval.
        uint256 protocolFeeBps;
        /// @notice Minimum approval ratio required to approve a proposal (in bps, e.g. 8000 = 80%).
        uint256 minApproveRatio;
        /// @notice Voting window length in seconds for each proposal.
        uint256 votingDuration;
        /// @notice Lock duration in seconds applied to voting power on each vote.
        uint256 voteLockDuration;
        /// @notice Minimum total vote weight (full decimals) required for the approval path.
        uint256 minVoteAmount;
        /// @notice Minimum amount of `payToken` (full decimals) required to create a proposal.
        uint256 minPayAmount;
        /// @notice Maximum `payToken` voter reward (full decimals) if proposal is rejected.
        uint256 maxVoterRewardIfRejected;
    }

    /// @notice Lifecycle states of a proposal.
    enum ProposalState {
        /// @notice Voting is not created, default value
        NonExistent,
        /// @notice Voting is open; votes can be cast and proposal can not be resolved yet.
        Voting,
        /// @notice Proposal passed; funds have been distributed according to approval path.
        Approved,
        /// @notice Proposal failed; partial refund has been processed.
        Rejected,
        /// @notice No votes were cast; full refund has been returned to proposer.
        NoVotes
    }

    /// @notice Fee distribution breakdown recorded when a proposal is resolved.
    struct ProposalDistribution {
        /// @notice Voter reward pool in `config.payToken`, fixed when resolved (basis for per-voter `previewReward`).
        uint256 voterReward;
        /// @notice Protocol/platform fee in `config.payToken` sent to `treasury` when approved; zero otherwise.
        uint256 protocolFee;
        /// @notice Amount in `config.payToken` sent to `airdropPool` when approved (`payAmount - voterReward - protocolFee`); zero otherwise.
        uint256 airdropReward;
        /// @notice Amount in `config.payToken` refunded to proposer when rejected or no votes; zero on approval.
        uint256 refund;
    }

    /// @notice Proposal metadata and voting totals.
    struct Proposal {
        /// @notice Proposal creator whose `config.payToken` deposit is pulled.
        address proposer;
        /// @notice Total deposited amount in `config.payToken`.
        uint256 payAmount;
        /// @notice Current state of the proposal.
        ProposalState state;
        /// @notice Timestamp (unix) when voting ends (`block.timestamp + config.votingDuration` at creation).
        uint256 votingEndTime;
        /// @notice Total approve vote weight accumulated.
        uint256 totalApproveWeight;
        /// @notice Total reject vote weight accumulated.
        uint256 totalRejectWeight;
        /// @notice Whether the proposal has been resolved and payouts/refunds executed.
        bool resolved;
        /// @notice Fee distribution breakdown, populated when the proposal is resolved.
        ProposalDistribution distribution;
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
        /// @notice Cumulative rewards claimed by the voter across all proposals (in `config.payToken`).
        uint256 claimedReward;
    }

    /// @notice Fee recipient when proposals are approved.
    address public treasury;
    /// @notice Recipient of the non-voter fees when proposals are approved.
    address public airdropPool;
    /// @notice Stored voting configuration set at initialization.
    VotingConfig private _votingConfig;

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
    event ProposalResolved(uint256 indexed proposalId, address indexed proposer, ProposalState outcome, ProposalDistribution distribution);
    /// @notice Emitted when a voter claims their reward for a proposal.
    event RewardClaimed(uint256 indexed proposalId, address indexed voter, uint256 amount);
    /// @notice Emitted when treasury address is updated.
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    /// @notice Emitted when airdrop pool address is updated.
    event AirdropPoolUpdated(address oldAirdropPool, address newAirdropPool);
    /// @notice Emitted when an approved proposal is renewed with additional funds.
    event ProposalRenewed(uint256 indexed proposalId, address indexed proposer, uint256 payAmount, ProposalDistribution distribution);

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
    error InvalidConfig(string reason);
    error NotProposer(uint256 proposalId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the upgradeable contract.
    /// @dev Sets token addresses, voting parameters, destinations and EIP-712 domain.
    /// @param config Voting configuration (tokens, fee rates, durations, thresholds).
    /// @param treasury_ Treasury that receives platform fee on approval.
    /// @param airdropPool_ Receiver of the remaining pay amount on approval (after fees).
    /// @param owner_ Owner for admin controls and UUPS upgrades.
    function initialize(
        VotingConfig calldata config,
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
        if (config.votingToken == address(0)) {
            revert ZeroAddress();
        }
        if (config.payToken == address(0)) {
            revert ZeroAddress();
        }
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

        if (config.voterFeeBps == 0) revert InvalidConfig("voterFeeBps must be > 0");
        if (config.voterFeeBps + config.protocolFeeBps > BPS_DENOMINATOR) revert InvalidConfig("total fee bps exceeds 100%");
        if (config.minApproveRatio == 0 || config.minApproveRatio > BPS_DENOMINATOR) revert InvalidConfig("minApproveRatio out of range");
        if (config.votingDuration == 0) revert InvalidConfig("votingDuration must be > 0");
        if (config.voteLockDuration == 0) revert InvalidConfig("voteLockDuration must be > 0");
        if (config.voteLockDuration < config.votingDuration) revert InvalidConfig("voteLockDuration must be >= votingDuration");
        if (config.minPayAmount == 0) revert InvalidConfig("minPayAmount must be > 0");
        if (config.minVoteAmount == 0) revert InvalidConfig("minVoteAmount must be > 0");

        _votingConfig = config;
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

    /// @notice Returns the full voting configuration.
    function getVotingConfig() external view returns (VotingConfig memory) {
        return _votingConfig;
    }

    /// @dev Creates a new proposal or renews an approved one.
    ///      If the proposal does not exist, creates it. If it is `Approved`, renews it
    ///      (only by the original proposer). Reverts for any other existing state.
    /// @param payAmount Amount of `config.payToken` to deposit (full decimals, must be ≥ `config.minPayAmount`).
    /// @param proposalId Proposal id to create or renew.
    /// @param proposer Address whose funds are pulled.
    function _createProposal(uint256 payAmount, uint256 proposalId, address proposer) internal {
        if (payAmount < _votingConfig.minPayAmount) {
            revert InsufficientProposalAmount(payAmount, _votingConfig.minPayAmount);
        }

        ProposalState state = proposals[proposalId].state;
        if (state == ProposalState.Approved) {
            _renewProposal(payAmount, proposalId, proposer);
        } else if (state == ProposalState.NonExistent) {
            proposals[proposalId] = Proposal({
                proposer: proposer,
                payAmount: payAmount,
                state: ProposalState.Voting,
                votingEndTime: block.timestamp + _votingConfig.votingDuration,
                totalApproveWeight: 0,
                totalRejectWeight: 0,
                resolved: false,
                distribution: ProposalDistribution({
                    voterReward: 0,
                    protocolFee: 0,
                    airdropReward: 0,
                    refund: 0
                })
            });

            IERC20(_votingConfig.payToken).safeTransferFrom(proposer, address(this), payAmount);
            emit ProposalCreated(proposalId, proposer, payAmount);
        } else {
            revert ProposalAlreadyExists(proposalId);
        }
    }

    /// @dev Renews an approved proposal with additional funds. Only the original proposer can renew.
    ///      Immediately distributes protocol fee and airdrop reward; voter reward is accumulated.
    function _renewProposal(uint256 payAmount, uint256 proposalId, address proposer) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposer != proposal.proposer) revert NotProposer(proposalId);

        uint256 voterRewardAmt = (payAmount * _votingConfig.voterFeeBps) / BPS_DENOMINATOR;
        uint256 protocolFeeAmt = (payAmount * _votingConfig.protocolFeeBps) / BPS_DENOMINATOR;
        uint256 airdropAmt = payAmount - voterRewardAmt - protocolFeeAmt;

        proposal.payAmount += payAmount;
        proposal.distribution.voterReward += voterRewardAmt;
        proposal.distribution.protocolFee += protocolFeeAmt;
        proposal.distribution.airdropReward += airdropAmt;

        emit ProposalRenewed(proposalId, proposer, payAmount, ProposalDistribution(voterRewardAmt, protocolFeeAmt, airdropAmt, 0));

        IERC20 pay = IERC20(_votingConfig.payToken);
        pay.safeTransferFrom(proposer, address(this), payAmount);
        pay.safeTransfer(treasury, protocolFeeAmt);
        pay.safeTransfer(airdropPool, airdropAmt);
    }

    /// @notice Creates a proposal by transferring `config.payToken` from caller.
    /// @param payAmount Amount of `config.payToken` to deposit (full decimals).
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
    /// - An ERC-2612 `permit` signature (passed as `v,r,s`) granting allowance for pulling `config.payToken`.
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
    /// @param payAmount Amount of `config.payToken` to deposit (full decimals).
    /// @param proposalId Proposal id to create.
    /// @param v Signature v of permit signature.
    /// @param r Signature r of permit signature.
    /// @param s Signature s of permit signature.
    /// @param nonce Expected nonce (must match `NoncesUpgradeable` for signer).
    /// @param deadline Signature expiry timestamp.
    /// @param signature ECDSA signature over typed data of createProposal.
    function createProposalFor(uint256 payAmount, uint256 proposalId, uint8 v, bytes32 r, bytes32 s, uint256 nonce, uint256 deadline, bytes calldata signature) external nonReentrant whenNotPaused {
        address signer = _verifyAndConsumeMetaTx(hashCreateProposal(payAmount, proposalId, v, r, s, nonce, deadline), nonce, deadline, signature);
        try IERC20Permit(_votingConfig.payToken).permit(signer, address(this), payAmount, deadline, v, r, s) {} catch {}
        _createProposal(payAmount, proposalId, signer);
    }

    /// @dev Casts (or adds to) a vote on a proposal, locking voting power for `config.voteLockDuration`.
    function _vote(uint256 proposalId, uint256 amount, bool support, address voter) internal {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotInVotingState(proposalId);
        if (block.timestamp > proposal.votingEndTime) revert VotingPeriodEnded(proposalId);
        if (amount == 0) revert ZeroAmount();
        if (ILockable(_votingConfig.votingToken).getAvailableBalance(voter) < amount) revert InsufficientVotingPower();

        ILockable(_votingConfig.votingToken).lock(voter, amount, block.timestamp + _votingConfig.voteLockDuration);

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

    /// @notice Resolves a proposal after `config.votingDuration` elapses and executes payout/refund logic.
    /// @dev
    /// - If no votes: rejected, proposer is fully refunded.
    /// - If approved (totalVotes ≥ `config.minVoteAmount` AND approve ratio ≥ `config.minApproveRatio`):
    ///   `config.voterFeeBps` → voter reward pool, `config.protocolFeeBps` → treasury, remainder → airdropPool.
    /// - If rejected with votes: voter reward = min(`config.voterFeeBps` share, `config.maxVoterRewardIfRejected`),
    ///   rest refunded to proposer.
    /// Anyone can call this after voting ends.
    /// @param proposalId Proposal id.
    function resolveProposal(uint256 proposalId) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.Voting) revert ProposalNotInVotingState(proposalId);
        if (block.timestamp <= proposal.votingEndTime) revert VotingPeriodNotEnded(proposalId);

        uint256 totalVoteWeight = proposal.totalApproveWeight + proposal.totalRejectWeight;
        IERC20 pay = IERC20(_votingConfig.payToken);

        if (totalVoteWeight == 0) {
            proposal.state = ProposalState.NoVotes;
            proposal.distribution.refund = proposal.payAmount;
            pay.safeTransfer(proposal.proposer, proposal.payAmount);
        } else {
            uint256 voterRewardAmt = (proposal.payAmount * _votingConfig.voterFeeBps) / BPS_DENOMINATOR;
            bool approved = totalVoteWeight >= _votingConfig.minVoteAmount
                && proposal.totalApproveWeight * BPS_DENOMINATOR / totalVoteWeight >= _votingConfig.minApproveRatio;

            if (approved) {
                proposal.state = ProposalState.Approved;
                uint256 protocolFeeAmt = (proposal.payAmount * _votingConfig.protocolFeeBps) / BPS_DENOMINATOR;
                uint256 airdropAmt = proposal.payAmount - voterRewardAmt - protocolFeeAmt;
                proposal.distribution = ProposalDistribution(voterRewardAmt, protocolFeeAmt, airdropAmt, 0);
                pay.safeTransfer(treasury, protocolFeeAmt);
                pay.safeTransfer(airdropPool, airdropAmt);
            } else {
                proposal.state = ProposalState.Rejected;
                if (voterRewardAmt > _votingConfig.maxVoterRewardIfRejected) voterRewardAmt = _votingConfig.maxVoterRewardIfRejected;
                uint256 refund = proposal.payAmount - voterRewardAmt;
                proposal.distribution = ProposalDistribution(voterRewardAmt, 0, 0, refund);
                pay.safeTransfer(proposal.proposer, refund);
            }
        }

        proposal.resolved = true;
        emit ProposalResolved(proposalId, proposal.proposer, proposal.state, proposal.distribution);
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
        reward = (record.supportWeight + record.rejectWeight) * proposal.distribution.voterReward / totalVoteWeight;
    }

    /// @notice Claims reward for `voter` for a resolved proposal.
    /// @dev Can be called by anyone; reward is always paid to `voter`.
    ///      Supports incremental claiming after `renewProposal`: if the voter already claimed
    ///      but the proposal was renewed (increasing the voter reward pool), the voter can
    ///      claim the additional delta.
    /// @param proposalId Proposal id.
    /// @param voter Voter address that receives the reward.
    function claimRewardFor(uint256 proposalId, address voter) public nonReentrant whenNotPaused {
        VoteRecord storage record = votes[proposalId][voter];

        uint256 totalReward = previewReward(proposalId, voter);
        uint256 alreadyClaimed = record.reward;
        if (totalReward <= alreadyClaimed) revert RewardAlreadyClaimed(proposalId, voter);

        uint256 claimable = totalReward - alreadyClaimed;
        record.reward = totalReward;

        if (!record.rewardClaimed) {
            record.rewardClaimed = true;
            voterClaimInfos[voter].claimedProposalIds.push(proposalId);
        }
        voterClaimInfos[voter].claimedReward += claimable;

        if (claimable > 0) {
            IERC20(_votingConfig.payToken).safeTransfer(voter, claimable);
        }

        emit RewardClaimed(proposalId, voter, claimable);
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
            if (proposals[proposalId].resolved) {
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