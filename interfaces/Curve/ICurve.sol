pragma solidity ^0.6.6;


interface ICurve {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable;
}