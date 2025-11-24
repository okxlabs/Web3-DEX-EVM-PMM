// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "../../src/interfaces/IPMMSettler.sol";
import "../../src/interfaces/IWETH.sol";
import "../../src/interfaces/IERC20.sol";

contract MockPMMSettler is IPMMSettler {
    IWETH public weth;
    address public treasury;
    bool public shouldTransferLess;
    uint256 public transferAmount;

    constructor(address _weth) {
        weth = IWETH(_weth);
    }

    function setTreasury(address _treasury) external {
        treasury = _treasury;
    }

    function setShouldTransferLess(bool _shouldTransferLess) external {
        shouldTransferLess = _shouldTransferLess;
    }

    function setTransferAmount(uint256 _transferAmount) external {
        transferAmount = _transferAmount;
    }

    function settleToTaker(address taker, address token, uint256 amount, bool isUnwrap) external override {
        uint256 actualAmount = shouldTransferLess ? transferAmount : amount;

        if (isUnwrap && token == address(weth)) {
            // Transfer WETH from treasury to this contract
            IERC20(token).transferFrom(treasury, address(this), actualAmount);
            // Unwrap WETH
            weth.withdraw(actualAmount);
            // Send ETH to taker
            payable(taker).transfer(actualAmount);
        } else {
            // Transfer token from treasury to taker
            IERC20(token).transferFrom(treasury, taker, actualAmount);
        }
    }

    function getTreasury() external view override returns (address) {
        return treasury;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
