// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";

library MemberOwner {
    // Load-bearing: an absent id yields address(0). Callers turn that into a failed code check, an
    // authorization miss, or a `GroupNotExist` revert. If ownerOf ever returned a non-zero owner for
    // an absent id, the code-check callers would answer true and the views would silently report
    // live data for a group that does not exist. Other failures pass through unchanged.
    function ownerOrZero(address memberNFTAddress, uint256 memberId) internal view returns (address owner) {
        try IMemberNFT(memberNFTAddress).ownerOf(memberId) returns (address resolved) {
            return resolved;
        } catch (bytes memory err) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(err, 0x20))
            }
            if (err.length >= 4 && selector == IERC721Errors.ERC721NonexistentToken.selector) {
                return address(0);
            }
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}
