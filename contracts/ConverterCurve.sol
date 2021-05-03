// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IConverter.sol";
import "../interfaces/Curve/ICurve.sol";
import "../interfaces/ICurveCalculator.sol";

contract ConverterCurve is IConverter {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    mapping(address => int128) public address2coin;

    address public curve;
    ICurveCalculator public curveCalculator;

    constructor(
        address _curve,
        address[] memory _coins,
        address _curveCalculator
    ) public {
        curve = _curve;
        curveCalculator = ICurveCalculator(_curveCalculator);

        int128 _i = 0;
        for (uint256 i = 0; i < _coins.length; i++) {
            address2coin[_coins[i]] = _i;

            IERC20(_coins[i]).safeApprove(_curve, type(uint256).max);

            _i++;
        }
    }

    function convert(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to
    ) external override {
        IERC20 coinI = IERC20(path[0]);
        IERC20 coinJ = IERC20(path[1]);

        coinI.safeTransferFrom(msg.sender, address(this), amountIn);

        ICurve(curve).exchange(address2coin[path[0]], address2coin[path[1]], amountIn, amountOutMin);

        coinJ.safeTransfer(msg.sender, coinJ.balanceOf(address(this)));
        coinI.safeTransfer(msg.sender, coinI.balanceOf(address(this)));
    }

    function getAmountOut(uint256 amountIn, address[] calldata path) external override view returns (uint256 amountOut) {
        return curveCalculator.get_dy(curve, address2coin[path[0]], address2coin[path[1]], amountIn);
    }

    function getAmountIn(uint256 amountOut, address[] calldata path) external override view returns (uint256 amountIn) {
        return curveCalculator.get_dx(curve, address2coin[path[0]], address2coin[path[1]], amountOut);
    }
}