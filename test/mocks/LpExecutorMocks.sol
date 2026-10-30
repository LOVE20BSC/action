// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "@core/interfaces/IPhase.sol";

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockLpPhase {
    error PhaseInfoNotConfigured(uint256 phase);

    struct PhaseInfo {
        uint256 startBlock;
        uint256 phaseBlocks;
    }

    uint256 internal _currentPhase;
    mapping(uint256 => PhaseInfo) internal _phaseInfoByPhase;

    function setCurrentPhase(uint256 currentPhase_) external {
        _currentPhase = currentPhase_;
    }

    function setPhaseInfo(uint256 phase, uint256 startBlock, uint256 phaseBlocks) external {
        _phaseInfoByPhase[phase] = PhaseInfo(startBlock, phaseBlocks);
    }

    function currentPhase() external view returns (uint256) {
        return _currentPhase;
    }

    function phaseInfo(uint256 phase) external view returns (uint256 startBlock, uint256 phaseBlocks) {
        PhaseInfo memory info = _phaseInfoByPhase[phase];
        if (info.phaseBlocks == 0) {
            revert PhaseInfoNotConfigured(phase);
        }
        return (info.startBlock, info.phaseBlocks);
    }
}

contract MockLpStake {
    address public memberNFTAddress;
    address public phaseAddress;
    address public pairFactoryAddress;

    // tokenAddress => total valid gov votes
    mapping(address => uint256) internal _totalValidGovVotes;
    // tokenAddress => memberId => valid gov votes
    mapping(address => mapping(uint256 => uint256)) internal _validGovVotes;

    function setMemberNFTAddress(address memberNFTAddress_) external {
        memberNFTAddress = memberNFTAddress_;
    }

    function setPhaseAddress(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    function setPairFactoryAddress(address pairFactoryAddress_) external {
        pairFactoryAddress = pairFactoryAddress_;
    }

    function MEMBER_NFT_ADDRESS() external view returns (address) {
        return memberNFTAddress;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return phaseAddress;
    }

    function PAIR_FACTORY_ADDRESS() external view returns (address) {
        return pairFactoryAddress;
    }

    function setTotalValidGovVotes(address tokenAddress, uint256 votes) external {
        _totalValidGovVotes[tokenAddress] = votes;
    }

    function setValidGovVotes(address tokenAddress, uint256 memberId, uint256 votes) external {
        _validGovVotes[tokenAddress][memberId] = votes;
    }

    // The real `Stake` is round-keyed; this double answers only the phase's current round (zero otherwise).
    function totalValidGovVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        if (round != IPhase(phaseAddress).currentPhase()) return 0;
        return _totalValidGovVotes[tokenAddress];
    }

    function validGovVotes(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256) {
        if (round != IPhase(phaseAddress).currentPhase()) return 0;
        return _validGovVotes[tokenAddress][memberId];
    }
}

contract MockLpMemberNFT {
    mapping(uint256 => address) internal _owners;

    function setOwner(uint256 memberId, address owner) external {
        _owners[memberId] = owner;
    }

    function ownerOf(uint256 memberId) external view returns (address) {
        address owner = _owners[memberId];
        if (owner == address(0)) {
            revert IERC721Errors.ERC721NonexistentToken(memberId);
        }
        return owner;
    }
}

