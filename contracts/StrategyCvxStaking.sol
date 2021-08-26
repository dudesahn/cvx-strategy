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
    address public sushiswap = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // default to sushiswap, more CRV and CVX liquidity there
    address[] public convexPath; // path to sell cvxCRV for more CVX

    IERC20 public constant cvxCrv =
        IERC20(0x62B9c7356A2Dc64a1969e19C23e4f579F9810Aa7);
    IERC20 public constant crv =
        IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public constant weth =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant cvx =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);

    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    string internal stratName; // we use this to be able to adjust our strategy's name

    // only need this in emergencies
    bool public claim;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault, string memory _stratName)
        public
        BaseStrategy(_vault)
    {
        // initialize variables
        minReportDelay = 0;
        maxReportDelay = 7 days; // 7 days in seconds, if we hit this then harvestTrigger = True
        profitFactor = 1_000; // in this strategy, profitFactor is only used for telling keep3rs when to move funds from vault to strategy
        debtThreshold = 5 * 1e18; // we shouldn't ever have loss, but set a bit of a buffer
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth

        // want is CVX
        want.approve(cvxStaking, type(uint256).max);

        // approve our reward token
        cvxCrv.approve(sushiswap, type(uint256).max);

        // swap path. sadly this is the only way to do things currently :(
        convexPath = [
            address(cvxCrv),
            address(crv),
            address(weth),
            address(cvx)
        ];

        // set our strategy's name
        stratName = _stratName;
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function stakedBalance() public view returns (uint256) {
        return IStaking(cvxStaking).balanceOf(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
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
        // claim our rewards but don't re-stake them
        IStaking(cvxStaking).getReward(false);

        // sell our claimed rewards for more CVX
        uint256 cvxRewards = IERC20(cvxCrv).balanceOf(address(this));
        if (cvxRewards > 0) {
            IUniswapV2Router02(sushiswap).swapExactTokensForTokens(
                cvxRewards,
                uint256(0),
                convexPath,
                address(this),
                now
            );
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                // can't withdraw 0
                IStaking(cvxStaking).withdraw(
                    Math.min(_stakedBal, _debtOutstanding),
                    false
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // send all of our want tokens to be deposited
        uint256 _toInvest = balanceOfWant();
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
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                // can't withdraw 0
                IStaking(cvxStaking).withdraw(
                    Math.min(_stakedBal, _amountNeeded.sub(_wantBal)),
                    false
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // can't withdraw 0
            IStaking(cvxStaking).withdraw(_stakedBal, false);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // can't withdraw 0
            IStaking(cvxStaking).withdraw(_stakedBal, claim);
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
        return new address[](0);
    }

    /* ========== KEEP3RS ========== */

    // our main trigger is regarding our DCA since there is low liquidity for $XYZ
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        return super.harvestTrigger(callCostinEth);
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
                IUniswapV2Router02(sushiswap).getAmountsOut(_amtInWei, ethPath);

            _ethToWant = callCostInWant[callCostInWant.length - 1];
        }
        return _ethToWant;
    }

    /* ========== SETTERS ========== */

    // This allows us to change the name of a strategy
    function setName(string calldata _stratName) external onlyAuthorized {
        stratName = _stratName;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    // We usually don't need to claim rewards on withdrawals, but might change our mind for migrations etc
    function setClaim(bool _claim) external onlyAuthorized {
        claim = _claim;
    }
}
