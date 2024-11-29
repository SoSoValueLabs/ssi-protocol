// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ReentrancyGuardTransientUpgradeable} from "../utils/ReentrancyGuardTransientUpgradeable.sol";
import {ReentrancyAttackUpgradeable} from "./ReentrancyAttackUpgradeable.sol";
import {Initializable} from "../proxy/utils/Initializable.sol";

contract ReentrancyTransientMockUpgradeable is Initializable, ReentrancyGuardTransientUpgradeable {
    uint256 public counter;

    function __ReentrancyTransientMock_init() internal onlyInitializing {
        __ReentrancyTransientMock_init_unchained();
    }

    function __ReentrancyTransientMock_init_unchained() internal onlyInitializing {
        counter = 0;
    }

    function callback() external nonReentrant {
        _count();
    }

    function countLocalRecursive(uint256 n) public nonReentrant {
        if (n > 0) {
            _count();
            countLocalRecursive(n - 1);
        }
    }

    function countThisRecursive(uint256 n) public nonReentrant {
        if (n > 0) {
            _count();
            (bool success, ) = address(this).call(abi.encodeCall(this.countThisRecursive, (n - 1)));
            require(success, "ReentrancyTransientMock: failed call");
        }
    }

    function countAndCall(ReentrancyAttackUpgradeable attacker) public nonReentrant {
        _count();
        attacker.callSender(abi.encodeCall(this.callback, ()));
    }

    function _count() private {
        counter += 1;
    }

    function guardedCheckEntered() public nonReentrant {
        require(_reentrancyGuardEntered());
    }

    function unguardedCheckNotEntered() public view {
        require(!_reentrancyGuardEntered());
    }
}
