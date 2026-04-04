// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PredictEarn.sol";
import "../src/MockCUSD.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//  Base test setup — shared by all test contracts
// ═══════════════════════════════════════════════════════════════════════════════
contract PredictEarnBase is Test {
    // ── Re-declare events for vm.expectEmit ───────────────────────────────────
    event MatchCreated(uint256 indexed matchIndex);
    event MatchClosed(uint256 indexed matchIndex);
    event MatchResolved(uint256 indexed matchIndex, PredictEarn.Outcome result);
    event MatchCancelled(uint256 indexed matchIndex);
    event BetPlaced(
        uint256 indexed betIndex,
        uint256 indexed matchIndex,
        address indexed bettor,
        PredictEarn.Outcome selection,
        uint256 stake,
        uint256 collateral,
        uint256 leverage,
        uint256 maxPayout
    );
    event WinningsClaimed(uint256 indexed betIndex, address indexed bettor, uint256 payout);
    event RefundClaimed(uint256 indexed betIndex, address indexed bettor, uint256 amount);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event WaitlistRegistered(address indexed wallet, uint256 nonce, uint256 position);
    event WaitlistApproved(address indexed wallet, address indexed approvedBy);
    event WaitlistRevoked(address indexed wallet, address indexed revokedBy);
    event WaitlistGatingChanged(bool enabled);

    // ── Constants ──────────────────────────────────────────────────────────────
    address internal constant CUSD_ADDR = 0x765DE816845861e75A25fCA122bb6898B8B1282a;

    uint256 internal constant ODD_HOME = 20000; // 2.0x
    uint256 internal constant ODD_DRAW = 30000; // 3.0x
    uint256 internal constant ODD_AWAY = 40000; // 4.0x

    uint256 internal constant MIN_STAKE = 0.5 ether;
    uint256 internal constant MAX_STAKE = 500 ether;
    uint256 internal constant FEE_BP    = 250;   // 2.5%

    // ── Named accounts ─────────────────────────────────────────────────────────
    address internal admin;
    uint256 internal adminKey;

    address internal alice;
    uint256 internal aliceKey;

    address internal bob;
    uint256 internal bobKey;

    address internal feeRecipient;

    // ── Contracts ──────────────────────────────────────────────────────────────
    PredictEarn internal pe;
    MockCUSD    internal cusd;

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public virtual {
        // deterministic keys / addresses
        (admin, adminKey)   = makeAddrAndKey("admin");
        (alice, aliceKey)   = makeAddrAndKey("alice");
        (bob,   bobKey)     = makeAddrAndKey("bob");
        feeRecipient        = makeAddr("feeRecipient");

        // deploy mock cUSD at the hardcoded address
        MockCUSD m = new MockCUSD();
        vm.etch(CUSD_ADDR, address(m).code);
        cusd = MockCUSD(CUSD_ADDR);

        // deploy PredictEarn as admin
        vm.prank(admin);
        pe = new PredictEarn(feeRecipient);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Fund `user` with `amount` cUSD and approve `pe` to spend it.
    function _fundAndApprove(address user, uint256 amount) internal {
        cusd.mint(user, amount);
        vm.prank(user);
        cusd.approve(address(pe), amount);
    }

    /// @dev Create a standard open match (commence time = 2 hours from now).
    function _createMatch() internal returns (uint256 idx) {
        PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
            matchId:      "match-001",
            homeTeam:     "Team A",
            awayTeam:     "Team B",
            league:       "Test League",
            commenceTime: block.timestamp + 2 hours,
            homeOddBP:    ODD_HOME,
            drawOddBP:    ODD_DRAW,
            awayOddBP:    ODD_AWAY
        });
        vm.prank(admin);
        idx = pe.createMatch(p);
    }

    /// @dev Build the EIP-191-prefixed hash the contract expects for waitlist registration.
    function _waitlistHash(address user, uint256 nonce) internal view returns (bytes32) {
        uint256 chainId = block.chainid;
        bytes32 raw = keccak256(
            abi.encodePacked("PredictEarn waitlist", user, nonce, chainId)
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
    }

    /// @dev Sign a waitlist message for `user` using `key` and register.
    function _register(address user, uint256 key) internal {
        uint256 nonce     = pe.waitlistNonce(user);
        bytes32 digest    = _waitlistHash(user, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        bytes memory sig  = abi.encodePacked(r, s, v);
        vm.prank(user);
        pe.registerForWaitlist(sig);
    }

    /// @dev Register + approve a user through the waitlist.
    function _registerAndApprove(address user, uint256 key) internal {
        _register(user, key);
        vm.prank(admin);
        pe.approveWaitlist(user);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  1. Match management
// ═══════════════════════════════════════════════════════════════════════════════
contract MatchManagementTest is PredictEarnBase {

    function test_CreateMatch_Success() public {
        uint256 idx = _createMatch();
        assertEq(idx, 0);
        assertEq(pe.getMatchCount(), 1);

        PredictEarn.MatchInfoView memory info = pe.getMatchInfo(0);
        assertEq(info.matchId,  "match-001");
        assertEq(info.homeTeam, "Team A");
        assertEq(info.awayTeam, "Team B");
        assertEq(info.league,   "Test League");

        PredictEarn.MatchStateView memory state = pe.getMatchState(0);
        assertEq(state.homeOddBP, ODD_HOME);
        assertEq(uint8(state.status), uint8(PredictEarn.MatchStatus.OPEN));
    }

    function test_CreateMatch_EmitsEvent() public {
        PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
            matchId:      "m2",
            homeTeam:     "A",
            awayTeam:     "B",
            league:       "L",
            commenceTime: block.timestamp + 1 hours,
            homeOddBP:    15000,
            drawOddBP:    15000,
            awayOddBP:    15000
        });
        vm.expectEmit(true, false, false, true);
        emit MatchCreated(0);
        vm.prank(admin);
        pe.createMatch(p);
    }

    function test_CreateMatch_RevertIfNotAdmin() public {
        PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
            matchId:      "x",
            homeTeam:     "A",
            awayTeam:     "B",
            league:       "L",
            commenceTime: block.timestamp + 1 hours,
            homeOddBP:    15000,
            drawOddBP:    15000,
            awayOddBP:    15000
        });
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not admin");
        pe.createMatch(p);
    }

    function test_CreateMatch_RevertIfAlreadyStarted() public {
        PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
            matchId:      "x",
            homeTeam:     "A",
            awayTeam:     "B",
            league:       "L",
            commenceTime: block.timestamp - 1,
            homeOddBP:    15000,
            drawOddBP:    15000,
            awayOddBP:    15000
        });
        vm.prank(admin);
        vm.expectRevert("PredictEarn: match already started");
        pe.createMatch(p);
    }

    function test_CreateMatch_RevertIfOddsBelow1x() public {
        PredictEarn.CreateMatchParams memory p = PredictEarn.CreateMatchParams({
            matchId:      "x",
            homeTeam:     "A",
            awayTeam:     "B",
            league:       "L",
            commenceTime: block.timestamp + 1 hours,
            homeOddBP:    9999,
            drawOddBP:    15000,
            awayOddBP:    15000
        });
        vm.prank(admin);
        vm.expectRevert("PredictEarn: odds must be > 1.0");
        pe.createMatch(p);
    }

    function test_CloseMatch_Success() public {
        _createMatch();
        vm.prank(admin);
        pe.closeMatch(0);
        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(uint8(s.status), uint8(PredictEarn.MatchStatus.CLOSED));
    }

    function test_CloseMatch_RevertIfAlreadyClosed() public {
        _createMatch();
        vm.prank(admin);
        pe.closeMatch(0);
        vm.prank(admin);
        vm.expectRevert("PredictEarn: not open");
        pe.closeMatch(0);
    }

    function test_ResolveMatch_Success() public {
        _createMatch();
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(uint8(s.result), uint8(PredictEarn.Outcome.HOME));
        assertEq(uint8(s.status), uint8(PredictEarn.MatchStatus.RESOLVED));
        assertGt(s.resolvedAt, 0);
    }

    function test_ResolveMatch_RevertBeforeCommenceTime() public {
        _createMatch();
        vm.prank(admin);
        vm.expectRevert("PredictEarn: match not started yet");
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
    }

    function test_ResolveMatch_RevertNoneOutcome() public {
        _createMatch();
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        vm.expectRevert("PredictEarn: invalid result");
        pe.resolveMatch(0, PredictEarn.Outcome.NONE);
    }

    function test_ResolveMatch_CanResolveFromClosed() public {
        _createMatch();
        vm.prank(admin);
        pe.closeMatch(0);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.DRAW);
        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(uint8(s.result), uint8(PredictEarn.Outcome.DRAW));
    }

    function test_ResolveMatch_RevertIfAlreadyResolved() public {
        _createMatch();
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(admin);
        vm.expectRevert("PredictEarn: already resolved or cancelled");
        pe.resolveMatch(0, PredictEarn.Outcome.AWAY);
    }

    function test_CancelMatch_Success() public {
        _createMatch();
        vm.prank(admin);
        pe.cancelMatch(0);
        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(uint8(s.status), uint8(PredictEarn.MatchStatus.CANCELLED));
    }

    function test_CancelMatch_RevertIfResolved() public {
        _createMatch();
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(admin);
        vm.expectRevert("PredictEarn: already resolved");
        pe.cancelMatch(0);
    }

    function test_UpdateOdds_Success() public {
        _createMatch();
        vm.prank(admin);
        pe.updateOdds(0, 25000, 35000, 45000);
        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(s.homeOddBP, 25000);
        assertEq(s.drawOddBP, 35000);
        assertEq(s.awayOddBP, 45000);
    }

    function test_UpdateOdds_RevertIfClosed() public {
        _createMatch();
        vm.prank(admin);
        pe.closeMatch(0);
        vm.prank(admin);
        vm.expectRevert("PredictEarn: not open");
        pe.updateOdds(0, 25000, 35000, 45000);
    }

    function test_GetOpenMatches() public {
        _createMatch();
        _createMatch();
        vm.prank(admin);
        pe.closeMatch(1);
        uint256[] memory open = pe.getOpenMatches();
        assertEq(open.length, 1);
        assertEq(open[0], 0);
    }

    function test_InvalidMatchIndex_Reverts() public {
        vm.expectRevert("PredictEarn: invalid match");
        pe.getMatchInfo(99);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  2. Betting
// ═══════════════════════════════════════════════════════════════════════════════
contract BettingTest is PredictEarnBase {

    function setUp() public override {
        super.setUp();
        _createMatch();
        _fundAndApprove(alice, 1000 ether);
        _fundAndApprove(bob,   1000 ether);
    }

    function test_PlaceBet_Success() public {
        vm.prank(alice);
        uint256 betIdx = pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        assertEq(betIdx, 0);

        PredictEarn.BetView memory b = pe.getBet(0);
        assertEq(b.bettor,     alice);
        assertEq(b.stake,      1 ether);
        assertEq(b.collateral, 1 ether);
        assertEq(b.leverage,   1);
        assertEq(uint8(b.selection), uint8(PredictEarn.Outcome.HOME));
        assertFalse(b.claimed);
        assertFalse(b.isLeveraged);
        assertEq(b.maxPayout, 2 ether);

        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(s.poolHome, 1 ether);
        assertEq(cusd.balanceOf(address(pe)), 1 ether);
    }

    function test_PlaceBet_EmitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit BetPlaced(0, 0, alice, PredictEarn.Outcome.HOME, 1 ether, 1 ether, 1, 2 ether);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_PlaceBet_AllOutcomes() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.DRAW, 1 ether);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.AWAY, 1 ether);

        PredictEarn.MatchStateView memory s = pe.getMatchState(0);
        assertEq(s.poolHome, 1 ether);
        assertEq(s.poolDraw, 1 ether);
        assertEq(s.poolAway, 1 ether);
    }

    function test_PlaceBet_BelowMinStake_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: below min stake");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 0.1 ether);
    }

    function test_PlaceBet_AboveMaxStake_Reverts() public {
        _fundAndApprove(alice, 10_000 ether);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: above max stake");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 501 ether);
    }

    function test_PlaceBet_NoneOutcome_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: invalid selection");
        pe.placeBet(0, PredictEarn.Outcome.NONE, 1 ether);
    }

    function test_PlaceBet_AfterMatchStart_Reverts() public {
        vm.warp(block.timestamp + 3 hours);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: match started");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_PlaceBet_ClosedMatch_Reverts() public {
        vm.prank(admin);
        pe.closeMatch(0);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: betting closed");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_PlaceBet_MultipleBettors() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 2 ether);
        vm.prank(bob);
        pe.placeBet(0, PredictEarn.Outcome.AWAY, 3 ether);

        assertEq(pe.getBetCount(), 2);
        assertEq(cusd.balanceOf(address(pe)), 5 ether);
    }

    function test_LeveragedBet_Success() public {
        vm.prank(alice);
        uint256 idx = pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 5);
        PredictEarn.BetView memory b = pe.getBet(idx);
        assertEq(b.stake,      1 ether);
        assertEq(b.collateral, 5 ether);
        assertEq(b.leverage,   5);
        assertEq(b.maxPayout,  10 ether);
        assertTrue(b.isLeveraged);
        assertEq(cusd.balanceOf(address(pe)), 5 ether);
    }

    function test_LeveragedBet_MaxLeverage() public {
        vm.prank(alice);
        uint256 idx = pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 100);
        PredictEarn.BetView memory b = pe.getBet(idx);
        assertEq(b.collateral, 100 ether);
        assertEq(b.leverage,   100);
    }

    function test_LeveragedBet_ZeroLeverage_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: bad leverage");
        pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 0);
    }

    function test_LeveragedBet_ExceedMaxLeverage_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: bad leverage");
        pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 101);
    }

    function test_GetUserBets() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.DRAW, 1 ether);

        uint256[] memory bets = pe.getUserBets(alice);
        assertEq(bets.length, 2);
        assertEq(bets[0], 0);
        assertEq(bets[1], 1);
    }

    function test_GetUserBetsForMatch() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.prank(bob);
        pe.placeBet(0, PredictEarn.Outcome.AWAY, 1 ether);

        uint256[] memory aliceBets = pe.getUserBetsForMatch(0, alice);
        assertEq(aliceBets.length, 1);
        assertEq(aliceBets[0], 0);

        uint256[] memory bobBets = pe.getUserBetsForMatch(0, bob);
        assertEq(bobBets.length, 1);
        assertEq(bobBets[0], 1);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  3. Claiming
