// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";

contract SimpleTest is Test {
    function testBasic() public {
        assertTrue(true);
    }

    function testMath() public {
        assertEq(uint256(1 + 1), uint256(2));
    }
}
