// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IStaking {
    function getReward(bool _stake) external; // claim our rewards

    function stake(uint256 _amount) external; // this is depositing

    function withdraw(uint256 _amount, bool claim) external;

    function balanceOf(address account) external view returns (uint256);
}

contract StrategyCvxStaking is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    address public constant cvxStaking =
        0xCF50b810E57Ac33B91dCF525C6ddd9881B139332;

    // Swap stuff

    address public sushiswapRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // default to sushiswap, more CRV and CVX liquidity there
    address[] public convexPath; // path to sell cvxCRV for more CVX
    IERC20 public constant cvxCrv =
        IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);
    IERC20 public constant crv =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant cvx =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 public constant weth =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // only need this in emergencies
    bool public claim;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {
        // initialize variables
        minReportDelay = 0;
        maxReportDelay = 604800; // 7 days in seconds, if we hit this then harvestTrigger = True
        profitFactor = 400;
        debtThreshold = 500 * 1e18; // we shouldn't ever have loss, but set a bit of a buffer
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012); // health.ychad.eth

        // want is CVX
        want.safeApprove(address(cvxStaking), type(uint256).max);

        // approve our reward token
        cvxCrv.safeApprove(sushiswapRouter, type(uint256).max);

        // swap path
        convexPath = new address[](4);
        convexPath[0] = address(cvxCrv);
        convexPath[1] = address(crv);
        convexPath[2] = address(weth);
        convexPath[3] = address(cvx);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return "StrategyCvxStaking";
    }

    function _stakedBalance() public view returns (uint256) {
        return IStaking(cvxStaking).balanceOf(address(this));
    }

    function _balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return _balanceOfWant().add(_stakedBalance());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // claim our rewards
        IStaking(cvxStaking).getReward(false);

        // sell our claimed rewards for more CVX
        uint256 cvxRewards = IERC20(cvxCrv).balanceOf(address(this));
        if (cvxRewards > 0) {
            IUniswapV2Router02(sushiswapRouter).swapExactTokensForTokens(
                cvxRewards,
                uint256(0),
                convexPath,
                address(this),
                now
            );
        }

        // serious loss should never happen, but if it does (for instance, if convex is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great! loss will be 0 by default
        if (assets > debt) {
            _profit = assets.sub(debt);
        } else {
            // if assets are less than debt, we are in trouble. profit will be 0 by default
            _loss = debt.sub(assets);
        }

        // debtOustanding will only be > 0 in the event of revoking or lowering debtRatio of a strategy
        if (_debtOutstanding > 0) {
            if (_stakedBalance() > 0) {
                // can't withdraw 0
                IStaking(cvxStaking).withdraw(
                    Math.min(_stakedBalance(), _debtOutstanding),
                    false
                );
            }
            uint256 withdrawnBal = _balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, withdrawnBal);
            if (_debtPayment < _debtOutstanding) {
                _loss = _debtOutstanding.sub(_debtPayment);
                _profit = 0;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // send all of our want tokens to be deposited
        uint256 _toInvest = _balanceOfWant();
        // stake only if we have something to stake
        if (_toInvest > 0) {
            IStaking(cvxStaking).stake(_toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBal = _balanceOfWant();
        if (_amountNeeded > wantBal) {
            if (_stakedBalance() > 0) {
                // can't withdraw 0
                IStaking(cvxStaking).withdraw(
                    Math.min(_stakedBalance(), _amountNeeded.sub(wantBal)),
                    false
                );
            }
            uint256 withdrawnBal = _balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        if (_stakedBalance() > 0) {
            // can't withdraw 0
            IStaking(cvxStaking).withdraw(_stakedBalance(), false);
        }
        return _balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (_stakedBalance() > 0) {
            // can't withdraw 0
            IStaking(cvxStaking).withdraw(_stakedBalance(), claim);
        }
        uint256 cvxRewards = IERC20(cvxCrv).balanceOf(address(this));
        if (cvxRewards > 0) {
            IERC20(cvxCrv).safeTransfer(_newStrategy, cvxRewards);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](0);
        return protected;
    }

    // our main trigger is regarding our DCA since there is low liquidity for $XYZ
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // Should not trigger if Strategy is not activated
        if (params.activation == 0) return false;

        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp.sub(params.lastReport) < minReportDelay)
            return false;

        // Should trigger if hasn't been called in a while
        if (block.timestamp.sub(params.lastReport) >= maxReportDelay)
            return true;

        // If some amount is owed, pay it back
        // NOTE: Since debt is based on deposits, it makes sense to guard against large
        //       changes to the value from triggering a harvest directly through user
        //       behavior. This should ensure reasonable resistance to manipulation
        //       from user-initiated withdrawals as the outstanding debt fluctuates.
        uint256 outstanding = vault.debtOutstanding();
        if (outstanding > debtThreshold) return true;

        // Check for profits and losses
        uint256 total = estimatedTotalAssets();
        // Trigger if we have a loss to report
        if (total.add(debtThreshold) < params.totalDebt) return true;

        // Trigger if we haven't harvested in the last week
        uint256 week = 86400 * 7;
        if (block.timestamp.sub(params.lastReport) > week) {
            return true;
        }
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        uint256 _ethToWant = 0;
        if (_amtInWei > 0) {
            address[] memory ethPath = new address[](2);
            ethPath[0] = address(weth);
            ethPath[1] = address(want);

            uint256[] memory callCostInWant =
                IUniswapV2Router02(sushiswapRouter).getAmountsOut(
                    _amtInWei,
                    ethPath
                );

            _ethToWant = callCostInWant[callCostInWant.length - 1];
        }
        return _ethToWant;
    }

    // We usually don't need to claim rewards on withdrawals, but might change our mind for migrations etc
    function setClaim(bool _claim) external onlyAuthorized {
        claim = _claim;
    }
}
