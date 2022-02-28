// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ERC20 }       from "../lib/erc20/src/ERC20.sol";
import { ERC20Helper } from "../lib/erc20-helper/src/ERC20Helper.sol";

import { IRevenueDistributionToken } from "./interfaces/IRevenueDistributionToken.sol";

contract RevenueDistributionToken is IRevenueDistributionToken, ERC20 {

    uint256 public immutable override precision;  // Precision of rates, equals max deposit amounts before rounding errors occur

    address public override owner;
    address public override pendingOwner;
    address public override asset;

    uint256 public override freeAssets;           // Amount of assets unlocked regardless of time passed.
    uint256 public override issuanceRate;         // asset/second rate dependent on aggregate vesting schedule (needs increased precision).
    uint256 public override lastUpdated;          // Timestamp of when issuance equation was last updated.
    uint256 public override vestingPeriodFinish;  // Timestamp when current vesting schedule ends.

    constructor(string memory name_, string memory symbol_, address owner_, address asset_, uint256 precision_)
        ERC20(name_, symbol_, ERC20(asset_).decimals())
    {
        owner      = owner_;
        precision  = precision_;
        asset = asset_;
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function acceptOwnership() external override {
        require(msg.sender == pendingOwner, "RDT:AO:NOT_PO");
        owner        = msg.sender;
        pendingOwner = address(0);
    }

    function setPendingOwner(address pendingOwner_) external override {
        require(msg.sender == owner, "RDT:SPO:NOT_OWNER");
        pendingOwner = pendingOwner_;
    }

    // TODO: Revisit returns
    function updateVestingSchedule(uint256 vestingPeriod_) external override returns (uint256 issuanceRate_, uint256 freeAssets_) {
        require(msg.sender == owner, "RDT:UVS:NOT_OWNER");

        // Update "y-intercept" to reflect current available asset
        freeAssets = freeAssets_ = totalHoldings();

        // Calculate slope, update timestamp and period finish
        issuanceRate        = issuanceRate_ = (ERC20(asset).balanceOf(address(this)) - freeAssets_) * precision / vestingPeriod_;
        lastUpdated         = block.timestamp;
        vestingPeriodFinish = block.timestamp + vestingPeriod_;
    }

    /************************/
    /*** Staker Functions ***/
    /************************/

    function deposit(uint256 assets_, address receiver_) external override returns (uint256 shares_) {
        shares_ = _deposit(assets_, msg.sender, msg.sender);
    }

    function redeem(uint256 rdTokenAmount_) external virtual override returns (uint256 assetAmount_) {
        return _redeem(msg.sender, rdTokenAmount_);
    }

    function withdraw(uint256 assetAmount_) external virtual override returns (uint256 shares_) {
        return _withdraw(msg.sender, assetAmount_);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _deposit(uint256 assets_, address receiver_, address caller_) internal returns (uint256 shares_) {
        require(assets_ != 0, "RDT:D:AMOUNT");
        _mint(receiver_, shares_ = previewDeposit(assets_));
        freeAssets = totalHoldings() + assets_;
        _updateIssuanceParams();
        require(ERC20Helper.transferFrom(address(asset), caller_, address(this), assets_), "RDT:D:TRANSFER_FROM");
        emit Deposit(caller_, receiver_, assets_, shares_);
    }

    function _redeem(address account_, uint256 rdTokenAmount_) internal returns (uint256 assetAmount_) {
        require(rdTokenAmount_ != 0, "RDT:W:AMOUNT");
        assetAmount_ = previewRedeem(rdTokenAmount_);
        _burn(account_, rdTokenAmount_);
        freeAssets = totalHoldings() - assetAmount_;
        _updateIssuanceParams();
        require(ERC20Helper.transfer(address(asset), account_, assetAmount_), "RDT:D:TRANSFER");
        emit Withdraw(account_, assetAmount_);
    }

    function _withdraw(address account_, uint256 assetAmount_) internal returns (uint256 shares_) {
        require(assetAmount_ != 0, "RDT:W:AMOUNT");
        _burn(account_, shares_ = previewWithdraw(assetAmount_));
        freeAssets = totalHoldings() - assetAmount_;
        _updateIssuanceParams();
        require(ERC20Helper.transfer(address(asset), account_, assetAmount_), "RDT:D:TRANSFER");
        emit Withdraw(account_, assetAmount_);
    }

    function _updateIssuanceParams() internal {
        issuanceRate = block.timestamp > vestingPeriodFinish ? 0 : issuanceRate;
        lastUpdated  = block.timestamp;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function APR() external view override returns (uint256 apr_) {
        return issuanceRate * 365 days * ERC20(asset).decimals() / totalSupply / precision;
    }

    function balanceOfAssets(address account_) external view override returns (uint256 balanceOfAssets_) {
        return balanceOf[account_] * exchangeRate() / precision;
    }

    function exchangeRate() public view override returns (uint256 exchangeRate_) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == uint256(0)) return precision;
        return totalHoldings() * precision / _totalSupply;
    }

    function previewDeposit(uint256 assetAmount_) public view override returns (uint256 shareAmount_) {
        shareAmount_ = assetAmount_ * precision / exchangeRate();
    }

    // TODO: Update this function and corresponding test to divide by exchange rate
    function previewWithdraw(uint256 assetAmount_) public view override returns (uint256 shareAmount_) {
        shareAmount_ = assetAmount_ * precision / exchangeRate();
    }

    function previewRedeem(uint256 shareAmount_) public view override returns (uint256 assetAmount_) {
        assetAmount_ = shareAmount_ * exchangeRate() / precision;
    }

    function totalHoldings() public view override returns (uint256 totalHoldings_) {
        if (issuanceRate == 0) return freeAssets;

        uint256 vestingTimePassed =
            block.timestamp > vestingPeriodFinish ?
                vestingPeriodFinish - lastUpdated :
                block.timestamp - lastUpdated;

        return issuanceRate * vestingTimePassed / precision + freeAssets;
    }

}
