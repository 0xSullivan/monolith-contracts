// SPDX-License-Identifier: MIT

pragma solidity ^0.8.16;

import "./interfaces/solidly/IVotingEscrow.sol";
import "./interfaces/solidly/IBribe.sol";
import "./interfaces/solidly/IGauge.sol";
import "./interfaces/solidly/IBaseV1Voter.sol";

import "./interfaces/IDepositToken.sol";
import "./interfaces/IMultiRewarder.sol";

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract NFTHolder is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /* ========== STATE VARIABLES ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant SETTER_ROLE = keccak256("SETTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // solidly contracts
    IVotingEscrow public votingEscrow;
    IBaseV1Voter public solidlyVoter;

    // monlith contracts
    address public moSolid;

    uint256 public tokenID;

    mapping(address => bool) public isRewardToken;

    address public depositTokenImplementation;
    IMultiRewarder public multiRewarder;

    // pool -> gauge
    mapping(address => address) public gaugeForPool;
    // pool -> monolith deposit token
    mapping(address => address) public tokenForPool;
    // user -> pool -> deposit amount
    mapping(address => mapping(address => uint256)) public userBalances;
    // pool -> total deposit amount
    mapping(address => uint256) public totalBalances;

    // reward variables
    uint256 public callerFee; // e.g. 5e15 for 0.5%
    uint256 public platformFee; // e.g. 1e17 for 10%
    address public platformFeeReceiver;

    uint256 public votingWindow;
    uint256 public splitDeadline;
    address public splitter;

    event Deposited(address indexed user, address indexed pool, uint256 amount);
    event Withdrawn(address indexed user, address indexed pool, uint256 amount);
    event TransferDeposit(
        address indexed pool,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        IVotingEscrow _votingEscrow,
        IBaseV1Voter _solidlyVoter,
        address admin,
        address pauser,
        address setter,
        address operator
    ) public initializer {
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControlEnumerable_init();

        votingEscrow = _votingEscrow;
        solidlyVoter = _solidlyVoter;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UNPAUSER_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(SETTER_ROLE, setter);
        _grantRole(OPERATOR_ROLE, operator);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function gaugeRewardTokens(address pool)
        external
        view
        returns (
            address[] memory rewardTokens,
            bool[] memory isOptIn,
            bool[] memory isWhitelisted
        )
    {
        IGauge gauge = IGauge(solidlyVoter.gauges(pool));
        if (address(gauge) != address(0)) {
            uint256 rewardsLength = gauge.rewardsListLength();

            rewardTokens = new address[](rewardsLength);
            isOptIn = new bool[](rewardsLength);
            isWhitelisted = new bool[](rewardsLength);

            for (uint8 i = 0; i < rewardsLength; i++) {
                address rewardToken = gauge.rewards(i);
                rewardTokens[i] = rewardToken;
                isOptIn[i] = gauge.isOptIn(address(this), rewardToken);
                isWhitelisted[i] = isRewardToken[rewardToken];
            }
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenID,
        bytes calldata
    ) external whenNotPaused returns (bytes4) {
        // VeDepositor transfers the NFT to this contract so this callback is required
        require(_operator == moSolid);

        // make sure only voting escrow can call this method
        require(msg.sender == address(votingEscrow));

        if (tokenID == 0) {
            tokenID = _tokenID;
        }

        return
            bytes4(
                keccak256("onERC721Received(address,address,uint256,bytes)")
            );
    }

    /**
     * @notice Deposit Solidly LP tokens into a gauge via this contract
     * @dev Each deposit is also represented via a new ERC20, the address
     * is available by querying `tokenForPool(pool)`
     * @param pool Address of the pool token to deposit
     * @param amount Quantity of tokens to deposit
     */
    function deposit(
        address pool,
        uint256 amount,
        address[] calldata rewardTokens
    ) external whenNotPaused nonReentrant {
        require(tokenID != 0, "Must lock SOLID first");
        require(amount > 0, "Cannot deposit zero");
        require(block.timestamp > splitDeadline, "Split is in action");

        address gauge = gaugeForPool[pool];

        if (gauge == address(0)) {
            gauge = solidlyVoter.gauges(pool);
            if (gauge == address(0)) {
                gauge = solidlyVoter.createGauge(pool);
            }
            gaugeForPool[pool] = gauge;
            tokenForPool[pool] = _deployDepositToken(pool);
            IERC20Upgradeable(pool).approve(gauge, type(uint256).max);

            uint256 rewardsLength = IGauge(gauge).rewardsListLength();
            if (rewardsLength > 0) {
                _gaugeOptIn(gauge, rewardsLength);
            }
        }

        if (rewardTokens.length != 0) optIn(pool, rewardTokens);

        IERC20Upgradeable(pool).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        IGauge(gauge).deposit(amount, tokenID);

        userBalances[msg.sender][pool] += amount;
        totalBalances[pool] += amount;
        IDepositToken(tokenForPool[pool]).mint(msg.sender, amount);

        multiRewarder.stakeFor(pool, msg.sender, amount);

        emit Deposited(msg.sender, pool, amount);
    }

    /**
     * @notice Withdraw Solidly LP tokens
     * @param pool Address of the pool token to withdraw
     * @param amount Quantity of tokens to withdraw
     */
    function withdraw(address pool, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        address gauge = gaugeForPool[pool];

        require(gauge != address(0), "Unknown pool");
        require(amount > 0, "Cannot withdraw zero");
        require(
            userBalances[msg.sender][pool] >= amount,
            "Insufficient deposit"
        );

        userBalances[msg.sender][pool] -= amount;
        totalBalances[pool] -= amount;

        IDepositToken(tokenForPool[pool]).burn(msg.sender, amount);
        IGauge(gauge).withdraw(amount);
        IERC20Upgradeable(pool).safeTransfer(msg.sender, amount);

        multiRewarder.withdrawFrom(pool, msg.sender, amount);

        emit Withdrawn(msg.sender, pool, amount);
    }

    /// @notice Claims rewards from pool's gauge and deposit into multi rewarder after cutting platform share
    function poke(
        address pool,
        address[] memory tokens,
        address bountyReceiver
    ) external whenNotPaused nonReentrant {
        IGauge(gaugeForPool[pool]).getReward(address(this), tokens);

        uint256[] memory rewards = new uint256[](tokens.length);
        uint256 reward;
        uint256 callerCut;
        uint256 platformCut;
        for (uint8 i = 0; i < tokens.length; i++) {
            require(isRewardToken[tokens[i]], "Not reward token");

            reward = IERC20Upgradeable(tokens[i]).balanceOf(address(this));

            if (reward > 0) {
                callerCut = (reward * callerFee) / 1e18;
                reward -= callerCut;

                platformCut = (reward * platformFee) / 1e18;
                rewards[i] = reward - platformCut;

                IERC20Upgradeable(tokens[i]).safeTransfer(
                    bountyReceiver,
                    callerCut
                );

                IERC20Upgradeable(tokens[i]).safeTransfer(
                    platformFeeReceiver,
                    platformCut
                );

                if (
                    IERC20Upgradeable(tokens[i]).allowance(
                        address(this),
                        address(multiRewarder)
                    ) < rewards[i]
                ) {
                    IERC20Upgradeable(tokens[i]).approve(
                        address(multiRewarder),
                        type(uint256).max
                    );
                }
            }
        }

        multiRewarder.notifyRewardAmount(pool, tokens, rewards);
    }

    function optIn(address pool, address[] calldata tokens) public {
        IGauge(gaugeForPool[pool]).optIn(tokens);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferDeposit(
        address pool,
        address from,
        address to,
        uint256 amount
    ) external whenNotPaused returns (bool) {
        require(msg.sender == tokenForPool[pool], "Unauthorized caller");
        require(amount > 0, "Cannot transfer zero");
        require(userBalances[from][pool] >= amount, "Insufficient balance");

        userBalances[from][pool] -= amount;
        multiRewarder.withdrawFrom(pool, from, amount);

        userBalances[to][pool] += amount;
        multiRewarder.stakeFor(pool, to, amount);

        emit TransferDeposit(pool, from, to, amount);

        return true;
    }

    function setAddresses(
        address _moSolid,
        address _depositTokenImplementation,
        address _multiRewarder,
        address _platformFeeReceiver,
        address _splitter
    ) external onlyRole(SETTER_ROLE) {
        if (_moSolid != address(0)) {
            moSolid = _moSolid;
            votingEscrow.setApprovalForAll(_moSolid, true); // for merge
        }

        if (_depositTokenImplementation != address(0)) {
            depositTokenImplementation = _depositTokenImplementation;
        }

        if (_multiRewarder != address(0)) {
            multiRewarder = IMultiRewarder(_multiRewarder);
        }

        if (_platformFeeReceiver != address(0)) {
            platformFeeReceiver = _platformFeeReceiver;
        }

        if (_splitter != address(0)) {
            splitter = _splitter;
            votingEscrow.setApprovalForAll(_splitter, true); // for split
        }
    }

    function setRewardsFees(uint256 _callerFee, uint256 _platformFee)
        external
        onlyRole(SETTER_ROLE)
    {
        callerFee = _callerFee;
        platformFee = _platformFee;
    }

    function setRewardTokens(address[] memory rewardTokens, bool status)
        external
        onlyRole(SETTER_ROLE)
    {
        for (uint8 i = 0; i < rewardTokens.length; i++) {
            isRewardToken[rewardTokens[i]] = status;
        }
    }

    function setVotingWindow(uint256 _votingWindow)
        external
        onlyRole(SETTER_ROLE)
    {
        votingWindow = _votingWindow;
    }

    function enterSplitMode(uint256 workTimeLimit) external {
        require(msg.sender == splitter, "Only Splitter");
        splitDeadline = block.timestamp + workTimeLimit;
    }

    function vote(address[] memory pools, int256[] memory weights)
        external
        onlyRole(OPERATOR_ROLE)
    {
        solidlyVoter.vote(tokenID, pools, weights);
    }

    function withdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) {
        IERC20Upgradeable(token).safeTransfer(to, amount);
    }

    function withdrawNFT(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        votingEscrow.safeTransferFrom(address(this), to, tokenID);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }

    function detachGauges(address[] memory gaugeAddresses) external {
        require(msg.sender == splitter, "Not Splitter");

        uint256 amount;
        for (uint256 i = 0; i < gaugeAddresses.length; i++) {
            // max withdraw is 1e16 token to avoid large asset transfer
            amount = IGauge(gaugeAddresses[i]).balanceOf(address(this));
            if (amount > 0) {
                if (amount > 1e16) amount = 1e16;
                IGauge(gaugeAddresses[i]).withdrawToken(amount, tokenID);
                IGauge(gaugeAddresses[i]).deposit(amount, 0);
            }
        }
    }

    function reattachGauges(address[] memory gaugeAddresses) external {
        require(msg.sender == splitter, "Not Splitter");

        // when this function is called it means split is over
        // so we can allow deposits sooner than splitDeadline
        splitDeadline = 0;

        uint256 amount = 1e16;
        for (uint256 i = 0; i < gaugeAddresses.length; i++) {
            amount = IGauge(gaugeAddresses[i]).balanceOf(address(this));
            if (amount > 0) {
                if (amount > 1e16) amount = 1e16;
                IGauge(gaugeAddresses[i]).withdrawToken(amount, 0);
                IGauge(gaugeAddresses[i]).deposit(amount, tokenID);
            }
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function _deployDepositToken(address pool)
        internal
        returns (address token)
    {
        // taken from https://solidity-by-example.org/app/minimal-proxy/
        bytes20 targetBytes = bytes20(depositTokenImplementation);
        assembly {
            let clone := mload(0x40)
            mstore(
                clone,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone, 0x14), targetBytes)
            mstore(
                add(clone, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            token := create(0, clone, 0x37)
        }
        IDepositToken(token).initialize(pool);
        return token;
    }

    function _gaugeOptIn(address gauge, uint256 rewardsLength) internal {
        IGauge gauge = IGauge(gauge);
        address[] memory rewardTokens = new address[](rewardsLength);
        for (uint8 i = 0; i < rewardsLength; i++) {
            rewardTokens[i] = gauge.rewards(i);
        }
        gauge.optIn(rewardTokens);
    }
}
