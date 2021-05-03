// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategyInitializable,
    StrategyParams,
    VaultAPI
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/IConverter.sol";
import "../interfaces/Uniswap/IUniswapRouter.sol";


contract CrossAssetStrategy is BaseStrategyInitializable {
    using SafeERC20 for ERC20;
    using Address for address;
    using SafeMath for uint256;

    VaultAPI public underlyingVault;
    IConverter public converter;
    IUniswapRouter public uniswapRouter;
    address public weth;

    address[] internal _path;
    address[] internal _invertedPath;

    modifier onlyGovernanceOrManagement() {
        require(
            msg.sender == governance() || msg.sender == vault.management(),
            "!authorized"
        );
        _;
    }

    constructor(
        address _vault,
        address _underlyingVault,
        address _converter,
        address _uniswapRouter,
        address _weth
    ) public BaseStrategyInitializable(_vault) {
        _init(
            _underlyingVault,
            _converter,
            _uniswapRouter,
            _weth
        );
    }

    function init(
        address _vault,
        address _onBehalfOf,
        address _underlyingVault,
        address _converter,
        address _uniswapRouter,
        address _weth
    ) external {
        super._initialize(_vault, _onBehalfOf, _onBehalfOf, _onBehalfOf);

        _init(
            _underlyingVault,
            _converter,
            _uniswapRouter,
            _weth
        );
    }

    function _init(
        address _underlyingVault,
        address _converter,
        address _uniswapRouter,
        address _weth
    ) internal {
        underlyingVault = VaultAPI(_underlyingVault);
        converter = IConverter(_converter);
        uniswapRouter = IUniswapRouter(uniswapRouter);
        weth = _weth;

        _path = new address[](2);
        _path[0] = address(want); 
        _path[1] = underlyingVault.token();

        _invertedPath = new address[](2);
        _invertedPath[0] = _path[1];
        _invertedPath[1] = _path[0];

        ERC20(_path[0]).safeApprove(_converter, type(uint256).max);
        ERC20(_path[1]).safeApprove(_converter, type(uint256).max);
        ERC20(_path[1]).safeApprove(_underlyingVault, type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "CrossStrategy", 
                    ERC20(address(want)).symbol(), 
                    ERC20(underlyingVault.token()).symbol()
                )
            );
    }

    /**
     * @notice
     *  The amount (priced in want) of the total assets managed by this strategy should not count
     *  towards Yearn's TVL calculations.
     * @dev
     *  You can override this field to set it to a non-zero value if some of the assets of this
     *  Strategy is somehow delegated inside another part of of Yearn's ecosystem e.g. another Vault.
     *  Note that this value must be strictly less than or equal to the amount provided by
     *  `estimatedTotalAssets()` below, as the TVL calc will be total assets minus delegated assets.
     *  Also note that this value is used to determine the total assets under management by this
     *  strategy, for the purposes of computing the management fee in `Vault`
     * @return
     *  The amount of assets this strategy manages that should not be included in Yearn's Total Value
     *  Locked (TVL) calculation across it's ecosystem.
     */
    function delegatedAssets() external view override returns (uint256) {
        StrategyParams memory params = vault.strategies(address(this));
        return Math.min(params.totalDebt, _balanceOnUnderlyingVault());
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return _balanceOfWantExcludingUnderlyingWant().add(
            converter.getAmountOut(
                _balanceOnUnderlyingVault()
                .add(_balanceOfUnderlyingWant()),
                _invertedPath
            ));
    }

    function _balanceOfWantExcludingUnderlyingWant() internal view returns (uint256) {
        return ERC20(address(want)).balanceOf(address(this));
    }

    function _balanceOfWant() internal view returns (uint256) {
        return 
            (ERC20(address(want)).balanceOf(address(this)))
            .add(converter.getAmountOut(_balanceOfUnderlyingWant(), _invertedPath))
        ;
    }

    function _balanceOfUnderlyingWant() internal view returns (uint256) {
        return ERC20(underlyingVault.token()).balanceOf(address(this));
    }

    function _balanceOnUnderlyingVault() internal view returns (uint256) {
        return
            underlyingVault
                .balanceOf(address(this))
                .mul(underlyingVault.pricePerShare())
                .div(10**underlyingVault.decimals());
    }

    function ethToWant(uint256 _amount) internal view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(want);
        uint256[] memory amounts =
            IUniswapRouter(uniswapRouter).getAmountsOut(_amount, path);

        return amounts[1];
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 currentValue = estimatedTotalAssets();
        uint256 wantBalance = _balanceOfWant();

        // Calculate total profit w/o farming
        if (debt < currentValue) {
            _profit = currentValue.sub(debt);
        } else {
            _loss = debt.sub(currentValue);
        }

        // To withdraw = profit from lending + _debtOutstanding
        uint256 toFree = _debtOutstanding.add(_profit);

        // In the case want is not enough, divest from idle
        if (toFree > wantBalance) {
            // Divest only the missing part = toFree-wantBalance
            toFree = toFree.sub(wantBalance);
            (uint256 _liquidatedAmount, ) = liquidatePosition(toFree);

            // loss in the case freedAmount less to be freed
            uint256 withdrawalLoss =
                _liquidatedAmount < toFree ? toFree.sub(_liquidatedAmount) : 0;

            // profit recalc
            if (withdrawalLoss < _profit) {
                _profit = _profit.sub(withdrawalLoss);
            } else {
                _loss = _loss.add(withdrawalLoss.sub(_profit));
                _profit = 0;
            }
        }

        // Recalculate profit
        wantBalance = _balanceOfWantExcludingUnderlyingWant();

        if (wantBalance < _profit) {
            _profit = wantBalance;
            _debtPayment = 0;
        } else if (wantBalance < _debtOutstanding.add(_profit)) {
            _debtPayment = wantBalance.sub(_profit);
        } else {
            _debtPayment = _debtOutstanding;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: Do something to invest excess `want` tokens (from the Vault) into your positions
        // NOTE: Try to adjust positions so that `_debtOutstanding` can be freed up on *next* harvest (not immediately)

        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }

        uint256 balanceOfWant = _balanceOfWant();
        if (balanceOfWant > _debtOutstanding) {
            uint256 balanceOfWantExcludingUnderlyingWant = _balanceOfWantExcludingUnderlyingWant();

            if (balanceOfWantExcludingUnderlyingWant > 0) {
                uint256 minAmount = balanceOfWantExcludingUnderlyingWant;

                uint256 wantDecimals = vault.decimals();
                uint256 underlyingDecimals = underlyingVault.decimals();

                if (wantDecimals > underlyingDecimals) {
                    minAmount = minAmount.mul(10**underlyingDecimals).mul(995).div(1000).div(10**wantDecimals);
                } else if (wantDecimals < underlyingDecimals) {
                    minAmount = minAmount.mul(10**wantDecimals).mul(995).div(1000).div(10**underlyingDecimals);
                }

                converter.convert(
                    balanceOfWantExcludingUnderlyingWant,
                    minAmount, // TODO: add slippage protection
                    _path,
                    address(this)
                );
            }

            underlyingVault.deposit(_balanceOfUnderlyingWant());
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`

        // Get current want
        uint256 balanceOfWant = _balanceOfWantExcludingUnderlyingWant();

        if (balanceOfWant < _amountNeeded) {
            uint256 amountToRedeem = _amountNeeded.sub(balanceOfWant);

            uint256 underlyingAmountToRedeem = converter.getAmountIn(
                amountToRedeem, _invertedPath
            );

            uint256 valueToRedeemApprox =
                underlyingAmountToRedeem.mul(10**underlyingVault.decimals()).div(
                    underlyingVault.pricePerShare()
                );
            uint256 valueToRedeem =
                Math.min(
                    valueToRedeemApprox,
                    underlyingVault.balanceOf(address(this))
                );

            underlyingVault.withdraw(valueToRedeem);

            converter.convert(
                _balanceOfUnderlyingWant(),
                amountToRedeem.mul(995).div(1000),
                _invertedPath,
                address(this)
            );
        }

        // _liquidatedAmount min(_amountNeeded, balanceOfWant), otw vault accounting breaks
        balanceOfWant = _balanceOfWantExcludingUnderlyingWant();

        if (balanceOfWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = balanceOfWant;
            _loss = _amountNeeded.sub(balanceOfWant);
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function harvestTrigger(uint256 callCost)
        public
        view
        override
        returns (bool)
    {
        return super.harvestTrigger(ethToWant(callCost));
    }

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one

        underlyingVault.withdraw(type(uint256).max, _newStrategy);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](2);

        protected[0] = underlyingVault.token();
        protected[1] = address(underlyingVault);

        return protected;
    }

    function clone(
        address _vault,
        address _onBehalfOf,
        address _underlyingVault,
        address _converter,
        address _uniswapRouter,
        address _weth
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        CrossAssetStrategy(newStrategy).init(
            _vault,
            _onBehalfOf,
            _underlyingVault,
            _converter,
            _uniswapRouter,
            _weth
        );

        emit Cloned(newStrategy);
    }
}
