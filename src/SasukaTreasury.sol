// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SasukaTreasury is Ownable {
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    event FeeReceived(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {
        emit FeeReceived(msg.sender, msg.value);
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        if (amount > address(this).balance) {
            revert InsufficientBalance(amount, address(this).balance);
        }

        (bool success,) = to.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Withdrawn(to, amount);
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
