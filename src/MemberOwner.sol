// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";

library MemberOwner {
    function ofOrZero(address memberNFT, uint256 memberId) internal view returns (address owner) {
        try IMemberNFT(memberNFT).ownerOf(memberId) returns (address resolved) {
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
