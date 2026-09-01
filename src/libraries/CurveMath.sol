// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CurveMath
/// @notice Constant-product bonding curve with a phantom (virtual) quote reserve, Pons V2 style.
/// @dev Reserves are
///        x = phantomQuote + realQuote   (quote side, fees excluded)
///        y = supply - tokensSold        (token side; the whole leg supply starts in the curve)
///      with k = phantomQuote * supply held constant. Tokens stop being sellable when
///      y == reserved = supply * phantom / (phantom + target), which is exactly when realQuote == target,
///      so graduation is triggered on the token side and can never be overshot.
library CurveMath {
    error CurveMathInsufficientReserve();

    /// @notice Tokens received for `dx` quote (fees already removed): dy = y * dx / (x + dx).
    function tokensOut(uint256 x, uint256 y, uint256 dx) internal pure returns (uint256 dy) {
        if (dx == 0) return 0;
        dy = (y * dx) / (x + dx);
    }

    /// @notice Quote required (rounded up) to receive exactly `dy` tokens: dx = x * dy / (y - dy) + 1.
    function quoteIn(uint256 x, uint256 y, uint256 dy) internal pure returns (uint256 dx) {
        if (dy == 0) return 0;
        if (dy >= y) revert CurveMathInsufficientReserve();
        dx = (x * dy) / (y - dy) + 1;
    }

    /// @notice Quote returned for selling `dy` tokens (before fees): dx = x * dy / (y + dy).
    function quoteOut(uint256 x, uint256 y, uint256 dy) internal pure returns (uint256 dx) {
        if (dy == 0) return 0;
        dx = (x * dy) / (y + dy);
    }

    /// @notice Tokens that remain in the curve at graduation: supply * phantom / (phantom + target).
    function reservedTokens(uint256 supply, uint256 phantomQuote, uint256 target) internal pure returns (uint256) {
        return (supply * phantomQuote) / (phantomQuote + target);
    }

    /// @notice Spot price scaled by 1e18 (quote wei per 1e18 token units).
    function spotPrice(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * 1e18) / y;
    }

    /// @notice Gross quote needed so that gross * (1e4 - feeBps) / 1e4 >= net, rounded up.
    function grossForNet(uint256 net, uint256 totalFeeBps) internal pure returns (uint256) {
        uint256 keep = 10_000 - totalFeeBps;
        return (net * 10_000 + keep - 1) / keep;
    }
}
