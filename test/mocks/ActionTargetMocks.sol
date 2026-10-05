// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Pagination} from "libs/Pagination.sol";

contract MockPhase {
    uint256 internal _currentPhase;

    function setPhase(uint256 currentPhase_) external {
        _currentPhase = currentPhase_;
    }

    function currentPhase() external view returns (uint256) {
        return _currentPhase;
    }
}

contract MockVote {
    using Pagination for uint256[];

    address public phaseAddress;

    // tokenAddress => round => proposalId => voted
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _proposalVoted;
    // tokenAddress => round => voted proposal ids
    mapping(address => mapping(uint256 => uint256[])) internal _votedProposalIds;
    // round => ended
    mapping(uint256 => bool) internal _roundEnded;

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setRoundEnded(uint256 round, bool ended) external {
        _roundEnded[round] = ended;
    }

    function setProposalVoted(address tokenAddress, uint256 round, uint256 proposalId, bool voted) external {
        _proposalVoted[tokenAddress][round][proposalId] = voted;
    }

    function setVotedProposalIds(address tokenAddress, uint256 round, uint256[] calldata proposalIds) external {
        delete _votedProposalIds[tokenAddress][round];
        for (uint256 i = 0; i < proposalIds.length; i++) {
            _votedProposalIds[tokenAddress][round].push(proposalIds[i]);
            _proposalVoted[tokenAddress][round][proposalIds[i]] = true;
        }
    }

    function isProposalIdVoted(address tokenAddress, uint256 round, uint256 proposalId) external view returns (bool) {
        return _proposalVoted[tokenAddress][round][proposalId];
    }

    function isRoundEnded(uint256 round) external view returns (bool) {
        return _roundEnded[round];
    }

    function votedProposalIds(address tokenAddress, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory proposalIds, uint256 total)
    {
        return _votedProposalIds[tokenAddress][round].paginate(offset, limit, reverse);
    }
}

contract MockMint {
    error MintProposalRewardReverted();
    error BurnUnmintedProposalRewardReverted();

    uint256 public mintAmount;
    bool public revertOnMint;
    bool public revertOnBurn;
    uint256 public mintCalls;
    uint256 public burnCalls;
    address public lastMintCaller;
    address public lastMintTokenAddress;
    uint256 public lastMintRound;
    uint256 public lastMintProposalId;
    address public lastBurnCaller;
    address public lastBurnTokenAddress;
    uint256 public lastBurnRound;
    uint256 public lastBurnProposalId;

    // tokenAddress => round => proposalId => amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _proposalRewardAmount;
    // tokenAddress => round => proposalId => minted
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _proposalMinted;

    function setMintAmount(uint256 mintAmount_) external {
        mintAmount = mintAmount_;
    }

    function setRevertOnMint(bool revertOnMint_) external {
        revertOnMint = revertOnMint_;
    }

    function setRevertOnBurn(bool revertOnBurn_) external {
        revertOnBurn = revertOnBurn_;
    }

    function setProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 amount,
        bool minted
    ) external {
        _proposalRewardAmount[tokenAddress][round][proposalId] = amount;
        _proposalMinted[tokenAddress][round][proposalId] = minted;
    }

    function proposalRewardByProposalId(address tokenAddress, uint256 round, uint256 proposalId)
        external
        view
        returns (uint256 amount, bool minted)
    {
        return (_proposalRewardAmount[tokenAddress][round][proposalId], _proposalMinted[tokenAddress][round][proposalId]);
    }

    function mintProposalReward(address tokenAddress, uint256 round, uint256 proposalId)
        external
        returns (uint256 amount)
    {
        if (revertOnMint) revert MintProposalRewardReverted();
        mintCalls++;
        lastMintCaller = msg.sender;
        lastMintTokenAddress = tokenAddress;
        lastMintRound = round;
        lastMintProposalId = proposalId;
        _proposalMinted[tokenAddress][round][proposalId] = true;
        return mintAmount;
    }

    function burnUnmintedProposalReward(address tokenAddress, uint256 round, uint256 proposalId)
        external
        returns (uint256 amount)
    {
        if (revertOnBurn) revert BurnUnmintedProposalRewardReverted();
        burnCalls++;
        lastBurnCaller = msg.sender;
        lastBurnTokenAddress = tokenAddress;
        lastBurnRound = round;
        lastBurnProposalId = proposalId;
        _proposalMinted[tokenAddress][round][proposalId] = true;
        return _proposalRewardAmount[tokenAddress][round][proposalId];
    }
}

