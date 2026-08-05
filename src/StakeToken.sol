// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;
import './Interface.sol';
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
// import "forge-std/console.sol";

contract StakeToken is Initializable, ERC20PermitUpgradeable, OwnableUpgradeable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;

    address public token;
    uint48 public cooldown;
    uint48 public constant MAX_COOLDOWN = 30 days;

    struct CooldownInfo {
        uint256 cooldownAmount;
        uint256 cooldownEndTimestamp;
    }

    struct Lock {
        uint256 amount;
        uint256 expiry;
    }

    mapping(address => CooldownInfo) public cooldownInfos;
    mapping(address => bool) public lockers;
    mapping(address => Lock[]) private _locks;

    // Releasable balance locks (no expiry): locker => user => amount locked by that locker for the user.
    mapping(address => mapping(address => uint256)) public lockedBalances;
    // user => total amount locked across all lockers (used by getAvailableBalance).
    mapping(address => uint256) public lockedTotals;

    event Stake(address staker, uint256 amount);
    event UnStake(address unstaker, uint256 amount);
    event Withdraw(address withdrawer, uint256 amount);
    event SetCooldown(uint48 oldCooldown, uint48 cooldown);
    event LockerRoleGranted(address indexed user);
    event LockerRoleRevoked(address indexed user);
    event Locked(address indexed user, uint256 amount, uint256 expiry);
    event BalanceLocked(address indexed locker, address indexed user, uint256 amount);
    event BalanceUnlocked(address indexed locker, address indexed user, uint256 amount);

    error InsufficientAvailableBalance(address user, uint256 available, uint256 required);
    error TooManyActiveLocks(address user, uint256 count);

    uint256 public constant MAX_ACTIVE_LOCKS = 200;
    uint8 public constant NATIVE_TOKEN_DECIMALS = 18;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address token_,
        uint48 cooldown_,
        address owner_
    ) public initializer {
        __ERC20_init(name_, symbol_);
        // Only present so upgrades-core's `missing-initializer-call` validation passes.
        // The EIP712 storage it writes is deliberately ignored by the _EIP712Name /
        // _EIP712Version overrides below, which derive the domain instead.
        __ERC20Permit_init(name_);
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuardTransient_init();
        require(cooldown_ < MAX_COOLDOWN, "cooldown exceeds MAX_COOLDOWN");
        token = token_;
        cooldown = cooldown_;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function decimals() public view override(ERC20Upgradeable) returns (uint8) {
        if (token == address(0)) {
            return NATIVE_TOKEN_DECIMALS;
        }
        return ERC20Upgradeable(token).decimals();
    }

    /// @dev The EIP-712 domain is derived from `name()` rather than read from EIP712 storage.
    ///      That is what lets proxies upgraded through StakeFactory.upgradeSTImpl — which passes
    ///      EMPTY calldata and therefore cannot run a reinitializer — obtain a valid domain with
    ///      zero initialization, and makes upgraded tokens behave identically to freshly deployed
    ///      ones. WARNING: `name()` must never become mutable; changing it would silently
    ///      invalidate every outstanding permit signature. Removing this override would break the
    ///      domain of every token that was upgraded with empty calldata.
    function _EIP712Name() internal view override returns (string memory) {
        return name();
    }

    function _EIP712Version() internal pure override returns (string memory) {
        return "1";
    }

    function stake(uint256 amount) external payable whenNotPaused nonReentrant {
        require(amount > 0, "amount is zero");
        if (token == address(0)) {
            require(msg.value == amount, "value must equal amount");
        } else {
            require(msg.value == 0, "value must be zero for ERC20");
            require(IERC20(token).allowance(msg.sender, address(this)) >= amount, "not enough allowance");
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        _mint(msg.sender, amount);
        emit Stake(msg.sender, amount);
    }

    function unstake(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount is zero");
        CooldownInfo storage cooldownInfo = cooldownInfos[msg.sender];
        require(amount <= balanceOf(msg.sender), "not enough to unstake");
        cooldownInfo.cooldownAmount += amount;
        cooldownInfo.cooldownEndTimestamp = block.timestamp + cooldown;
        _burn(msg.sender, amount);
        emit UnStake(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount is zero");
        CooldownInfo storage cooldownInfo = cooldownInfos[msg.sender];
        require(cooldownInfo.cooldownAmount >= amount, "not enough cooldown amount");
        require(cooldownInfo.cooldownEndTimestamp <= block.timestamp, "cooldowning");
        cooldownInfo.cooldownAmount -= amount;
        if (token == address(0)) {
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "Failed to send native token");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit Withdraw(msg.sender, amount);
    }

    function setCooldown(uint48 cooldown_) external onlyOwner {
        require(cooldown != cooldown_, "cooldown not change");
        require(cooldown_ < MAX_COOLDOWN, "cooldown exceeds MAX_COOLDOWN");
        emit SetCooldown(cooldown, cooldown_);
        cooldown = cooldown_;
    }

    function grantLockerRole(address user) external onlyOwner {
        lockers[user] = true;
        emit LockerRoleGranted(user);
    }

    function revokeLockerRole(address user) external onlyOwner {
        lockers[user] = false;
        emit LockerRoleRevoked(user);
    }

    modifier onlyLocker() {
        require(lockers[msg.sender], "not locker");
        _;
    }

    function lock(address user, uint256 amount, uint256 expiry) external onlyLocker {
        _cleanExpiredLocks(user);
        uint256 len = _locks[user].length;
        if (len >= MAX_ACTIVE_LOCKS) revert TooManyActiveLocks(user, len);
        _locks[user].push(Lock(amount, expiry));
        emit Locked(user, amount, expiry);
    }

    /// @notice Locks `amount` of `user`'s balance with no expiry; releasable any time via `unlock`.
    /// @dev Only callable by a locker. Accounting is scoped to the calling locker so it can only
    ///      release what it locked. The locked amount counts against `getAvailableBalance`.
    function lock(address user, uint256 amount) external onlyLocker whenNotPaused {
        require(amount > 0, "amount is zero");
        require(getAvailableBalance(user) >= amount, "insufficient available");
        lockedBalances[msg.sender][user] += amount;
        lockedTotals[user] += amount;
        emit BalanceLocked(msg.sender, user, amount);
    }

    /// @notice Releases `amount` previously locked by the caller for `user`.
    /// @dev No role check needed: a caller can only release locks it created (scoped accounting).
    function unlock(address user, uint256 amount) external whenNotPaused {
        require(amount > 0, "amount is zero");
        require(lockedBalances[msg.sender][user] >= amount, "exceeds locked");
        lockedBalances[msg.sender][user] -= amount;
        lockedTotals[user] -= amount;
        emit BalanceUnlocked(msg.sender, user, amount);
    }

    function getAvailableBalance(address user) public view returns (uint256) {
        uint256 locked = _totalActiveLocks(user) + lockedTotals[user];
        uint256 balance = balanceOf(user);
        if (locked >= balance) return 0;
        return balance - locked;
    }

    function getActiveLocks(address user) external view returns (Lock[] memory) {
        Lock[] storage userLocks = _locks[user];
        uint256 activeCount;
        for (uint256 i; i < userLocks.length; i++) {
            if (userLocks[i].expiry > block.timestamp) {
                activeCount++;
            }
        }

        Lock[] memory result = new Lock[](activeCount);
        uint256 idx;
        for (uint256 i; i < userLocks.length; i++) {
            if (userLocks[i].expiry > block.timestamp) {
                result[idx] = userLocks[i];
                idx++;
            }
        }
        return result;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 available = getAvailableBalance(from);
            if (available < value) {
                revert InsufficientAvailableBalance(from, available, value);
            }
        }
        super._update(from, to, value);
    }

    function _totalActiveLocks(address user) internal view returns (uint256 total) {
        Lock[] storage userLocks = _locks[user];
        for (uint256 i; i < userLocks.length; i++) {
            if (userLocks[i].expiry > block.timestamp) {
                total += userLocks[i].amount;
            }
        }
    }

    function _cleanExpiredLocks(address user) internal {
        Lock[] storage userLocks = _locks[user];
        uint256 writeIdx;
        for (uint256 readIdx; readIdx < userLocks.length; readIdx++) {
            if (userLocks[readIdx].expiry > block.timestamp) {
                if (writeIdx != readIdx) {
                    userLocks[writeIdx] = userLocks[readIdx];
                }
                writeIdx++;
            }
        }
        uint256 removeCount = userLocks.length - writeIdx;
        for (uint256 i; i < removeCount; i++) {
            userLocks.pop();
        }
    }
}