// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AllowList} from "../src/AllowList.sol";
import {SecurityToken} from "../src/SecurityToken.sol";
import {TestBase, Vm} from "./TestBase.sol";

contract SecurityTokenPolicyTest is TestBase {
    bytes32 internal constant TRANSFER_TOPIC =
        keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant RECOVERY_TOPIC =
        keccak256("RecoveryExecuted(bytes32,address,address,uint256)");

    bytes32 internal constant CASE_1 = keccak256("case-1");
    bytes32 internal constant CASE_2 = keccak256("case-2");

    SecurityToken internal token;
    AllowList internal allowlist;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant SPENDER = address(0x5BE4D);
    address internal constant MALLORY = address(0xBAD);
    address internal constant ZERO = address(0);
    address internal constant agentOnly = address(0xA6E47);

    function setUp() public {
        allowlist = new AllowList(address(this));
        token = new SecurityToken(address(allowlist));
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.grantRole(token.AGENT_ROLE(), address(this));
        token.grantRole(token.AGENT_ROLE(), agentOnly);
        allowlist.allow(ALICE);
        allowlist.allow(BOB);
        allowlist.allow(CAROL);
    }

    // helpers
    function _call(
        address caller,
        bytes memory data
    ) internal returns (bool ok) {
        vm.prank(caller);
        (ok, ) = address(token).call(data);
    }

    function _mustSucceed(address caller, bytes memory data) internal {
        require(_call(caller, data), "call unexpectedly reverted");
    }

    function _mustRevert(address caller, bytes memory data) internal {
        require(!_call(caller, data), "call unexpectedly succeeded");
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        return _call(from, abi.encodeCall(token.transfer, (to, amount)));
    }

    function _transferFrom(
        address spender,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        return
            _call(
                spender,
                abi.encodeCall(token.transferFrom, (from, to, amount))
            );
    }

    function _recover(
        address caller,
        bytes32 caseId,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        return
            _call(
                caller,
                abi.encodeCall(token.recover, (caseId, from, to, amount))
            );
    }

    function _mint(
        address caller,
        address to,
        uint256 amount
    ) internal returns (bool) {
        return _call(caller, abi.encodeCall(token.mint, (to, amount)));
    }

    function _burn(
        address caller,
        address from,
        uint256 amount
    ) internal returns (bool) {
        return _call(caller, abi.encodeCall(token.burn, (from, amount)));
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        _mustSucceed(owner, abi.encodeCall(token.approve, (spender, amount)));
    }

    // TOK-01 current eligibility
    function test_TOK01_revokedSenderCannotTransferOrBeMovedByTransferFrom()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        allowlist.disallow(ALICE);

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 10));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_TOK01_revokedRecipientRejectedOnTransferAndTransferFrom()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        allowlist.disallow(BOB);

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_TOK01_neverListedRecipientRejectedOnTransferFrom() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);

        assertFalse(_transferFrom(SPENDER, ALICE, MALLORY, 1));
        assertEq(token.balanceOf(MALLORY), 0);
    }

    function test_TOK01_revocationAndReinstatementTakeEffectImmediately()
        public
    {
        token.mint(ALICE, 100);
        assertTrue(_transfer(ALICE, BOB, 1));

        allowlist.disallow(BOB);
        assertFalse(_transfer(ALICE, BOB, 1));

        allowlist.allow(BOB);
        assertTrue(_transfer(ALICE, BOB, 1));
        assertEq(token.balanceOf(BOB), 2);
    }

    function test_TOK01_issuanceToIneligibleWalletRejected() public {
        assertFalse(_mint(address(this), MALLORY, 1));
        assertEq(token.totalSupply(), 0);
    }

    function test_TOK01_redemptionFromIneligibleWalletRejected() public {
        token.mint(ALICE, 100);
        allowlist.disallow(ALICE);

        assertFalse(_burn(address(this), ALICE, 10));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
    }

    // TOK-02 operational holds
    function test_TOK02_heldSenderCannotTransferOrBeMovedByTransferFrom()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        token.freeze(ALICE);

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_TOK02_heldRecipientRejectedOnTransferAndTransferFrom()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        token.freeze(BOB);

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_TOK02_issuanceToHeldWalletRejected() public {
        token.freeze(ALICE);

        assertFalse(_mint(address(this), ALICE, 5));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_TOK02_redemptionFromHeldWalletRejected() public {
        token.mint(ALICE, 100);
        token.freeze(ALICE);

        assertFalse(_burn(address(this), ALICE, 5));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK02_holdAndAllowlistAreIndependentControls() public {
        token.mint(ALICE, 100);

        // Held but still allowlisted: blocked.
        token.freeze(BOB);
        assertTrue(allowlist.isAllowed(BOB));
        assertFalse(_transfer(ALICE, BOB, 1));

        // Releasing the hold does not touch eligibility, and vice versa.
        token.unfreeze(BOB);
        allowlist.disallow(BOB);
        assertFalse(token.frozen(BOB));
        assertFalse(_transfer(ALICE, BOB, 1));

        // Re-listing alone does not re-freeze anything.
        allowlist.allow(BOB);
        assertTrue(_transfer(ALICE, BOB, 1));
    }

    // TOK-03 register halt
    function test_TOK03_pausedBlocksTransferTransferFromAndIssuance() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        token.pause();

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertFalse(_mint(address(this), BOB, 1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK03_redemptionRemainsAvailableWhilePaused() public {
        token.mint(ALICE, 100);
        token.pause();

        token.burn(ALICE, 40);

        assertEq(token.balanceOf(ALICE), 60);
        assertEq(token.totalSupply(), 60);
    }

    function test_TOK03_recoveryRemainsAvailableWhilePaused() public {
        token.mint(ALICE, 100);
        token.pause();

        assertTrue(_recover(address(this), CASE_1, ALICE, BOB, 70));

        assertEq(token.balanceOf(ALICE), 30);
        assertEq(token.balanceOf(BOB), 70);
        assertTrue(token.recoveryUsed(CASE_1));
    }

    function test_TOK03_unpauseDoesNotRestoreHeldOrIneligibleWallets() public {
        token.mint(ALICE, 100);
        token.freeze(BOB);
        allowlist.disallow(CAROL);
        token.pause();
        token.unpause();

        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transfer(ALICE, CAROL, 1));
        assertFalse(_mint(address(this), BOB, 1));
    }

    function test_TOK03_unpauseRestoresOperationsForCleanWallets() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        token.pause();
        token.unpause();

        assertFalse(token.paused());
        assertTrue(_transfer(ALICE, BOB, 10));
        assertTrue(_transferFrom(SPENDER, ALICE, BOB, 10));
        assertTrue(_mint(address(this),CAROL, 5));
        assertEq(token.balanceOf(ALICE), 80);
        assertEq(token.balanceOf(BOB), 20);
        assertEq(token.balanceOf(CAROL), 5);
        assertEq(token.totalSupply(), 105);
    }

    function test_TOK03_recoveryWhilePausedStillAppliesDestinationPolicy() public {
        token.mint(ALICE, 100);
        token.freeze(BOB);
        token.pause();

        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 10)); // held destination
        assertFalse(_recover(address(this), CASE_1, ALICE, MALLORY, 10)); // ineligible destination
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(MALLORY), 0);
    }

    function test_TOK03_redemptionWhilePausedStillAppliesWalletPolicy() public {
        token.mint(ALICE, 100);
        token.pause();

        token.freeze(ALICE);
        assertFalse(_burn(address(this),ALICE, 10)); // held source
        token.unfreeze(ALICE);

        allowlist.disallow(ALICE);
        assertFalse(_burn(address(this), ALICE, 10)); // ineligible source

        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
    }

    // TOK-04 case-tracked recovery
    function test_TOK04_recoveryMovesPositionAndEmitsEventsAndUsedCaseCannotBeReused()
        public
    {
        token.mint(ALICE, 100);
        assertFalse(token.recoveryUsed(CASE_1));

        vm.recordLogs();
        assertTrue(_recover(address(this), CASE_1, ALICE, BOB, 60));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 40);
        assertEq(token.balanceOf(BOB), 60);
        assertEq(token.totalSupply(), 100);
        assertTrue(token.recoveryUsed(CASE_1));

        assertEq(_countLogs(logs, TRANSFER_TOPIC), 1);
        assertEq(_countLogs(logs, RECOVERY_TOPIC), 1);

        Vm.Log memory transferLog = _firstLog(logs, TRANSFER_TOPIC);
        assertEqAddr(address(uint160(uint256(transferLog.topics[1]))), ALICE);
        assertEqAddr(address(uint160(uint256(transferLog.topics[2]))), BOB);
        assertEq(abi.decode(transferLog.data, (uint256)), 60);

        Vm.Log memory recoveryLog = _firstLog(logs, RECOVERY_TOPIC);
        assertEq32(recoveryLog.topics[1], CASE_1);
        assertEqAddr(address(uint160(uint256(recoveryLog.topics[2]))), ALICE);
        assertEqAddr(address(uint160(uint256(recoveryLog.topics[3]))), BOB);
        assertEq(abi.decode(recoveryLog.data, (uint256)), 60);

        //used case cannot be reused
        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 10));
        // A different case id is independent.
        assertTrue(_recover(address(this), CASE_2, ALICE, BOB, 10));
        assertEq(token.balanceOf(BOB), 70);
    }

    function test_TOK04_onlyAgentMayRecover() public {
        token.mint(ALICE, 100);
        token.grantRole(token.MINTER_ROLE(), MALLORY); // a different role is not enough

        assertFalse(_recover(MALLORY, CASE_1, ALICE, BOB, 10));
        assertFalse(_recover(ALICE, CASE_1, ALICE, BOB, 10));
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(ALICE), 100);
    }

    function test_TOK04_zeroCaseIdAndAmountRejected() public {
        token.mint(ALICE, 100);

        //zero caseId rejects
        assertFalse(_recover(address(this), bytes32(0), ALICE, BOB, 10));
        assertFalse(token.recoveryUsed(bytes32(0)));
        assertEq(token.balanceOf(ALICE), 100);
        //zero amount rejects
        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 0));
        assertFalse(token.recoveryUsed(CASE_1));
    }

    function test_TOK04_zeroAddressAndSelfRecoveryRejected() public {
        token.mint(ALICE, 100);

        assertFalse(_recover(address(this), CASE_1, ZERO, BOB, 1));
        assertFalse(_recover(address(this), CASE_1, ALICE, ZERO, 1));
        assertFalse(_recover(address(this), CASE_1, ALICE, ALICE, 1));
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK04_heldAndIneligibleSourceMayBeRecovered() public {
        token.mint(ALICE, 100);
        token.freeze(ALICE);
        //Held source Recovered
        assertTrue(_recover(address(this), CASE_1, ALICE, BOB, 50));
        token.unfreeze(ALICE);
        //Ineligible source Recovered
        allowlist.disallow(ALICE);
        assertTrue(_recover(address(this), CASE_2, ALICE, BOB, 50));
        assertTrue(token.recoveryUsed(CASE_1));
        assertTrue(token.recoveryUsed(CASE_2));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.totalSupply(),100);
    }

    function test_TOK04_heldAndIneligibleDestinationRejected() public {
        token.mint(ALICE, 100);
        //held destination rejected
        token.freeze(BOB);
        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 10));
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(BOB), 0);
        
        //Ineligible destination Rejected
        assertFalse(_recover(address(this), CASE_1, ALICE, MALLORY, 10));
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(MALLORY), 0);

        assertEq(token.balanceOf(ALICE), 100);
    }

    function test_TOK04_insufficientBalanceRejectedAndCaseNotConsumed() public {
        token.mint(ALICE, 100);

        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 101));
        assertFalse(token.recoveryUsed(CASE_1));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);

        // The same case id is still usable after the failed attempt.
        assertTrue(_recover(address(this), CASE_1, ALICE, BOB, 100));
        assertTrue(token.recoveryUsed(CASE_1));
    }

    function test_TOK04_failedRecoveryEmitsNoEvents() public {
        token.mint(ALICE, 100);
        token.freeze(BOB);

        vm.recordLogs();
        assertFalse(_recover(address(this), CASE_1, ALICE, BOB, 10));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countLogs(logs, TRANSFER_TOPIC), 0);
        assertEq(_countLogs(logs, RECOVERY_TOPIC), 0);
    }

    function test_TOK04_recoveryDoesNotTouchAllowances() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 25);

        assertTrue(_recover(address(this), CASE_1, ALICE, BOB, 10));

        assertEq(token.allowance(ALICE, SPENDER), 25);
    }


    // TOK-05 supply and zero-address safety
    // The zero address is deliberately made "eligible" in the allowlist for these tests, so they
    // prove the token itself rejects it instead of relying on the registry to refuse it.

    function test_TOK05_transferAndTransferFromToZeroAddressCannotBurnSupply() public {
        allowlist.allow(ZERO);
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);

        assertFalse(_transfer(ALICE, ZERO, 10));
        assertFalse(_transferFrom(SPENDER, ALICE, ZERO, 10));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
        assertEq(token.allowance(ALICE, SPENDER), 50);
    }

    function test_TOK05_transferFromZeroAddressCannotMintSupply() public {
        allowlist.allow(ZERO);

        // A zero-value transfer from the zero address would otherwise look like issuance.
        vm.recordLogs();
        assertFalse(_transferFrom(SPENDER, ZERO, ALICE, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_TOK05_zeroAmountTransferToZeroAddressRejected() public {
        allowlist.allow(ZERO);
        token.mint(ALICE, 100);

        vm.recordLogs();
        assertFalse(_transfer(ALICE, ZERO, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK05_recoveryRejectsZeroAddressEvenIfAllowlistAcceptsIt()
        public
    {
        allowlist.allow(ZERO);
        token.mint(ALICE, 100);

        assertFalse(_recover(address(this), CASE_1, ALICE, ZERO, 10));
        assertFalse(_recover(address(this), CASE_2, ZERO, ALICE, 10));
        assertFalse(token.recoveryUsed(CASE_1));
        assertFalse(token.recoveryUsed(CASE_2));
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK05_onlyMinterCanIncreaseSupply() public {
        token.grantRole(token.AGENT_ROLE(), MALLORY);

        assertFalse(_mint(MALLORY,ALICE, 1)); // agent, not minter
        assertFalse(_mint(ALICE,ALICE, 1)); // holder
        assertEq(token.totalSupply(), 0);
    }

    function test_TOK05_onlyAgentCanDecreaseSupply() public {
        token.mint(ALICE, 100);
        token.grantRole(token.MINTER_ROLE(), MALLORY);

        assertFalse(_burn(MALLORY, ALICE, 1)); // minter, not agent
        assertFalse(_burn(ALICE,ALICE, 1)); // holder burning own shares
        assertEq(token.totalSupply(), 100);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function test_TOK05_recoveryPreservesTotalSupply() public {
        token.mint(ALICE, 100);
        token.mint(BOB, 50);

        assertTrue(_recover(address(this), CASE_1, ALICE, CAROL, 100));

        assertEq(token.totalSupply(), 150);
    }

    // TOK-06 authority and registry administration
    function test_TOK06_deploymentGrantsOnlyAdminRole() public {
        SecurityToken fresh = new SecurityToken(address(allowlist));

        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.MINTER_ROLE(), address(this)));
        assertFalse(fresh.hasRole(fresh.AGENT_ROLE(), address(this)));

        // Without explicit grants the deployer cannot use minter or agent powers.
        (bool mintOk, ) = address(fresh).call(
            abi.encodeCall(fresh.mint, (ALICE, 1))
        );
        (bool pauseOk, ) = address(fresh).call(abi.encodeCall(fresh.pause, ()));
        assertFalse(mintOk);
        assertFalse(pauseOk);
    }

    function test_TOK06_roleGrantsAndRevocationsAreAdminOnly() public {
        bytes32 minterRole = token.MINTER_ROLE();

        assertFalse(
            _call(
                MALLORY,
                abi.encodeCall(token.grantRole, (minterRole, MALLORY))
            )
        );
        assertFalse(token.hasRole(minterRole, MALLORY));

        token.grantRole(minterRole, ALICE);
        assertFalse(
            _call(
                MALLORY,
                abi.encodeCall(token.revokeRole, (minterRole, ALICE))
            )
        );
        assertTrue(token.hasRole(minterRole, ALICE));

        token.revokeRole(minterRole, ALICE);
        assertFalse(token.hasRole(minterRole, ALICE));
    }

    function test_TOK06_constructorRejectsZeroAllowlist() public {
        vm.expectRevert();
        new SecurityToken(ZERO);
    }

    function test_TOK06_setAllowlistRejectsZeroAndNonAdmin() public {
        assertFalse(
            _call(address(this), abi.encodeCall(token.setAllowlist, (ZERO)))
        );
        assertEqAddr(address(token.allowlist()), address(allowlist));

        AllowList other = new AllowList(address(this));
        assertFalse(
            _call(MALLORY, abi.encodeCall(token.setAllowlist, (address(other))))
        );
        assertEqAddr(address(token.allowlist()), address(allowlist));
    }

    function test_TOK06_adminCanReplaceAllowlistAndItTakesEffect() public {
        token.mint(ALICE, 100);
        AllowList other = new AllowList(address(this));
        other.allow(ALICE); // BOB is not on the replacement list

        token.setAllowlist(address(other));

        assertEqAddr(address(token.allowlist()), address(other));
        assertFalse(_transfer(ALICE, BOB, 1));
        other.allow(BOB);
        assertTrue(_transfer(ALICE, BOB, 1));
    }

    function test_TOK06_issuanceIsMinterPowerNotAgentPower() public {
        token.grantRole(token.MINTER_ROLE(), CAROL);

        assertFalse(_mint(agentOnly, ALICE, 1));
        assertTrue(_mint(CAROL,ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
    }

    function test_TOK06_holdsHaltsAndRedemptionAreAgentPowersNotMinterPower() public {
        token.mint(ALICE, 100);
        token.grantRole(token.MINTER_ROLE(), MALLORY); // minter only

        //Minter not access agent power
        assertFalse(_call(MALLORY, abi.encodeCall(token.freeze, (ALICE))));
        assertFalse(_call(MALLORY, abi.encodeCall(token.unfreeze, (ALICE))));
        assertFalse(_call(MALLORY, abi.encodeCall(token.pause, ())));
        assertFalse(_call(MALLORY, abi.encodeCall(token.unpause, ())));
        assertFalse(_burn(MALLORY,ALICE, 1));

        //Agent power
        assertTrue(_call(agentOnly, abi.encodeCall(token.freeze, (BOB))));
        assertTrue(token.frozen(BOB));
        assertTrue(_call(agentOnly, abi.encodeCall(token.unfreeze, (BOB))));
        assertFalse(token.frozen(BOB));
        assertTrue(_call(agentOnly, abi.encodeCall(token.pause, ())));
        assertTrue(token.paused());
        assertTrue(_recover(agentOnly, CASE_1, ALICE, BOB, 20)); // recovery works while paused
        assertTrue(_burn(agentOnly,ALICE, 30)); // redemption works while paused
        assertTrue(_call(agentOnly, abi.encodeCall(token.unpause, ())));
        assertFalse(token.paused());

        
        assertEq(token.balanceOf(ALICE), 50);
        assertEq(token.balanceOf(BOB), 20);
        assertEq(token.totalSupply(), 70);
    }

    // TOK-07 route consistency and atomic failure
    function test_TOK07_rejectedTransferFromDoesNotSpendAllowance() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);

        token.freeze(ALICE);
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 10)); // held source
        token.unfreeze(ALICE);

        allowlist.disallow(BOB);
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 10)); // ineligible destination
        allowlist.allow(BOB);

        token.pause();
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 10)); // halted
        token.unpause();

        assertFalse(_transferFrom(SPENDER, ALICE, ZERO, 10)); // zero destination

        assertEq(token.allowance(ALICE, SPENDER), 50);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_TOK07_allowanceDoesNotBypassParticipantPolicy() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, type(uint256).max);

        allowlist.disallow(ALICE);
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        allowlist.allow(ALICE);

        token.freeze(BOB);
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        token.unfreeze(BOB);

        assertTrue(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertEq(token.balanceOf(BOB), 1);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
    }

    function test_TOK07_transferFromFailureLeavesNoEventsOrStateChange()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 50);
        allowlist.disallow(ALICE);

        vm.recordLogs();
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 10));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
        assertEq(token.totalSupply(), 100);
        assertEq(token.allowance(ALICE, SPENDER), 50);
    }

    function test_TOK07_insufficientAllowanceAndBalanceLeaveStateUnchanged()
        public
    {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 5);

        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 6)); // allowance too small
        assertFalse(_transfer(ALICE, BOB, 101)); // balance too small
        assertEq(token.allowance(ALICE, SPENDER), 5);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 100);
    }

    function test_TOK07_everyRouteAppliesTheSameParticipantPolicy() public {
        token.mint(ALICE, 100);
        _approve(ALICE, SPENDER, 100);
        token.freeze(ALICE);

        // Held source: transfer and transferFrom reject, redemption rejects.
        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertFalse(_burn(address(this),ALICE, 1));
        token.unfreeze(ALICE);

        // Ineligible source: same result on all three routes.
        allowlist.disallow(ALICE);
        assertFalse(_transfer(ALICE, BOB, 1));
        assertFalse(_transferFrom(SPENDER, ALICE, BOB, 1));
        assertFalse(_burn(address(this),ALICE, 1));
        allowlist.allow(ALICE);

        // Once the wallet is clean, every route works again.
        assertTrue(_transfer(ALICE, BOB, 1));
        assertTrue(_transferFrom(SPENDER, ALICE, BOB, 1));
        token.burn(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 97);
    }
}
