// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "./AccessControl.sol";
import {ERC20Base} from "./ERC20Base.sol";
import {IAllowList} from "./IAllowList.sol";

/// @title SecurityToken
/// @notice Inherited implementation of permissioned fund shares.
contract SecurityToken is ERC20Base, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    IAllowList public allowlist;
    mapping(address account => bool) public frozen;
    bool public paused;

    //True once a recovery case has been successfully executed.
    mapping(bytes32 => bool) public recoveryUsed;

    event RecoveryExecuted(
        bytes32 indexed caseId,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    constructor(address allowlist_) ERC20Base("Fund Share", "FUND") {
        require(allowlist_ != address(0), "zero allowlist");
        allowlist = IAllowList(allowlist_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "token paused");
        _requireParticipant(msg.sender);
        _requireParticipant(to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!paused, "token paused");
        _requireParticipant(from);
        _requireParticipant(to);
        return super.transferFrom(from, to, amount);
    }

    /**
     Recovery only can access by an address with Agent role  .
     And it will recover the fund from frozen or In-eligible wallet to unfrozen or eligible wallet.
     It's work's whether the pause is enable or disabled
    */
    function recover(bytes32 caseId, address from, address to, uint256 amount)
        external
        onlyRole(AGENT_ROLE)
    {
        require(caseId != bytes32(0), "zero case");
        require(!recoveryUsed[caseId], "case used");
        require(amount > 0, "zero amount");
        require(from != address(0) && to != address(0), "zero address");
        require(from != to, "same wallet");
        _requireParticipant(to);

        recoveryUsed[caseId] = true;
        _update(from, to, amount);
        emit RecoveryExecuted(caseId, from, to, amount);
    }

    // setAllowlist only can access by an address with Admin role .
    function setAllowlist(address nextAllowlist) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(nextAllowlist != address(0), "zero allowlist");
        allowlist = IAllowList(nextAllowlist);
    }

    // mint only can access by an address with Minter role .
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(!paused, "token paused");
        _requireParticipant(to);
        _mint(to, amount);
    }

    // burn only can access by an address with Agent role .
    function burn(address from, uint256 amount) external onlyRole(AGENT_ROLE) {
        _requireParticipant(from);
        _burn(from, amount);
    }

    // freeze only can access by an address with Agent role .
    function freeze(address account) external onlyRole(AGENT_ROLE) {
        frozen[account] = true;
    }

    // unfreeze only can access by an address with Agent role .
    function unfreeze(address account) external onlyRole(AGENT_ROLE) {
        frozen[account] = false;
    }

    // pause only can access by an address with Agent role .
    function pause() external onlyRole(AGENT_ROLE) {
        paused = true;
    }

    // unpause only can access by an address with Agent role .
    function unpause() external onlyRole(AGENT_ROLE) {
        paused = false;
    }

    //validate the account
    function _requireParticipant(address account) internal view {
        require(account != address(0), "zero address");
        require(allowlist.isAllowed(account), "wallet not eligible");
        require(!frozen[account], "wallet held");
    }
}

