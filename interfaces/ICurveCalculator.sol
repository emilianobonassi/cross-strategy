
// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.6.6;

interface ICurveCalculator {
    function get_dx(address curve, int128 i, int128 j, uint256 dy) external view returns (uint256 dx);
    function get_dy(address curve, int128 i, int128 j, uint256 dx) external view returns (uint256 dy);
}