contract MockLpActionTarget {
    error RegisterJoinStateReverted();
    error ClearJoinStateReverted();
    error MintActionRewardReverted();

    event JoinStateCleared(
        address indexed tokenAddress,
        uint256 indexed actionId,
        uint256 indexed memberId,
        uint256 round,
        bool forced
    );

    // tokenAddress => actionId => memberId => joined
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _joined;
    // tokenAddress => actionId => round => reward amount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _actionRewardAmount;
    // tokenAddress => actionId => round => reward minted
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _actionRewardMinted;

    bool public revertRegister;
    bool public revertClear;
    bool public revertMint;
    bool public emitClearEvent;
    uint256 public mintReturnAmount;

    uint256 public registerCalls;
    uint256 public clearCalls;
    uint256 public mintRewardCalls;
    address public lastRegisterTokenAddress;
    uint256 public lastRegisterActionId;
    uint256 public lastRegisterMemberId;
    address public lastClearTokenAddress;
    uint256 public lastClearActionId;
    uint256 public lastClearMemberId;
    address public lastMintTokenAddress;
    uint256 public lastMintActionId;
    uint256 public lastMintRound;

    function setJoined(address tokenAddress, uint256 actionId, uint256 memberId, bool joined) external {
        _joined[tokenAddress][actionId][memberId] = joined;
    }

    function setRevertRegister(bool revertRegister_) external {
        revertRegister = revertRegister_;
    }

    function setRevertClear(bool revertClear_) external {
        revertClear = revertClear_;
    }

    function setRevertMint(bool revertMint_) external {
        revertMint = revertMint_;
    }

    function setEmitClearEvent(bool emitClearEvent_) external {
        emitClearEvent = emitClearEvent_;
    }

    function setMintReturnAmount(uint256 mintReturnAmount_) external {
        mintReturnAmount = mintReturnAmount_;
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

    function isJoined(address tokenAddress, uint256 actionId, uint256 memberId) external view returns (bool) {
        return _joined[tokenAddress][actionId][memberId];
    }

    function registerJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        if (revertRegister) {
            revert RegisterJoinStateReverted();
        }
        registerCalls++;
        lastRegisterTokenAddress = tokenAddress;
        lastRegisterActionId = actionId;
        lastRegisterMemberId = memberId;
        _joined[tokenAddress][actionId][memberId] = true;
    }

    function clearJoinState(address tokenAddress, uint256 actionId, uint256 memberId) external {
        if (revertClear) {
            revert ClearJoinStateReverted();
        }
        clearCalls++;
        lastClearTokenAddress = tokenAddress;
        lastClearActionId = actionId;
        lastClearMemberId = memberId;
        _joined[tokenAddress][actionId][memberId] = false;
        if (emitClearEvent) {
            emit JoinStateCleared({
                tokenAddress: tokenAddress,
                actionId: actionId,
                memberId: memberId,
                round: 0,
                forced: false
            });
        }
    }

    function actionReward(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256 amount, bool minted) {
        return (_actionRewardAmount[tokenAddress][actionId][round], _actionRewardMinted[tokenAddress][actionId][round]);
    }

    function mintActionReward(address tokenAddress, uint256 actionId, uint256 round) external returns (uint256) {
        if (revertMint) {
            revert MintActionRewardReverted();
        }
        mintRewardCalls++;
        lastMintTokenAddress = tokenAddress;
        lastMintActionId = actionId;
        lastMintRound = round;
        _actionRewardAmount[tokenAddress][actionId][round] = mintReturnAmount;
        _actionRewardMinted[tokenAddress][actionId][round] = true;
        return mintReturnAmount;
    }
}

contract MockRevertingPair {
    error TokenReverted();

    function token0() external pure returns (address) {
        revert TokenReverted();
    }

    function token1() external pure returns (address) {
        revert TokenReverted();
    }
}

contract MockRevertingPairToken1 {
    error Token1Reverted();

    address internal immutable _token0;

    constructor(address token0_) {
        _token0 = token0_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external pure returns (address) {
        revert Token1Reverted();
    }
}

contract MockRevertingPairFactory {
    error GetPairReverted();

    function getPair(address, address) external pure returns (address) {
        revert GetPairReverted();
    }
}

contract MockERC20 {
    mapping(address => uint256) internal _balanceOf;
    uint256 internal _totalSupply;

    bool public failTransfer;
    uint256 public transferCalls;
    uint256 public burnCalls;
    uint256 public lastBurnAmount;

    function setFailTransfer(bool failTransfer_) external {
        failTransfer = failTransfer_;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _balanceOf[to] += amount;
    }

    function burn(uint256 amount) external {
        burnCalls++;
        lastBurnAmount = amount;
        _balanceOf[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        transferCalls++;
        if (failTransfer) {
            return false;
        }
        _balanceOf[msg.sender] -= amount;
        _balanceOf[to] += amount;
        return true;
    }
}
