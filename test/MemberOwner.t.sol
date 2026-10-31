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

contract MockEmptyRevertNFT {
    fallback() external {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }
}

contract MockOneByteRevertNFT {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0xab00000000000000000000000000000000000000000000000000000000000000)
            revert(0, 1)
        }
    }
}

contract MemberOwnerLookupHarness {
    function lookup(address memberNFTAddress, uint256 memberId) external view returns (address) {
        return MemberOwner.ownerOrZero(memberNFTAddress, memberId);
    }
}

contract MemberOwnerLookupTest is Test {
    MemberOwnerLookupHarness internal harness;

    function setUp() public {
        harness = new MemberOwnerLookupHarness();
    }

    function testOwnerOrZeroMapsNonexistentToken() public {
        MockMemberOwnerNFT nft = new MockMemberOwnerNFT();
        assertEq(MemberOwner.ownerOrZero(address(nft), 0), address(0));
    }

    function testOwnerOrZeroRethrowsUnexpectedFailure() public {
        MockMemberOwnerNFT nft = new MockMemberOwnerNFT();
        vm.expectRevert(MockMemberOwnerNFT.UnexpectedOwnerFailure.selector);
        harness.lookup(address(nft), 1);
    }

    function testOwnerOrZeroRethrowsEmptyFailure() public {
        MockEmptyRevertNFT nft = new MockEmptyRevertNFT();
        vm.expectRevert(bytes(""));
        harness.lookup(address(nft), 1);
    }

    function testOwnerOrZeroRethrowsShortFailure() public {
        MockOneByteRevertNFT nft = new MockOneByteRevertNFT();
        vm.expectRevert(bytes(hex"ab"));
        harness.lookup(address(nft), 1);
    }
}
