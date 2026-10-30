// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MemberOwner} from "../src/MemberOwner.sol";

contract MockMemberOwnerNFT {
    error UnexpectedOwnerFailure();

    function ownerOf(uint256 memberId) external pure returns (address) {
        if (memberId == 0) {
            revert IERC721Errors.ERC721NonexistentToken(memberId);
        }
        revert UnexpectedOwnerFailure();
    }
}

contract MemberOwnerTest is Test {
    function testOfOrZeroMapsNonexistentToken() public {
        MockMemberOwnerNFT nft = new MockMemberOwnerNFT();
        assertEq(MemberOwner.ownerOrZero(address(nft), 0), address(0));
    }

    function testOfOrZeroRethrowsUnexpectedFailure() public {
        MockMemberOwnerNFT nft = new MockMemberOwnerNFT();

        vm.expectRevert(MockMemberOwnerNFT.UnexpectedOwnerFailure.selector);
        MemberOwner.ownerOrZero(address(nft), 1);
    }
}
