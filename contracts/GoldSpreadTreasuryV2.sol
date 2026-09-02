// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GoldSpreadTreasuryV2
 * @notice Share-based gold treasury protocol.
 *
 * Core model:
 *
 *   IGD = ERC20 shares
 *
 *   NAV =
 *       XAUT balance valued at gold oracle price
 *       +
 *       USDT balance held by the protocol
 *
 *   IGD NAV/share =
 *       NAV / total IGD supply
 *
 * Buy:
 *
 *   USDT
 *      ↓
 *   buy spread
 *      ↓
 *   treasury vault
 *      ↓
 *   remaining USDT
 *      ↓
 *   aggregator
 *      ↓
 *   XAUT
 *      ↓
 *   calculate actual backing contribution
 *      ↓
 *   mint IGD shares
 *
 * Redeem:
 *
 *   IGD shares
 *      ↓
 *   calculate proportional XAUT
 *      ↓
 *   aggregator
 *      ↓
 *   USDT
 *      ↓
 *   sell spread
 *      ↓
 *   user
 *
 * IMPORTANT:
 * This contract does not itself certify physical gold ownership,
 * legal title, custody arrangements, or Shariah compliance.
 * Those claims require separate legal, custody, reserve and
 * Shariah-board verification.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";


interface AggregatorV3Interface {

    function decimals()
        external
        view
        returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}


