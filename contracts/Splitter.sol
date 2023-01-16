// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/solidly/IGauge.sol";
import "./interfaces/INFTHolder.sol";
import "./interfaces/IVeDepositor.sol";

import "./interfaces/solidly/IBaseV1Voter.sol";
import "./interfaces/solidly/IVotingEscrow.sol";
import "./interfaces/solidly/IBaseV1Minter.sol";

/**************************************************
 *                 Splitter
 **************************************************/

/**
 * Methods in this contract assumes all interactions with gauges and bribes are safe
 * and that the anti-bricking logics are all already processed by voterProxy
 */

contract Splitter is
    IERC721Receiver,
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable
{
    using SafeMath for uint256;

    /********** Storage slots start here **********/

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant SETTER_ROLE = keccak256("SETTER_ROLE");

    uint256 public workTimeLimit;

    // re-entrancy
    uint256 internal _unlocked;

    // Public addresses
    uint256 public splitTokenId;
    IBaseV1Voter public solidlyVoter;
    IVotingEscrow public votingEscrow;
    IBaseV1Minter public minter;

    ILpDepositor public NFTHolder;
    IVeDepositor public moSolid;
    address public elmoSOLID;

    uint256 public minTipPerGauge;
    uint256 public minBond;
    uint256 public fee;

    // States
    uint256 public lastSplitTimestamp; // Records last successful split timestamp
    address public currentWorker;
    uint256 public workingStage;
    uint256 public workFinishDeadline;

    mapping(address => bool) public reattachGauge; // Gauges to reattach
    uint256 public reattachGaugeLength; // Length of gauges to reattach

    // Accounting
    uint256 public totalSplitRequested;
    mapping(address => uint256) public balanceOf; // User => claimable balance
    mapping(address => uint256) public lastBurnTimestamp; // User => last burn timestamp

    /****************************************
     *              Events
     ****************************************/

    event RequestBurn(address indexed from, uint256 amount);
    event WorkStarted(address indexed worker, uint256 deadline);
    event WorkerSplit(uint256 amount);
    event SplitClaimed(address indexed user, uint256 tokenId, uint256 amount);

    /****************************************
     *              Modifiers
     ****************************************/

    modifier lock() {
        require(_unlocked != 2, "Reentrancy");
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    modifier onlyStage(uint256 stage) {
        require(stage == workingStage, "Not current stage");
        _;
    }

    function initialize(
        address _votingEscrow,
        address _minterAddress,
        address _solidlyVoter,
        uint256 _minTipPerGauge,
        uint256 _minBond,
        address admin,
        address setter,
        address pauser
    ) public initializer {
        __Pausable_init();
        __AccessControlEnumerable_init();

        votingEscrow = IVotingEscrow(_votingEscrow);
        minter = IBaseV1Minter(_minterAddress);
        solidlyVoter = IBaseV1Voter(_solidlyVoter);

        // Set presets
        _unlocked = 1;
        workTimeLimit = 3600; // 1 hour
        fee = 3e16; // 3%

        minTipPerGauge = _minTipPerGauge;
        minBond = _minBond;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UNPAUSER_ROLE, admin);
        _grantRole(SETTER_ROLE, setter);
        _grantRole(PAUSER_ROLE, pauser);
    }

    /****************************************
     *             Initialize
     ****************************************/

    /**
     * @notice Initialize proxy storage
     */
    function setAddresses(
        address _NFTHolder,
        address _moSolid,
        address _elmoSOLID
    ) public onlyRole(SETTER_ROLE) {
        // Set addresses and interfaces
        NFTHolder = ILpDepositor(_NFTHolder);
        moSolid = IVeDepositor(_moSolid);
        elmoSOLID = _elmoSOLID;
    }

    /****************************************
     *            View Methods
     ****************************************/

    function totalTips() external view returns (uint256) {
        return address(this).balance;
    }

    function minTip() public view returns (uint256) {
        return votingEscrow.attachments(NFTHolder.tokenID()) * minTipPerGauge;
    }

    /****************************************
     *            User Methods
     ****************************************/
    function requestSplit(uint256 splitAmount)
        external
        payable
        onlyStage(0)
        whenNotPaused
    {
        require(splitAmount > 0, "Cannot split 0");
        require(
            balanceOf[msg.sender] == 0 ||
                lastBurnTimestamp[msg.sender] > lastSplitTimestamp,
            "Claim available split first"
        );
        require(msg.value >= minTip(), "Not enough tips");

        uint256 feeAmount = (splitAmount * fee) / 1e18;
        uint256 burnAmount = splitAmount - feeAmount;

        // Burn moSolid
        moSolid.burnFrom(msg.sender, burnAmount);

        // Transfer fee
        require(
            moSolid.transferFrom(msg.sender, elmoSOLID, feeAmount),
            "TRANSFER FAILED"
        );

        // Record user data
        balanceOf[msg.sender] += splitAmount;
        lastBurnTimestamp[msg.sender] = block.timestamp;

        // Record global data
        totalSplitRequested += splitAmount;

        emit RequestBurn(msg.sender, splitAmount);
    }

    function claimSplitVeNft()
        external
        lock
        whenNotPaused
        returns (uint256 tokenId)
    {
        require(
            lastBurnTimestamp[msg.sender] < lastSplitTimestamp,
            "Split not processed"
        );
        uint256 amount = balanceOf[msg.sender];
        require(amount > 0, "Nothing to claim");

        // Reset state
        balanceOf[msg.sender] = 0;

        // Split if amount < total locked
        (uint256 lockedAmount, ) = votingEscrow.locked(splitTokenId);
        if (amount < uint128(lockedAmount)) {
            tokenId = votingEscrow.split(splitTokenId, amount);
        } else {
            // Transfer splitTokenId instead of split if amount = locked
            tokenId = splitTokenId;
            splitTokenId = 0;
        }
        votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId);

        emit SplitClaimed(msg.sender, tokenId, amount);
        return tokenId;
    }

    /****************************************
     *            Worker Methods
     ****************************************/

    function startWork() external payable lock onlyStage(0) whenNotPaused {
        uint256 activePeriod = minter.active_period();
        require(activePeriod > lastSplitTimestamp, "Not new epoch");
        require(
            block.timestamp <
                activePeriod +
                    1 weeks -
                    NFTHolder.votingWindow() -
                    workTimeLimit,
            "Cannot start work close to voting window"
        );
        // Require workers to post bonds of 10% of the rewards, minimum: minBond
        require(
            msg.value >=
                Math.max(minBond, address(this).balance.sub(msg.value) / 10),
            "Not enough bond"
        );

        NFTHolder.enterSplitMode(workTimeLimit);

        // Set work status
        currentWorker = msg.sender;
        workFinishDeadline = block.timestamp + workTimeLimit;
        workingStage = 1;

        emit WorkStarted(msg.sender, block.timestamp + workTimeLimit);
    }

    function detachGauges(address[] memory gaugeAddresses)
        external
        onlyStage(1)
    {
        uint256 _reattachGaugeLength = 0;
        address[] memory validGauges = new address[](gaugeAddresses.length);

        for (uint256 i = 0; i < gaugeAddresses.length; i++) {
            require(solidlyVoter.isGauge(gaugeAddresses[i]), "Invalid gauge");

            if (IGauge(gaugeAddresses[i]).tokenIds(address(NFTHolder)) > 0) {
                reattachGauge[gaugeAddresses[i]] = true;
                validGauges[_reattachGaugeLength] = gaugeAddresses[i];
                _reattachGaugeLength++;
            }
        }

        // Update array length
        assembly {
            mstore(validGauges, _reattachGaugeLength)
        }
        reattachGaugeLength += _reattachGaugeLength;

        // Detach gauges
        NFTHolder.detachGauges(validGauges);
    }

    function resetVotes() external onlyStage(1) {
        require(
            block.timestamp < minter.active_period() + 1 weeks, //- votingSnapshot.window(),
            "Voting underway"
        );
        solidlyVoter.vote(
            NFTHolder.tokenID(),
            new address[](0),
            new int256[](0)
        );
    }

    /**
     * @notice Split and enter next stage if possible
     */
    function finishStage1() external lock onlyStage(1) {
        uint256 _primaryTokenId = NFTHolder.tokenID();
        require(
            votingEscrow.attachments(_primaryTokenId) == 0,
            "Gauge Attachments"
        );
        require(!votingEscrow.voted(_primaryTokenId), "Vote not cleared");

        // Split veNFT
        uint256 incomingTokenId = votingEscrow.split(
            _primaryTokenId,
            totalSplitRequested
        );
        emit WorkerSplit(totalSplitRequested);

        // Reset totalSplitRequested
        totalSplitRequested = 0;

        // Merge incoming veNFT into tokenId of splitting veNFT
        if (splitTokenId > 0) {
            votingEscrow.merge(incomingTokenId, splitTokenId);
        } else {
            splitTokenId = incomingTokenId;
        }

        // Record split timestamp
        lastSplitTimestamp = block.timestamp;

        // Enter next stage
        workingStage = 2;
    }

    function reattachGauges(address[] memory gaugeAddresses)
        external
        onlyStage(2)
    {
        // Process reattachGauge and reattachGaugeLength
        uint256 _reattachedGaugeLength = 0;
        address[] memory validGauges = new address[](gaugeAddresses.length);

        for (uint256 i = 0; i < gaugeAddresses.length; i++) {
            if (reattachGauge[gaugeAddresses[i]]) {
                reattachGauge[gaugeAddresses[i]] = false;
                validGauges[_reattachedGaugeLength] = gaugeAddresses[i];
                _reattachedGaugeLength++;
            }
        }
        // Update array length
        assembly {
            mstore(validGauges, _reattachedGaugeLength)
        }

        reattachGaugeLength -= _reattachedGaugeLength;

        NFTHolder.reattachGauges(validGauges);
    }

    function claimTips() external lock onlyStage(2) {
        require(reattachGaugeLength == 0, "Not all gauges were reattached");
        require(
            msg.sender == currentWorker || block.timestamp > workFinishDeadline,
            "Only current worker can claim tips unless over deadline"
        );
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfer tip failed");

        // Reset status
        currentWorker = address(0);
        workingStage = 0;
    }

    /**
     * @notice Only allow inbound ERC721s during contract calls
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(_unlocked == 2, "No inbound ERC721s");
        return IERC721Receiver.onERC721Received.selector;
    }

    /****************************************
     *            Restricted Methods
     ****************************************/

    function setMinTipPerGauge(uint256 _minTipPerGauge)
        public
        onlyRole(SETTER_ROLE)
    {
        minTipPerGauge = _minTipPerGauge;
    }

    function setMinBond(uint256 _minBond) public onlyRole(SETTER_ROLE) {
        minBond = _minBond;
    }

    function setFee(uint256 _fee) public onlyRole(SETTER_ROLE) {
        fee = _fee;
    }

    function setWorkTimeLimit(uint256 _workTimeLimit)
        public
        onlyRole(SETTER_ROLE)
    {
        workTimeLimit = _workTimeLimit;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(UNPAUSER_ROLE) {
        _unpause();
    }
}
