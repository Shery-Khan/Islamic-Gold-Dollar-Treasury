// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GoldSpreadTreasury
 * @notice An algorithmic spread engine ensuring the protocol always captures a profit buffer 
 * during both mint and burn operations. Front-end transactions display as 0% flat fees.
 * Implements strict OpenZeppelin standards for public decentralized security.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract GoldSpreadTreasury is ERC20, Ownable, ReentrancyGuard {

    IERC20 public immutable usdtToken;
    IERC20 public immutable xautToken;
    
    address public aggregatorRouter;
    address public protocolTreasuryVault;

    // Spread configurations: 25 basis points = 0.25% algorithmic spread buffer
    uint256 public buySpreadBps = 25;  
    uint256 public sellSpreadBps = 25; 
    uint256 public constant DENOMINATOR = 10000;

    constructor(
        address _usdt, 
        address _xaut, 
        address _router, 
        address _treasury
    ) 
        ERC20("Islamic Gold Dollar", "IGD") 
        Ownable(msg.sender) 
    {
        require(_usdt != address(0) && _xaut != address(0) && _router != address(0) && _treasury != address(0), "Invalid address");
        usdtToken = IERC20(_usdt);
        xautToken = IERC20(_xaut);
        aggregatorRouter = _router;
        protocolTreasuryVault = _treasury;
    }

    /**
     * @notice Algorithmic Spread Minting (User buys the token).
     */
    function mintWithSpread(uint256 usdtAmount, bytes calldata aggregatorCallData) external nonReentrant {
        require(usdtAmount > 0, "Amount must be greater than 0");
        
        require(usdtToken.transferFrom(msg.sender, address(this), usdtAmount), "USDT inbound transfer failed");

        uint256 spreadSurplus = (usdtAmount * buySpreadBps) / DENOMINATOR;
        uint256 swapExecutionAmount = usdtAmount - spreadSurplus;

        require(usdtToken.transfer(protocolTreasuryVault, spreadSurplus), "Treasury safety buffer allocation failed");

        usdtToken.approve(aggregatorRouter, swapExecutionAmount);
        uint256 goldBefore = xautToken.balanceOf(address(this));
        
        (bool success, ) = aggregatorRouter.call(aggregatorCallData);
        require(success, "DEX routing failed: Slippage perimeter breached");

        uint256 goldAfter = xautToken.balanceOf(address(this));
        require(goldAfter - goldBefore > 0, "Security Revert: Insufficient gold collateral acquired");

        _mint(msg.sender, usdtAmount);
    }

    /**
     * @notice Algorithmic Spread Redemption (User sells the token).
     */
    function redeemWithSpread(uint256 tokenAmount, bytes calldata aggregatorCallData) external nonReentrant {
        require(tokenAmount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient ledger balance");

        uint256 usdtBalanceBefore = usdtToken.balanceOf(address(this));

        _burn(msg.sender, tokenAmount);

        xautToken.approve(aggregatorRouter, xautToken.balanceOf(address(this)));
        (bool success, ) = aggregatorRouter.call(aggregatorCallData);
        require(success, "DEX routing failed: Insufficient exit liquidity");

        uint256 usdtBalanceAfter = usdtToken.balanceOf(address(this));
        uint256 totalUsdtReclaimed = usdtBalanceAfter - usdtBalanceBefore;

        uint256 exitSpreadSurplus = (totalUsdtReclaimed * sellSpreadBps) / DENOMINATOR;
        uint256 netUserPayout = totalUsdtReclaimed - exitSpreadSurplus;

        require(usdtToken.transfer(protocolTreasuryVault, exitSpreadSurplus), "Treasury exit allocation failed");

        require(usdtToken.transfer(msg.sender, netUserPayout), "Public treasury payout failed");
    }

    function setSpreads(uint256 _buyBps, uint256 _sellBps) external onlyOwner {
        require(_buyBps <= 100 && _sellBps <= 100, "Spread cannot exceed 1% perimeter");
        buySpreadBps = _buyBps;
        sellSpreadBps = _sellBps;
    }
}