// ═══════════════════════════════════════════════════════════════════════════════
contract ClaimingTest is PredictEarnBase {

    function setUp() public override {
        super.setUp();
        _createMatch();
        _fundAndApprove(alice, 1000 ether);
        _fundAndApprove(bob,   1000 ether);
        cusd.mint(address(pe), 10_000 ether);
    }

    function test_ClaimWinnings_CorrectPayout() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimWinnings(0);
        uint256 afterBal = cusd.balanceOf(alice);

        uint256 expected = 2 ether - (2 ether * FEE_BP / 10000);
        assertEq(afterBal - before, expected);
        assertEq(pe.totalFeesCollected(), 2 ether * FEE_BP / 10000);
    }

    function test_ClaimWinnings_EmitsEvent() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);

        uint256 expected = 2 ether - (2 ether * FEE_BP / 10000);
        vm.expectEmit(true, true, false, true);
        emit WinningsClaimed(0, alice, expected);
        vm.prank(alice);
        pe.claimWinnings(0);
    }

    function test_ClaimWinnings_Loser_NoTransfer() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.DRAW, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimWinnings(0);
        assertEq(cusd.balanceOf(alice), before);
        assertEq(pe.totalFeesCollected(), 0);
    }

    function test_ClaimWinnings_BetMarkedClaimed() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(alice);
        pe.claimWinnings(0);
        assertTrue(pe.getBet(0).claimed);
    }

    function test_ClaimWinnings_DoubleClaim_Reverts() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(alice);
        pe.claimWinnings(0);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: already claimed");
        pe.claimWinnings(0);
    }

    function test_ClaimWinnings_NotYourBet_Reverts() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(bob);
        vm.expectRevert("PredictEarn: not your bet");
        pe.claimWinnings(0);
    }

    function test_ClaimWinnings_BeforeResolved_Reverts() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not resolved");
        pe.claimWinnings(0);
    }

    function test_IsBetWinner_True() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        assertTrue(pe.isBetWinner(0));
    }

    function test_IsBetWinner_False() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.DRAW, 1 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        assertFalse(pe.isBetWinner(0));
    }

    function test_ClaimWinnings_LeveragedBet() public {
        _fundAndApprove(alice, 10 ether);
        vm.prank(alice);
        pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 3);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimWinnings(0);
        uint256 gain = cusd.balanceOf(alice) - before;
        uint256 expected = 6 ether - (6 ether * FEE_BP / 10000);
        assertEq(gain, expected);
    }

    function test_ClaimRefund_Success() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 2 ether);
        vm.prank(admin);
        pe.cancelMatch(0);

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimRefund(0);
        assertEq(cusd.balanceOf(alice) - before, 2 ether);
    }

    function test_ClaimRefund_EmitsEvent() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 2 ether);
        vm.prank(admin);
        pe.cancelMatch(0);
        vm.expectEmit(true, true, false, true);
        emit RefundClaimed(0, alice, 2 ether);
        vm.prank(alice);
        pe.claimRefund(0);
    }

    function test_ClaimRefund_NotCancelled_Reverts() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 2 ether);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not cancelled");
        pe.claimRefund(0);
    }

    function test_ClaimRefund_DoubleClaim_Reverts() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 2 ether);
        vm.prank(admin);
        pe.cancelMatch(0);
        vm.prank(alice);
        pe.claimRefund(0);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: already claimed");
        pe.claimRefund(0);
    }

    function test_ClaimRefund_LeveragedBet_ReturnsFullCollateral() public {
        _fundAndApprove(alice, 10 ether);
        vm.prank(alice);
        pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, 1 ether, 5);
        vm.prank(admin);
        pe.cancelMatch(0);

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimRefund(0);
        assertEq(cusd.balanceOf(alice) - before, 5 ether);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  4. Waitlist
