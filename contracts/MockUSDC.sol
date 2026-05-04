// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;

    constructor(uint256 initialSupply) ERC20("USD Coin", "USDC") Ownable(msg.sender) {
        _mint(msg.sender, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