contract GoldSpreadTreasuryV2
    is ERC20,
       Ownable,
       ReentrancyGuard,
       Pausable
{

    using SafeERC20 for IERC20;


    // =========================================================
    // CONSTANTS
    // =========================================================

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*
     * USDT and XAUT are normally 6 decimals.
     *
     * IGD uses 18 decimals.
     */
    uint256 public constant USDT_DECIMALS = 6;
    uint256 public constant XAUT_DECIMALS = 6;
    uint256 public constant IGD_DECIMALS = 18;

    uint256 public constant USDT_UNIT = 1e6;
    uint256 public constant XAUT_UNIT = 1e6;
    uint256 public constant IGD_UNIT = 1e18;


    // =========================================================
    // TOKENS
    // =========================================================

    IERC20 public immutable usdtToken;

    IERC20 public immutable xautToken;


    // =========================================================
    // ROUTER
    // =========================================================

    /*
     * The router is fixed by the owner.
     *
     * User calldata can only be sent to this address.
     */
    address public aggregatorRouter;


    // =========================================================
    // TREASURY
    // =========================================================

    /*
     * Spread revenue is sent here.
     *
     * IMPORTANT:
     * This external vault is NOT included in IGD backing NAV.
     */
    address public protocolTreasuryVault;


    // =========================================================
    // GOLD ORACLE
    // =========================================================

    AggregatorV3Interface public goldPriceOracle;

    /*
     * Maximum acceptable age of oracle data.
     *
     * Example:
     * 1 hour = 3600 seconds
     */
    uint256 public oracleMaxAge = 1 hours;


    // =========================================================
    // SPREAD
    // =========================================================

    /*
     * 25 BPS = 0.25%
     */
    uint256 public buySpreadBps = 25;

    uint256 public sellSpreadBps = 25;


    // =========================================================
    // RISK LIMITS
    // =========================================================

    /*
     * Default:
     *
     * 5,000 USDT
     *
     * Stored using USDT's 6 decimals.
     */
    uint256 public maxSwapCapLimit = 5_000 * USDT_UNIT;


    /*
     * Maximum IGD redemption per transaction.
     *
     * Default:
     *
     * 5,000 IGD
     */
    uint256 public maxRedeemTokenLimit = 5_000 * IGD_UNIT;


    // =========================================================
    // EVENTS
    // =========================================================

    event Minted(
        address indexed user,
        uint256 usdtDeposited,
        uint256 spreadPaid,
        uint256 xautAcquired,
        uint256 igdMinted,
        uint256 navPerShare
    );


    event Redeemed(
        address indexed user,
        uint256 igdBurned,
        uint256 xautSold,
        uint256 usdtReceived,
        uint256 spreadPaid,
        uint256 usdtPaid
    );


    event RouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );


    event TreasuryVaultUpdated(
        address indexed oldVault,
        address indexed newVault
    );


    event OracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );


    event OracleMaxAgeUpdated(
        uint256 oldAge,
        uint256 newAge
    );


    event SpreadsUpdated(
        uint256 buySpreadBps,
        uint256 sellSpreadBps
    );


    event SwapCapUpdated(
        uint256 newCap
    );


    event RedeemCapUpdated(
        uint256 newCap
    );


    // =========================================================
    // CONSTRUCTOR
    // =========================================================

    constructor(
        address _usdt,
        address _xaut,
        address _router,
        address _treasury,
        address _goldOracle
    )
        ERC20(
            "Islamic Gold Dollar",
            "IGD"
        )
        Ownable(msg.sender)
    {

        require(
            _usdt != address(0),
            "Invalid USDT"
        );

        require(
            _xaut != address(0),
            "Invalid XAUT"
        );

        require(
            _router != address(0),
            "Invalid router"
        );

        require(
            _treasury != address(0),
            "Invalid treasury"
        );

        require(
            _goldOracle != address(0),
            "Invalid gold oracle"
        );


        usdtToken =
            IERC20(_usdt);


        xautToken =
            IERC20(_xaut);


        aggregatorRouter =
            _router;


        protocolTreasuryVault =
            _treasury;


        goldPriceOracle =
            AggregatorV3Interface(
                _goldOracle
            );
    }


    // =========================================================
    // ERC20 DECIMALS
    // =========================================================

    function decimals()
        public
        pure
        override
        returns (uint8)
    {
        return 18;
    }


    // =========================================================
    // ORACLE
    // =========================================================

    /**
     * @notice Returns current gold price in USDT with 6 decimals.
     *
     * Example:
     *
     * $4,368.41
     *
     * becomes:
     *
     * 4,368,410,000
     *
     * when normalized to 6 decimals.
     */
    function goldPriceUsdt6()
        public
        view
        returns (uint256)
    {

        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) =
            goldPriceOracle.latestRoundData();


        require(
            answer > 0,
            "Invalid gold price"
        );


        require(
            updatedAt > 0,
            "Oracle timestamp missing"
        );


        require(
            block.timestamp - updatedAt
                <= oracleMaxAge,
            "Gold oracle stale"
        );


        uint8 oracleDecimals =
            goldPriceOracle.decimals();


        uint256 price =
            uint256(answer);


        if (oracleDecimals < 6) {

            return
                price *
                (10 ** (6 - oracleDecimals));

        }


        if (oracleDecimals > 6) {

            return
                price /
                (10 ** (oracleDecimals - 6));

        }


        return price;
    }


    // =========================================================
    // XAUT VALUATION
    // =========================================================

    /**
     * @notice Converts XAUT amount into USDT value.
     *
     * XAUT:
     * 6 decimals
     *
     * Gold price:
     * 6 decimals
     *
     * Result:
     * USDT 6 decimals
     */
    function xautValueUsdt6(
        uint256 xautAmount
    )
        public
        view
        returns (uint256)
    {

        uint256 goldPrice =
            goldPriceUsdt6();


        return
            (
                xautAmount *
                goldPrice
            ) /
            XAUT_UNIT;
    }


    // =========================================================
    // TOTAL BACKING
    // =========================================================

    /**
     * @notice Total protocol backing valued in USDT.
     *
     * Includes:
     *
     *   XAUT held by this contract
     *   +
     *   USDT held by this contract
     *
     * Does NOT include:
     *
     *   protocolTreasuryVault
     */
    function totalBackingValueUsdt()
        public
        view
        returns (uint256)
    {

        uint256 xautBalance =
            xautToken.balanceOf(
                address(this)
            );


        uint256 xautValue =
            xautValueUsdt6(
                xautBalance
            );


        uint256 usdtBalance =
            usdtToken.balanceOf(
                address(this)
            );


        return
            xautValue +
            usdtBalance;
    }


    // =========================================================
    // NAV PER IGD
    // =========================================================

    /**
     * @notice Current IGD NAV in USDT 6 decimals.
     *
     * Initial bootstrap price:
     *
     * 1 IGD = 1 USDT
     */
    function navPerShareUsdt6()
        public
        view
        returns (uint256)
    {

        uint256 supply =
            totalSupply();


        if (supply == 0) {

            return USDT_UNIT;
        }


        uint256 backing =
            totalBackingValueUsdt();


        /*
         * backing:
         * 6 decimals
         *
         * supply:
         * 18 decimals
         *
         * result:
         * 6 decimals
         */
        return
            (
                backing *
                IGD_UNIT
            ) /
            supply;
    }


    // =========================================================
    // MINT QUOTE
    // =========================================================

    /**
     * @notice Approximate IGD shares created from a USDT deposit.
     *
     * This quote assumes execution receives XAUT valued at
     * the current oracle price.
     *
     * Actual minting uses the XAUT actually acquired.
     */
    function quoteMint(
        uint256 usdtAmount
    )
        external
        view
        returns (
            uint256 spread,
            uint256 swapAmount,
            uint256 estimatedIgd
        )
    {

        require(
            usdtAmount > 0,
            "Invalid amount"
        );


        spread =
            (
                usdtAmount *
                buySpreadBps
            ) /
            BPS_DENOMINATOR;


        swapAmount =
            usdtAmount -
            spread;


        uint256 currentNav =
            navPerShareUsdt6();


        /*
         * If current NAV is $1:
         *
         * 4,987.50 USDT
         *
         * -> 4,987.50 IGD
         *
         */
        estimatedIgd =
            (
                swapAmount *
                IGD_UNIT
            ) /
            currentNav;
    }


    // =========================================================
    // MINT
    // =========================================================

    /**
     * @notice Deposit USDT and mint IGD shares.
     *
     * The actual amount minted is based on the XAUT
     * actually acquired by the router.
     */
    function mintWithSpread(
        uint256 usdtAmount,
        uint256 minXautOut,
        bytes calldata aggregatorCallData
    )
        external
        nonReentrant
        whenNotPaused
    {

        require(
            usdtAmount > 0,
            "Amount must be greater than zero"
        );


        require(
            usdtAmount <= maxSwapCapLimit,
            "Swap cap exceeded"
        );


        /*
         * Snapshot existing protocol state BEFORE
         * accepting the new deposit.
         */
        uint256 supplyBefore =
            totalSupply();


        uint256 backingBefore =
            totalBackingValueUsdt();


        uint256 navBefore =
            navPerShareUsdt6();


        /*
         * Get oracle price once for this transaction.
         */
        uint256 goldPrice =
            goldPriceUsdt6();


        /*
         * Receive USDT.
         */
        usdtToken.safeTransferFrom(
            msg.sender,
            address(this),
            usdtAmount
        );


        /*
         * Calculate buy spread.
         */
        uint256 spreadSurplus =
            (
                usdtAmount *
                buySpreadBps
            ) /
            BPS_DENOMINATOR;


        uint256 swapExecutionAmount =
            usdtAmount -
            spreadSurplus;


        require(
            swapExecutionAmount > 0,
            "Swap amount is zero"
        );


        /*
         * Send spread revenue to treasury.
         */
        usdtToken.safeTransfer(
            protocolTreasuryVault,
            spreadSurplus
        );


        /*
         * Measure XAUT before swap.
         */
        uint256 goldBefore =
            xautToken.balanceOf(
                address(this)
            );


        /*
         * Give router ONLY the amount required
         * for this swap.
         */
        usdtToken.forceApprove(
            aggregatorRouter,
            swapExecutionAmount
        );


        /*
         * Execute router calldata.
         */
        (bool success, bytes memory result) =
            aggregatorRouter.call(
                aggregatorCallData
            );


        /*
         * Clear approval immediately.
         */
        usdtToken.forceApprove(
            aggregatorRouter,
            0
        );


        require(
            success,
            "DEX routing failed"
        );


        /*
         * Silence compiler warning while preserving
         * returned router data for debugging compatibility.
         */
        result;


        /*
         * Measure XAUT after swap.
         */
        uint256 goldAfter =
            xautToken.balanceOf(
                address(this)
            );


        require(
            goldAfter > goldBefore,
            "No XAUT acquired"
        );


        uint256 xautAcquired =
            goldAfter -
            goldBefore;


        require(
            xautAcquired >= minXautOut,
            "XAUT slippage exceeded"
        );


        /*
         * Value ONLY the XAUT acquired by this user.
         */
        uint256 contributionValue =
            (
                xautAcquired *
                goldPrice
            ) /
            XAUT_UNIT;


        require(
            contributionValue > 0,
            "Contribution value is zero"
        );


        uint256 igdToMint;


        /*
         * BOOTSTRAP
         *
         * If no IGD exists:
         *
         * contributionValue USDT
         * ->
         * same number of IGD units.
         *
         * Example:
         *
         * $4,987.50 backing
         * ->
         * 4,987.50 IGD
         */
        if (supplyBefore == 0) {

            igdToMint =
                contributionValue *
                IGD_UNIT;

        } else {

            /*
             * Existing holders receive protection from dilution.
             *
             * New shares =
             *
             * contribution / previous NAV
             *
             * in share units.
             */
            igdToMint =
                (
                    contributionValue *
                    IGD_UNIT
                ) /
                navBefore;
        }


        require(
            igdToMint > 0,
            "Mint amount is zero"
        );


        /*
         * Sanity check:
         *
         * Backing should not decrease as a consequence
         * of the mint.
         */
        uint256 backingAfter =
            totalBackingValueUsdt();


        require(
            backingAfter >= backingBefore,
            "Backing accounting error"
        );


        /*
         * Mint actual shares.
         */
        _mint(
            msg.sender,
            igdToMint
        );


        emit Minted(
            msg.sender,
            usdtAmount,
            spreadSurplus,
            xautAcquired,
            igdToMint,
            navPerShareUsdt6()
        );
    }


    // =========================================================
    // REDEEM
    // =========================================================

    /**
     * @notice Burn IGD shares and redeem their proportional
     * XAUT backing through the aggregator.
     *
     * IMPORTANT:
     * Only the XAUT amount attributable to the user's shares
     * is approved to the router.
     */
    function redeemWithSpread(
        uint256 tokenAmount,
        uint256 minUsdtOut,
        bytes calldata aggregatorCallData
    )
        external
        nonReentrant
        whenNotPaused
    {

        require(
            tokenAmount > 0,
            "Amount must be greater than zero"
        );


        require(
            tokenAmount <= maxRedeemTokenLimit,
            "Redemption cap exceeded"
        );


        uint256 userBalance =
            balanceOf(msg.sender);


        require(
            userBalance >= tokenAmount,
            "Insufficient IGD balance"
        );


        uint256 supplyBefore =
            totalSupply();


        require(
            supplyBefore > 0,
            "No IGD supply"
        );


        /*
         * Determine the XAUT backing attributable
         * to this percentage of the supply.
         */
        uint256 xautBalance =
            xautToken.balanceOf(
                address(this)
            );


        uint256 xautToSell =
            (
                xautBalance *
                tokenAmount
            ) /
            supplyBefore;


        require(
            xautToSell > 0,
            "Redeem amount below XAUT precision"
        );


        /*
         * Measure USDT before router execution.
         */
        uint256 usdtBefore =
            usdtToken.balanceOf(
                address(this)
            );


        /*
         * Burn shares BEFORE external call.
         *
         * ReentrancyGuard protects the function.
         */
        _burn(
            msg.sender,
            tokenAmount
        );


        /*
         * Approve ONLY the proportional XAUT amount.
         */
        xautToken.forceApprove(
            aggregatorRouter,
            xautToSell
        );


        /*
         * Execute XAUT -> USDT swap.
         */
        (bool success, bytes memory result) =
            aggregatorRouter.call(
                aggregatorCallData
            );


        /*
         * Immediately clear allowance.
         */
        xautToken.forceApprove(
            aggregatorRouter,
            0
        );


        result;


        require(
            success,
            "DEX redemption failed"
        );


        /*
         * Measure USDT received from this swap.
         */
        uint256 usdtAfter =
            usdtToken.balanceOf(
                address(this)
            );


        require(
            usdtAfter > usdtBefore,
            "No USDT received"
        );


        uint256 totalUsdtReclaimed =
            usdtAfter -
            usdtBefore;


        require(
            totalUsdtReclaimed >= minUsdtOut,
            "USDT slippage exceeded"
        );


        /*
         * Calculate redemption spread.
         */
        uint256 exitSpreadSurplus =
            (
                totalUsdtReclaimed *
                sellSpreadBps
            ) /
            BPS_DENOMINATOR;


        uint256 netUserPayout =
            totalUsdtReclaimed -
            exitSpreadSurplus;


        require(
            netUserPayout > 0,
            "Payout is zero"
        );


        /*
         * Send spread revenue.
         */
        usdtToken.safeTransfer(
            protocolTreasuryVault,
            exitSpreadSurplus
        );


        /*
         * Send redemption proceeds.
         */
        usdtToken.safeTransfer(
            msg.sender,
            netUserPayout
        );


        emit Redeemed(
            msg.sender,
            tokenAmount,
            xautToSell,
            totalUsdtReclaimed,
            exitSpreadSurplus,
            netUserPayout
        );
    }


    // =========================================================
    // ADMINISTRATION
    // =========================================================

    function setSpreads(
        uint256 _buyBps,
        uint256 _sellBps
    )
        external
        onlyOwner
    {

        require(
            _buyBps <= 100,
            "Buy spread exceeds 1%"
        );


        require(
            _sellBps <= 100,
            "Sell spread exceeds 1%"
        );


        buySpreadBps =
            _buyBps;


        sellSpreadBps =
            _sellBps;


        emit SpreadsUpdated(
            _buyBps,
            _sellBps
        );
    }


    function setMaxSwapCapLimit(
        uint256 _newCap
    )
        external
        onlyOwner
    {

        require(
            _newCap > 0,
            "Invalid swap cap"
        );


        maxSwapCapLimit =
            _newCap;


        emit SwapCapUpdated(
            _newCap
        );
    }


    function setMaxRedeemTokenLimit(
        uint256 _newCap
    )
        external
        onlyOwner
    {

        require(
            _newCap > 0,
            "Invalid redemption cap"
        );


        maxRedeemTokenLimit =
            _newCap;


        emit RedeemCapUpdated(
            _newCap
        );
    }


    function setRouter(
        address _newRouter
    )
        external
        onlyOwner
    {

        require(
            _newRouter != address(0),
            "Invalid router"
        );


        address oldRouter =
            aggregatorRouter;


        aggregatorRouter =
            _newRouter;


        emit RouterUpdated(
            oldRouter,
            _newRouter
        );
    }


    function setTreasuryVault(
        address _newVault
    )
        external
        onlyOwner
    {

        require(
            _newVault != address(0),
            "Invalid treasury"
        );


        address oldVault =
            protocolTreasuryVault;


        protocolTreasuryVault =
            _newVault;


        emit TreasuryVaultUpdated(
            oldVault,
            _newVault
        );
    }


    function setGoldOracle(
        address _newOracle
    )
        external
        onlyOwner
    {

        require(
            _newOracle != address(0),
            "Invalid oracle"
        );


        address oldOracle =
            address(goldPriceOracle);


        goldPriceOracle =
            AggregatorV3Interface(
                _newOracle
            );


        emit OracleUpdated(
            oldOracle,
            _newOracle
        );
    }


    function setOracleMaxAge(
        uint256 _newAge
    )
        external
        onlyOwner
    {

        require(
            _newAge > 0,
            "Invalid oracle age"
        );


        uint256 oldAge =
            oracleMaxAge;


        oracleMaxAge =
            _newAge;


        emit OracleMaxAgeUpdated(
            oldAge,
            _newAge
        );
    }


    // =========================================================
    // EMERGENCY CONTROLS
    // =========================================================

    function pause()
        external
        onlyOwner
    {
        _pause();
    }


    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }


    // =========================================================
    // RESCUE NON-PROTOCOL TOKENS
    // =========================================================

    /**
     * @notice Allows recovery of accidental ERC20 transfers.
     *
     * USDT and XAUT cannot be rescued because they constitute
     * protocol backing/assets.
     */
    function rescueToken(
        address token,
        address recipient,
        uint256 amount
    )
        external
        onlyOwner
    {

        require(
            token != address(usdtToken),
            "Cannot rescue USDT"
        );


        require(
            token != address(xautToken),
            "Cannot rescue XAUT"
        );


        require(
            recipient != address(0),
            "Invalid recipient"
        );


        IERC20(token).safeTransfer(
            recipient,
            amount
        );
    }


    // =========================================================
    // VIEW HELPERS
    // =========================================================

    function xautBalance()
        external
        view
        returns (uint256)
    {
        return
            xautToken.balanceOf(
                address(this)
            );
    }


    function usdtBalance()
        external
        view
        returns (uint256)
    {
        return
            usdtToken.balanceOf(
                address(this)
            );
    }
}
