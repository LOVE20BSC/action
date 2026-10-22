// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockGroupActionPhase {
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

contract MockGroupActionMemberNFT {
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
