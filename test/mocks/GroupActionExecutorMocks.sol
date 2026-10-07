// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

contract MockGroupActionExecutorStake {
    address public memberNFTAddress;
    address public phaseAddress;
    address public voteAddress;

    // tokenAddress => global gov votes
    mapping(address => uint256) internal _globalGovVotes;
    // tokenAddress => memberId => valid gov votes
    mapping(address => mapping(uint256 => uint256)) internal _validGovVotes;

    function setMemberNFTAddress(address memberNFTAddress_) external {
        memberNFTAddress = memberNFTAddress_;
    }

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setVoteAddress(address voteAddress_) external {
        voteAddress = voteAddress_;
    }

    function setGlobalGovVotes(address tokenAddress, uint256 votes) external {
        _globalGovVotes[tokenAddress] = votes;
    }

    function setValidGovVotes(address tokenAddress, uint256 memberId, uint256 votes) external {
        _validGovVotes[tokenAddress][memberId] = votes;
    }

    function globalGovVotes(address tokenAddress) external view returns (uint256) {
        return _globalGovVotes[tokenAddress];
    }

    function validGovVotes(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _validGovVotes[tokenAddress][memberId];
    }
}

contract MockGroupActionVote {
    // tokenAddress => round => total votes
    mapping(address => mapping(uint256 => uint256)) internal _votesNum;
    // tokenAddress => round => proposalId => votes
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _votesNumByProposalId;

    function setVotesNum(address tokenAddress, uint256 round, uint256 votes) external {
        _votesNum[tokenAddress][round] = votes;
    }

    function setVotesNumByProposalId(address tokenAddress, uint256 round, uint256 proposalId, uint256 votes) external {
        _votesNumByProposalId[tokenAddress][round][proposalId] = votes;
    }

    function votesNum(address tokenAddress, uint256 round) external view returns (uint256) {
        return _votesNum[tokenAddress][round];
    }

    function votesNumByProposalId(address tokenAddress, uint256 round, uint256 proposalId) external view returns (uint256) {
        return _votesNumByProposalId[tokenAddress][round][proposalId];
    }
}

contract MockGroupActionExecutorActionTarget {
    // tokenAddress => actionId => memberId => joined
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _joined;
    // tokenAddress => actionId => round => reward amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _actionRewardAmount;
    // tokenAddress => actionId => round => reward minted
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _actionRewardMinted;

    uint256 public mintReturnAmount;
    uint256 public registerCalls;
    uint256 public clearCalls;
    uint256 public mintRewardCalls;
    address public lastRegisterTokenAddress;
    uint256 public lastRegisterActionId;
    uint256 public lastRegisterMemberId;
    address public lastMintTokenAddress;
    uint256 public lastMintActionId;
    uint256 public lastMintRound;

    function setJoined(address tokenAddress, uint256 actionId, uint256 memberId, bool joined) external {
        _joined[tokenAddress][actionId][memberId] = joined;
    }

    function setActionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round,
        uint256 amount,
        bool minted
    ) external {
        _actionRewardAmount[tokenAddress][actionId][round] = amount;
        _actionRewardMinted[tokenAddress][actionId][round] = minted;
    }

    function setMintReturnAmount(uint256 mintReturnAmount_) external {
        mintReturnAmount = mintReturnAmount_;
    }

    function isJoined(address tokenAddress, uint256 actionId, uint256 memberId) external view returns (bool) {
        return _joined[tokenAddress][actionId][memberId];
    }

    function registerJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        registerCalls++;
        lastRegisterTokenAddress = tokenAddress;
        lastRegisterActionId = actionId;
        lastRegisterMemberId = memberId;
        _joined[tokenAddress][actionId][memberId] = true;
    }

    function clearJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        clearCalls++;
        _joined[tokenAddress][actionId][memberId] = false;
    }

    function actionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount, bool minted) {
        return (_actionRewardAmount[tokenAddress][actionId][round], _actionRewardMinted[tokenAddress][actionId][round]);
    }

    function mintActionReward(address tokenAddress, uint256 actionId, uint256 round) external returns (uint256) {
        mintRewardCalls++;
        lastMintTokenAddress = tokenAddress;
        lastMintActionId = actionId;
        lastMintRound = round;
        _actionRewardAmount[tokenAddress][actionId][round] = mintReturnAmount;
        _actionRewardMinted[tokenAddress][actionId][round] = true;
        return mintReturnAmount;
    }
}

contract MockGroupActionToken {
    mapping(address => uint256) internal _balanceOf;
    mapping(address => mapping(address => uint256)) internal _allowance;
    uint256 internal _totalSupply;

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balanceOf[to] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowance[msg.sender][spender] = amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balanceOf[msg.sender] -= amount;
        _balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            _allowance[from][msg.sender] = allowed - amount;
        }
        _balanceOf[from] -= amount;
        _balanceOf[to] += amount;
        return true;
    }
}