contract MockToken {
    bool public transferResult = true;
    uint256 public transferCalls;
    address public lastTransferTo;
    uint256 public lastTransferAmount;

    function setTransferResult(bool transferResult_) external {
        transferResult = transferResult_;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        transferCalls++;
        lastTransferTo = to;
        lastTransferAmount = amount;
        return transferResult;
    }
}

contract MockMemberNFT {
    error NonexistentToken(uint256 memberId);

    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 memberId, address owner) external {
        _owners[memberId] = owner;
    }

    function ownerOf(uint256 memberId) external view returns (address) {
        address owner = _owners[memberId];
        if (owner == address(0)) revert NonexistentToken(memberId);
        return owner;
    }
}

contract MockExecutor {
    error ActionTargetUnavailable();
    error CreatedCallbackReverted();
    error SubmittedCallbackReverted();
    error VotedCallbackReverted();
    error NeedBurnRewardReverted();

    address internal _actionTargetAddress;
    bool public revertActionTarget;
    bool public revertCreated;
    bool public revertSubmitted;
    bool public revertVoted;
    bool public needBurn;
    bool public revertNeedBurn;

    uint256 public createdCalls;
    uint256 public submittedCalls;
    uint256 public votedCalls;
    uint256 public lastCreatedProposalId;
    uint256 public lastSubmittedProposalId;
    uint256 public lastSubmittedSubmitterId;
    uint256 public lastVotedRound;
    uint256 public lastVotedProposalId;
    uint256 public lastVotedVoterId;
    uint256 public lastVotedVotes;
    address public lastCallbackTokenAddress;
    bytes32 public lastCreatedTargetDataHash;
    bytes32 public lastSubmittedTargetDataHash;
    bytes32 public lastVotedTargetDataHash;

    constructor(address actionTargetAddress_) {
        _actionTargetAddress = actionTargetAddress_;
    }

    function setActionTarget(address actionTargetAddress_) external {
        _actionTargetAddress = actionTargetAddress_;
    }

    function setRevertActionTarget(bool revertActionTarget_) external {
        revertActionTarget = revertActionTarget_;
    }

    function setRevertCreated(bool revertCreated_) external {
        revertCreated = revertCreated_;
    }

    function setRevertSubmitted(bool revertSubmitted_) external {
        revertSubmitted = revertSubmitted_;
    }

    function setRevertVoted(bool revertVoted_) external {
        revertVoted = revertVoted_;
    }

    function setNeedBurn(bool needBurn_) external {
        needBurn = needBurn_;
    }

    function setRevertNeedBurn(bool revertNeedBurn_) external {
        revertNeedBurn = revertNeedBurn_;
    }

    function actionTarget() external view returns (address) {
        if (revertActionTarget) revert ActionTargetUnavailable();
        return _actionTargetAddress;
    }

    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes[] calldata targetData
    ) external {
        createdCalls++;
        lastCallbackTokenAddress = tokenAddress;
        lastCreatedProposalId = proposalId;
        lastCreatedTargetDataHash = keccak256(abi.encode(targetData));
        if (revertCreated) revert CreatedCallbackReverted();
    }

    function onProposalSubmitted(
        address tokenAddress,
        uint256 proposalId,
        uint256 submitterId,
        bytes[] calldata targetData
    ) external {
        submittedCalls++;
        lastCallbackTokenAddress = tokenAddress;
        lastSubmittedProposalId = proposalId;
        lastSubmittedSubmitterId = submitterId;
        lastSubmittedTargetDataHash = keccak256(abi.encode(targetData));
        if (revertSubmitted) revert SubmittedCallbackReverted();
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 votes,
        bytes[] calldata targetData
    ) external {
        votedCalls++;
        lastCallbackTokenAddress = tokenAddress;
        lastVotedRound = round;
        lastVotedProposalId = proposalId;
        lastVotedVoterId = voterId;
        lastVotedVotes = votes;
        lastVotedTargetDataHash = keccak256(abi.encode(targetData));
        if (revertVoted) revert VotedCallbackReverted();
    }

    function needBurnReward(
        address,
        uint256,
        uint256
    ) external view returns (bool) {
        if (revertNeedBurn) revert NeedBurnRewardReverted();
        return needBurn;
    }
}