// ═══════════════════════════════════════════════════════════════════════════════
contract WaitlistTest is PredictEarnBase {

    function test_Register_Success() public {
        _register(alice, aliceKey);
        assertEq(uint8(pe.waitlistStatusOf(alice)), uint8(PredictEarn.WaitlistStatus.PENDING));
        assertEq(pe.waitlistLength(), 1);
        assertEq(pe.waitlistNonce(alice), 1);
    }

    function test_Register_EmitsEvent() public {
        uint256 nonce = pe.waitlistNonce(alice);
        vm.expectEmit(true, false, false, false);
        emit WaitlistRegistered(alice, nonce, 1);
        _register(alice, aliceKey);
    }

    function test_Register_Duplicate_Reverts() public {
        _register(alice, aliceKey);
        vm.expectRevert("PredictEarn: already registered");
        _register(alice, aliceKey);
    }

    function test_Register_BadSignature_Reverts() public {
        uint256 nonce   = pe.waitlistNonce(alice);
        uint256 chainId = block.chainid;
        bytes32 raw     = keccak256(abi.encodePacked("PredictEarn waitlist", alice, nonce, chainId));
        bytes32 digest  = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: signature mismatch");
        pe.registerForWaitlist(sig);
    }

    function test_Register_WrongLength_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: bad signature length");
        pe.registerForWaitlist(new bytes(64));
    }

    function test_ApproveWaitlist_Success() public {
        _register(alice, aliceKey);
        vm.prank(admin);
        pe.approveWaitlist(alice);
        assertEq(uint8(pe.waitlistStatusOf(alice)), uint8(PredictEarn.WaitlistStatus.APPROVED));
        assertGt(pe.getWaitlistEntry(alice).approvedAt, 0);
    }

    function test_ApproveWaitlist_EmitsEvent() public {
        _register(alice, aliceKey);
        vm.expectEmit(true, true, false, false);
        emit WaitlistApproved(alice, admin);
        vm.prank(admin);
        pe.approveWaitlist(alice);
    }

    function test_ApproveWaitlist_NotPending_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("PredictEarn: not pending");
        pe.approveWaitlist(alice);
    }

    function test_ApproveBatch_Success() public {
        _register(alice, aliceKey);
        _register(bob,   bobKey);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        vm.prank(admin);
        pe.approveWaitlistBatch(list);
        assertEq(uint8(pe.waitlistStatusOf(alice)), uint8(PredictEarn.WaitlistStatus.APPROVED));
        assertEq(uint8(pe.waitlistStatusOf(bob)),   uint8(PredictEarn.WaitlistStatus.APPROVED));
    }

    function test_ApproveBatch_SkipsNonPending() public {
        _register(alice, aliceKey);
        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        vm.prank(admin);
        pe.approveWaitlistBatch(list);
        assertEq(uint8(pe.waitlistStatusOf(bob)), uint8(PredictEarn.WaitlistStatus.NONE));
    }

    function test_RevokeWaitlist_Success() public {
        _registerAndApprove(alice, aliceKey);
        vm.prank(admin);
        pe.revokeWaitlist(alice);
        assertEq(uint8(pe.waitlistStatusOf(alice)), uint8(PredictEarn.WaitlistStatus.REVOKED));
    }

    function test_RevokeWaitlist_EmitsEvent() public {
        _register(alice, aliceKey);
        vm.expectEmit(true, true, false, false);
        emit WaitlistRevoked(alice, admin);
        vm.prank(admin);
        pe.revokeWaitlist(alice);
    }

    function test_RevokeWaitlist_NoneStatus_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("PredictEarn: nothing to revoke");
        pe.revokeWaitlist(alice);
    }

    function test_RevokedUser_CanReregister() public {
        _register(alice, aliceKey);
        vm.prank(admin);
        pe.revokeWaitlist(alice);
        assertEq(pe.waitlistNonce(alice), 1);
        _register(alice, aliceKey);
        assertEq(uint8(pe.waitlistStatusOf(alice)), uint8(PredictEarn.WaitlistStatus.PENDING));
        assertEq(pe.waitlistNonce(alice), 2);
        assertEq(pe.waitlistLength(), 1);
    }

    function test_RevokedUser_OldSignature_Reverts() public {
        uint256 chainId = block.chainid;
        bytes32 raw0    = keccak256(abi.encodePacked("PredictEarn waitlist", alice, uint256(0), chainId));
        bytes32 digest0 = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", raw0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest0);
        bytes memory sig0 = abi.encodePacked(r, s, v);

        vm.prank(alice);
        pe.registerForWaitlist(sig0);
        vm.prank(admin);
        pe.revokeWaitlist(alice);

        vm.prank(alice);
        vm.expectRevert("PredictEarn: signature mismatch");
        pe.registerForWaitlist(sig0);
    }

    function test_GetWaitlistPage() public {
        _register(alice, aliceKey);
        _register(bob,   bobKey);
        PredictEarn.WaitlistEntry[] memory page = pe.getWaitlistPage(0, 10);
        assertEq(page.length, 2);
        assertEq(page[0].wallet, alice);
        assertEq(page[1].wallet, bob);
    }

    function test_GetWaitlistPage_OffsetBeyondLength() public {
        _register(alice, aliceKey);
        PredictEarn.WaitlistEntry[] memory page = pe.getWaitlistPage(5, 10);
        assertEq(page.length, 0);
    }

    function test_GetPendingWaitlist() public {
        _register(alice, aliceKey);
        _register(bob,   bobKey);
        vm.prank(admin);
        pe.approveWaitlist(bob);
        PredictEarn.WaitlistEntry[] memory pending = pe.getPendingWaitlist();
        assertEq(pending.length, 1);
        assertEq(pending[0].wallet, alice);
    }

    function test_WaitlistGating_BlocksUnregistered() public {
        _createMatch();
        _fundAndApprove(alice, 100 ether);
        vm.prank(admin);
        pe.setWaitlistGating(true);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not on approved waitlist");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_WaitlistGating_AllowsApprovedUser() public {
        _createMatch();
        _fundAndApprove(alice, 100 ether);
        vm.prank(admin);
        pe.setWaitlistGating(true);
        _registerAndApprove(alice, aliceKey);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_WaitlistGating_BlocksPendingUser() public {
        _createMatch();
        _fundAndApprove(alice, 100 ether);
        vm.prank(admin);
        pe.setWaitlistGating(true);
        _register(alice, aliceKey);
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not on approved waitlist");
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_GatingDisabled_AnyoneCanBet() public {
        _createMatch();
        _fundAndApprove(alice, 100 ether);
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 1 ether);
    }

    function test_SetWaitlistGating_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit WaitlistGatingChanged(true);
        vm.prank(admin);
        pe.setWaitlistGating(true);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  5. Admin (fees, transfer, feeRecipient)
// ═══════════════════════════════════════════════════════════════════════════════
contract AdminTest is PredictEarnBase {

    function setUp() public override {
        super.setUp();
        _createMatch();
        _fundAndApprove(alice, 1000 ether);
        cusd.mint(address(pe), 10_000 ether);
    }

    function test_WithdrawFees_Success() public {
        vm.prank(alice);
        pe.placeBet(0, PredictEarn.Outcome.HOME, 10 ether);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);
        vm.prank(alice);
        pe.claimWinnings(0);

        uint256 fees = pe.totalFeesCollected();
        assertGt(fees, 0);

        uint256 before = cusd.balanceOf(feeRecipient);
        vm.prank(admin);
        pe.withdrawFees();
        assertEq(cusd.balanceOf(feeRecipient), before + fees);
        assertEq(pe.totalFeesCollected(), 0);
    }

    function test_WithdrawFees_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not admin");
        pe.withdrawFees();
    }

    function test_WithdrawFees_NoFees_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("PredictEarn: no fees");
        pe.withdrawFees();
    }

    function test_TransferAdmin_Success() public {
        vm.prank(admin);
        pe.transferAdmin(alice);
        assertEq(pe.admin(), alice);
    }

    function test_TransferAdmin_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit AdminTransferred(admin, alice);
        vm.prank(admin);
        pe.transferAdmin(alice);
    }

    function test_TransferAdmin_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("PredictEarn: zero address");
        pe.transferAdmin(address(0));
    }

    function test_TransferAdmin_NotAdmin_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("PredictEarn: not admin");
        pe.transferAdmin(bob);
    }

    function test_SetFeeRecipient_Success() public {
        vm.prank(admin);
        pe.setFeeRecipient(bob);
        assertEq(pe.feeRecipient(), bob);
    }

    function test_SetFeeRecipient_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert("PredictEarn: zero address");
        pe.setFeeRecipient(address(0));
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  6. Payout math fuzz
// ═══════════════════════════════════════════════════════════════════════════════
contract FuzzTest is PredictEarnBase {

    function setUp() public override {
        super.setUp();
        _createMatch();
        cusd.mint(address(pe), type(uint128).max);
    }

    function testFuzz_PayoutMath(uint256 stake, uint256 leverage) public {
        stake    = bound(stake,    MIN_STAKE, MAX_STAKE);
        leverage = bound(leverage, 1,         100);

        _fundAndApprove(alice, stake * leverage);
        vm.prank(alice);
        uint256 idx = pe.placeLeveragedBet(0, PredictEarn.Outcome.HOME, stake, leverage);

        PredictEarn.BetView memory b = pe.getBet(idx);
        uint256 expectedCollateral = stake * leverage;
        uint256 expectedMaxPayout  = (expectedCollateral * ODD_HOME) / 10000;
        assertEq(b.collateral, expectedCollateral);
        assertEq(b.maxPayout,  expectedMaxPayout);
    }

    function testFuzz_FeeCalc(uint256 stake) public {
        stake = bound(stake, MIN_STAKE, MAX_STAKE);

        _fundAndApprove(alice, stake);
        vm.prank(alice);
        uint256 idx = pe.placeBet(0, PredictEarn.Outcome.HOME, stake);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(admin);
        pe.resolveMatch(0, PredictEarn.Outcome.HOME);

        PredictEarn.BetView memory b = pe.getBet(idx);
        uint256 expectedFee    = (b.maxPayout * FEE_BP) / 10000;
        uint256 expectedPayout = b.maxPayout - expectedFee;

        uint256 before = cusd.balanceOf(alice);
        vm.prank(alice);
        pe.claimWinnings(idx);
        assertEq(cusd.balanceOf(alice) - before, expectedPayout);
        assertEq(pe.totalFeesCollected(), expectedFee);
    }
}
