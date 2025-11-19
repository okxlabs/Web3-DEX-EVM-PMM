// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IPMMSettler {
    /**
     * @notice Interface for interactor which acts for `maker -> taker` transfers.
     * @param taker Taker address
     * @param token Settle token address
     * @param amount Settle token amount
     * @param isUnwrap Whether unwrap WETH
     */
    function settleToTaker(address taker, address token, uint256 amount, bool isUnwrap) external;

    /**
     * @notice Returns the settlement treasury address.
     */
    function getTreasury() external view returns (address);
}
