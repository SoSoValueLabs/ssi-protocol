// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockPermitToken is ERC20, ERC20Permit {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _decimals = decimals_;
    }

    function mint(address account, uint256 value) external {
        _mint(account, value);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function nonces(address owner) public view override returns (uint256) {
        return super.nonces(owner);
    }
}
