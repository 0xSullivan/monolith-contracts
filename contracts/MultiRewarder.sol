// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract MultiRewarder is
    Initializable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    AccessControlEnumerableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant SETTER_ROLE = keccak256("SETTER_ROLE");
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    struct Reward {
        uint256 rewardsDuration;
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    uint256 public defaultRewardsDuration;

    // pool => reward token => reward data
    mapping(address => mapping(address => Reward)) public rewardData;
    // pool => reward tokens
    mapping(address => address[]) public rewardTokens;
    // pool => reward token => bool
    mapping(address => mapping(address => bool)) public isRewardToken;

    // pool => user => reward token => amount
    mapping(address => mapping(address => mapping(address => uint256)))
        public userRewardPerTokenPaid;
    mapping(address => mapping(address => mapping(address => uint256)))
        public rewards;

    // pool => total supply
    mapping(address => uint256) public totalSupply;
    // pool => user => balance
    mapping(address => mapping(address => uint256)) public balanceOf;

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address NFTHolder,
        address admin,
        address setter,
        address pauser
    ) public initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlEnumerable_init();

        _grantRole(REWARDER_ROLE, NFTHolder);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UNPAUSER_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(SETTER_ROLE, setter);

        defaultRewardsDuration = 1 weeks;
    }

    /* ========== VIEWS ========== */

    function lastTimeRewardApplicable(address pool, address _rewardsToken)
        public
        view
        returns (uint256)
    {
        return
            block.timestamp < rewardData[pool][_rewardsToken].periodFinish
                ? block.timestamp
                : rewardData[pool][_rewardsToken].periodFinish;
    }

    function rewardTokensLength(address pool) external view returns (uint256) {
        return rewardTokens[pool].length;
    }

    function rewardPerToken(address pool, address _rewardsToken)
        public
        view
        returns (uint256)
    {
        if (totalSupply[pool] == 0) {
            return rewardData[pool][_rewardsToken].rewardPerTokenStored;
        }
        return
            rewardData[pool][_rewardsToken].rewardPerTokenStored +
            (((lastTimeRewardApplicable(pool, _rewardsToken) -
                rewardData[pool][_rewardsToken].lastUpdateTime) *
                rewardData[pool][_rewardsToken].rewardRate *
                1e18) / totalSupply[pool]);
    }

    function earned(
        address pool,
        address account,
        address _rewardsToken
    ) public view returns (uint256) {
        return
            ((balanceOf[pool][account] *
                (rewardPerToken(pool, _rewardsToken) -
                    userRewardPerTokenPaid[pool][account][_rewardsToken])) /
                1e18) + rewards[pool][account][_rewardsToken];
    }

    function getRewardForDuration(address pool, address _rewardsToken)
        external
        view
        returns (uint256)
    {
        return
            rewardData[pool][_rewardsToken].rewardRate *
            rewardData[pool][_rewardsToken].rewardsDuration;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stakeFor(
        address pool,
        address account,
        uint256 amount
    )
        external
        nonReentrant
        updateReward(pool, account)
        onlyRole(REWARDER_ROLE)
    {
        require(amount > 0, "Cannot stake 0");

        totalSupply[pool] += amount;
        balanceOf[pool][account] += amount;
        emit Staked(pool, account, amount);
    }

    function withdrawFrom(
        address pool,
        address account,
        uint256 amount
    )
        external
        nonReentrant
        updateReward(pool, account)
        onlyRole(REWARDER_ROLE)
    {
        require(amount > 0, "Cannot withdraw 0");
        totalSupply[pool] -= amount;
        balanceOf[pool][account] -= amount;
        emit Withdrawn(pool, account, amount);
    }

    function getReward(address pool)
        public
        nonReentrant
        updateReward(pool, msg.sender)
        whenNotPaused
    {
        for (uint256 i; i < rewardTokens[pool].length; i++) {
            address _rewardsToken = rewardTokens[pool][i];
            uint256 reward = rewards[pool][msg.sender][_rewardsToken];
            if (reward > 0) {
                rewards[pool][msg.sender][_rewardsToken] = 0;
                IERC20Upgradeable(_rewardsToken).safeTransfer(
                    msg.sender,
                    reward
                );
                emit RewardPaid(pool, msg.sender, _rewardsToken, reward);
            }
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(
        address pool,
        address[] memory _rewardsTokens,
        uint256[] memory _rewards
    ) external updateReward(pool, address(0)) onlyRole(REWARDER_ROLE) {
        for (uint8 i = 0; i < _rewardsTokens.length; i++) {
            address _rewardsToken = _rewardsTokens[i];
            uint256 reward = _rewards[i];

            if (reward == 0) continue;

            if (!isRewardToken[pool][_rewardsToken]) {
                rewardTokens[pool].push(_rewardsToken);
                rewardData[pool][_rewardsToken]
                    .rewardsDuration = defaultRewardsDuration;
                isRewardToken[pool][_rewardsToken] = true;
            }

            IERC20Upgradeable(_rewardsToken).safeTransferFrom(
                msg.sender,
                address(this),
                reward
            );

            if (
                block.timestamp >= rewardData[pool][_rewardsToken].periodFinish
            ) {
                rewardData[pool][_rewardsToken].rewardRate =
                    reward /
                    rewardData[pool][_rewardsToken].rewardsDuration;
            } else {
                uint256 remaining = rewardData[pool][_rewardsToken]
                    .periodFinish - block.timestamp;
                uint256 leftover = remaining *
                    rewardData[pool][_rewardsToken].rewardRate;
                rewardData[pool][_rewardsToken].rewardRate =
                    (reward + leftover) /
                    rewardData[pool][_rewardsToken].rewardsDuration;
            }

            rewardData[pool][_rewardsToken].lastUpdateTime = block.timestamp;
            rewardData[pool][_rewardsToken].periodFinish =
                block.timestamp +
                rewardData[pool][_rewardsToken].rewardsDuration;
        }
        emit RewardAdded(pool, _rewardsTokens, _rewards);
    }

    function setRewardsDuration(
        address pool,
        address _rewardsToken,
        uint256 _rewardsDuration
    ) external onlyRole(SETTER_ROLE) {
        require(
            block.timestamp > rewardData[pool][_rewardsToken].periodFinish,
            "Reward period still active"
        );
        require(_rewardsDuration > 0, "Reward duration must be non-zero");
        rewardData[pool][_rewardsToken].rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(
            pool,
            _rewardsToken,
            rewardData[pool][_rewardsToken].rewardsDuration
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address pool, address account) {
        for (uint256 i; i < rewardTokens[pool].length; i++) {
            address token = rewardTokens[pool][i];
            rewardData[pool][token].rewardPerTokenStored = rewardPerToken(
                pool,
                token
            );
            rewardData[pool][token].lastUpdateTime = lastTimeRewardApplicable(
                pool,
                token
            );
            if (account != address(0)) {
                rewards[pool][account][token] = earned(pool, account, token);
                userRewardPerTokenPaid[pool][account][token] = rewardData[pool][
                    token
                ].rewardPerTokenStored;
            }
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(address pool, address[] rewradsToken, uint256[] reward);
    event Staked(address pool, address indexed user, uint256 amount);
    event Withdrawn(address pool, address indexed user, uint256 amount);
    event RewardPaid(
        address pool,
        address indexed user,
        address indexed rewardsToken,
        uint256 reward
    );
    event RewardsDurationUpdated(
        address pool,
        address token,
        uint256 newDuration
    );
}
