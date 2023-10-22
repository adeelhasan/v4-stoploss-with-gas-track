// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract HookGasAccounting {
    uint256 immutable UNIT_PRICE; // in wei
    struct GasTrack {
        uint256 amount;
        uint256 numberOfUnitsOutstanding;
    }
    mapping(address user => GasTrack) public gasBalances;

    constructor(uint256 _unitPrice) {
        UNIT_PRICE = _unitPrice;
    }

    function depositGasBalance() external payable {
        gasBalances[msg.sender].amount += msg.value;
    }

    function withdrawGasBalance(uint256 amount) external {
        uint256 currentBalance = gasBalances[msg.sender].amount;
        require(currentBalance > amount, "not enough balance");
        uint256 minimumBalanceToBeLeft = gasBalances[msg.sender].numberOfUnitsOutstanding * UNIT_PRICE;
        require((currentBalance - amount) < minimumBalanceToBeLeft, "minimum balance with outstanding units not met");
        gasBalances[msg.sender].amount -= amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success);
    }

    function getGasBalancesAmount(address user) external view returns (uint256) {
        return gasBalances[user].amount;
    }

    function getGasPrice() public view returns (uint256) {
        uint256 gasPrice;
        assembly {
            gasPrice := gasprice()
        }
        return gasPrice;
    }

}

