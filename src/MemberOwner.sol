// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMemberNFT} from "@core/interfaces/IMemberNFT.sol";

library MemberOwner {
    // Load-bearing: an absent id yields address(0). Callers turn that into a failed code check, an
    // authorization miss, or a `GroupNotExist` revert. If ownerOf ever returned a non-zero owner for
    // an absent id, the code-check callers would answer true and the views would silently report
    // live data for a group that does not exist. Other failures pass through unchanged.
    function ownerOrZero(address memberNFTAddress, uint256 memberId) internal view returns (address) {
        try IMemberNFT(memberNFTAddress).ownerOf(memberId) returns (address owner) {
            return owner;
        } catch (bytes memory err) {
            // casting to 'bytes4' is safe: the length check guarantees the first four bytes exist
            // forge-lint: disable-next-line(unsafe-typecast)
            if (err.length >= 4 && bytes4(err) == IERC721Errors.ERC721NonexistentToken.selector) {
                return address(0);
            }
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}
