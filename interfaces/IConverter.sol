
// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.6.6;

interface IConverter {
    function convert(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to
    ) external;

    function getAmountOut(uint256 amountIn, address[] calldata path) external view returns (uint256 amountOut);
    function getAmountIn(uint256 amountOut, address[] calldata path) external view returns (uint256 amountIn);
}