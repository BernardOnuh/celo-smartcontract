// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
//  ECDSA — EIP-191 personal_sign recovery
//
//  Expects the CALLER to pass a raw 32-byte digest.
//  This library wraps it with the standard Ethereum prefix before ecrecover,
//  matching what eth_sign / personal_sign wallets produce.
// ─────────────────────────────────────────────────────────────────────────────
library ECDSA {
    error BadSignatureLength();
    error BadSignatureV();

    /// @dev Recovers the signer of an EIP-191 personal_sign message.
    function recover(bytes32 hash, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != 65) revert BadSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) { unchecked { v += 27; } }
        if (v != 27 && v != 28) revert BadSignatureV();

        signer = ecrecover(
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)),
            v, r, s
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal ERC-20 interface
// ─────────────────────────────────────────────────────────────────────────────
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
//  PredictEarn
//
//  Sports prediction market on Celo (cUSD).
//  • Admin creates/closes/resolves/cancels matches with fixed implied odds (basis-points).
//  • Users place fixed-odds bets, optionally with leverage (collateral = stake × leverage).
//  • Payout = collateral × oddBP / 10_000  (fee deducted at claim time).
//  • Optional waitlist gating: admin must approve a wallet before it can bet.
//  • Waitlist registration is admin-signed (off-chain allowance), preventing self-approval.
// ─────────────────────────────────────────────────────────────────────────────
contract PredictEarn {

    // ── Libraries ─────────────────────────────────────────────────────────────
    using ECDSA for bytes32;

    // ── Immutables / constants ─────────────────────────────────────────────────
    IERC20 public immutable cUSD;

    uint256 public constant MIN_STAKE        = 0.5  ether;   // 0.5  cUSD
    uint256 public constant MAX_STAKE        = 500  ether;   // 500  cUSD
    uint256 public constant PLATFORM_FEE_BP  = 250;          // 2.5 %
    uint256 public constant MAX_LEVERAGE     = 100;
    uint256 internal constant BP_DENOM       = 10_000;

    // ── Enums ─────────────────────────────────────────────────────────────────
    enum Outcome        { NONE, HOME, DRAW, AWAY }
    enum MatchStatus    { OPEN, CLOSED, RESOLVED, CANCELLED }
    enum WaitlistStatus { NONE, PENDING, APPROVED, REVOKED }

    // ── Structs ───────────────────────────────────────────────────────────────
    struct CreateMatchParams {
        string  matchId;
        string  homeTeam;
        string  awayTeam;
        string  league;
        uint256 commenceTime;
        uint256 homeOddBP;
        uint256 drawOddBP;
        uint256 awayOddBP;
    }

    struct Match {
        string      matchId;
        string      homeTeam;
        string      awayTeam;
        string      league;
        uint256     commenceTime;
        uint256     homeOddBP;
        uint256     drawOddBP;
        uint256     awayOddBP;
        uint256     poolHome;
        uint256     poolDraw;
        uint256     poolAway;
        Outcome     result;
        MatchStatus status;
        uint256     resolvedAt;
    }

    struct Bet {
        address bettor;
        uint256 matchIndex;
        Outcome selection;
        uint256 stake;
        uint256 collateral;   // stake × leverage
        uint256 leverage;
        uint256 maxPayout;    // collateral × oddBP / BP_DENOM
        bool    claimed;
        bool    isLeveraged;
    }

    struct WaitlistEntry {
        address        wallet;
        uint256        registeredAt;
        uint256        approvedAt;
        WaitlistStatus status;
    }

    // Separate "info" and "state" views let callers fetch only what they need.
    struct MatchInfoView {
        string  matchId;
        string  homeTeam;
        string  awayTeam;
        string  league;
        uint256 commenceTime;
    }

    struct MatchStateView {
        uint256     homeOddBP;
        uint256     drawOddBP;
        uint256     awayOddBP;
        uint256     poolHome;
        uint256     poolDraw;
        uint256     poolAway;
        Outcome     result;
        MatchStatus status;
        uint256     resolvedAt;
    }

    // ── State ─────────────────────────────────────────────────────────────────
    address public admin;
    address public feeRecipient;

    bool public paused;
    bool public waitlistGatingEnabled;

    Match[] public matches;
    Bet[]   public bets;

    uint256 public totalFeesCollected;

    /// @dev betIndex[] per (matchIndex → user)
    mapping(uint256 => mapping(address => uint256[])) public userBetsForMatch;
    /// @dev betIndex[] per user
    mapping(address => uint256[]) public userBets;

    mapping(address => WaitlistEntry) private _waitlist;
    /// @dev nonce consumed on each registration; prevents signature replay
    mapping(address => uint256)       public  waitlistNonce;

    address[] public waitlistAddresses;

    // ── Custom errors ─────────────────────────────────────────────────────────
    error NotAdmin();
    error InvalidMatch();
    error Paused();
    error NotApproved();
    error ZeroAddress();

    // match errors
    error MatchAlreadyStarted();
    error OddsTooLow();
    error NotOpen();
    error AlreadyResolvedOrCancelled();
    error InvalidResult();
    error MatchNotStarted();
    error AlreadyResolved();
    error BettingClosed();
    error MatchStarted();
    error MatchNotCancelled();
    error MatchNotResolved();

    // bet errors
    error InvalidBet();
    error NotYourBet();
    error AlreadyClaimed();
    error InvalidSelection();
    error BelowMinStake();
    error AboveMaxStake();
    error BadLeverage();
    error TransferFailed();

    // waitlist errors
    error AlreadyRegistered();
    error NotPending();
    error NothingToRevoke();
    error SignatureMismatch();
    error NoFees();

    // ── Events ────────────────────────────────────────────────────────────────
    event MatchCreated   (uint256 indexed matchIndex);
    event MatchClosed    (uint256 indexed matchIndex);
    event MatchResolved  (uint256 indexed matchIndex, Outcome result);
    event MatchCancelled (uint256 indexed matchIndex);
    event OddsUpdated    (uint256 indexed matchIndex, uint256 homeOddBP, uint256 drawOddBP, uint256 awayOddBP);

    event BetPlaced(
        uint256 indexed betIndex,
        uint256 indexed matchIndex,
        address indexed bettor,
        Outcome selection,
        uint256 stake,
        uint256 collateral,
        uint256 leverage,
        uint256 maxPayout
    );
    event WinningsClaimed  (uint256 indexed betIndex, address indexed bettor, uint256 payout);
    event RefundClaimed    (uint256 indexed betIndex, address indexed bettor, uint256 amount);
    event AdminTransferred (address indexed oldAdmin, address indexed newAdmin);
    event FeeRecipientSet  (address indexed newRecipient);
    event FeeWithdrawn     (address indexed recipient, uint256 amount);
    event PausedSet        (bool paused);

    event WaitlistRegistered (address indexed wallet, uint256 nonce, uint256 position);
    event WaitlistApproved   (address indexed wallet, address indexed approvedBy);
    event WaitlistRevoked    (address indexed wallet, address indexed revokedBy);
    event WaitlistGatingSet  (bool enabled);

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier matchExists(uint256 idx) {
        if (idx >= matches.length) revert InvalidMatch();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyApprovedOrUnrestricted() {
        if (waitlistGatingEnabled && _waitlist[msg.sender].status != WaitlistStatus.APPROVED)
            revert NotApproved();
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address _cUSD, address _feeRecipient) {
        if (_cUSD == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        cUSD         = IERC20(_cUSD);
        admin        = msg.sender;
        feeRecipient = _feeRecipient;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — USER
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Register for the waitlist.
    ///         `signature` must be produced by the ADMIN off-chain, signing:
    ///           keccak256(abi.encodePacked("PredictEarn waitlist", wallet, nonce, chainId))
    ///         This prevents self-approval: only an admin-authorised wallet can pass.
    function registerForWaitlist(bytes calldata signature) external {
        WaitlistStatus current = _waitlist[msg.sender].status;
        if (current != WaitlistStatus.NONE && current != WaitlistStatus.REVOKED)
            revert AlreadyRegistered();

        uint256 nonce   = waitlistNonce[msg.sender];
        bytes32 msgHash = _buildWaitlistHash(msg.sender, nonce);

        // Signature must come from the admin (off-chain allowance pattern).
        if (msgHash.recover(signature) != admin) revert SignatureMismatch();

        unchecked { waitlistNonce[msg.sender] = nonce + 1; }

        if (current == WaitlistStatus.NONE) {
            waitlistAddresses.push(msg.sender);
        }

        _waitlist[msg.sender] = WaitlistEntry({
            wallet:       msg.sender,
            registeredAt: block.timestamp,
            approvedAt:   0,
            status:       WaitlistStatus.PENDING
        });

        emit WaitlistRegistered(msg.sender, nonce, waitlistAddresses.length);
    }

    /// @dev Deterministic hash that the admin signs off-chain.
    function _buildWaitlistHash(address wallet, uint256 nonce) private view returns (bytes32) {
        return keccak256(abi.encodePacked("PredictEarn waitlist", wallet, nonce, block.chainid));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — ADMIN
    // ═════════════════════════════════════════════════════════════════════════

    function approveWaitlist(address wallet) external onlyAdmin {
        WaitlistEntry storage entry = _waitlist[wallet];
        if (entry.status != WaitlistStatus.PENDING) revert NotPending();
        entry.status     = WaitlistStatus.APPROVED;
        entry.approvedAt = block.timestamp;
        emit WaitlistApproved(wallet, msg.sender);
    }

    function approveWaitlistBatch(address[] calldata wallets) external onlyAdmin {
        uint256 ts = block.timestamp;
        for (uint256 i; i < wallets.length;) {
            WaitlistEntry storage entry = _waitlist[wallets[i]];
            if (entry.status == WaitlistStatus.PENDING) {
                entry.status     = WaitlistStatus.APPROVED;
                entry.approvedAt = ts;
                emit WaitlistApproved(wallets[i], msg.sender);
            }
            unchecked { ++i; }
        }
    }

    function revokeWaitlist(address wallet) external onlyAdmin {
        WaitlistStatus s = _waitlist[wallet].status;
        if (s != WaitlistStatus.APPROVED && s != WaitlistStatus.PENDING) revert NothingToRevoke();
        _waitlist[wallet].status = WaitlistStatus.REVOKED;
        emit WaitlistRevoked(wallet, msg.sender);
    }

    function setWaitlistGating(bool enabled) external onlyAdmin {
        waitlistGatingEnabled = enabled;
        emit WaitlistGatingSet(enabled);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    function getWaitlistEntry(address wallet)  external view returns (WaitlistEntry memory) { return _waitlist[wallet]; }
    function waitlistStatusOf(address wallet)  external view returns (WaitlistStatus)       { return _waitlist[wallet].status; }
    function waitlistLength()                  external view returns (uint256)              { return waitlistAddresses.length; }

    /// @notice Returns a page of waitlist entries (pagination helper).
    function getWaitlistPage(uint256 offset, uint256 limit)
        external view returns (WaitlistEntry[] memory page)
    {
        uint256 total = waitlistAddresses.length;
        if (offset >= total) return page;
        uint256 end = offset + limit > total ? total : offset + limit;
        page = new WaitlistEntry[](end - offset);
        for (uint256 i = offset; i < end;) {
            page[i - offset] = _waitlist[waitlistAddresses[i]];
            unchecked { ++i; }
        }
    }

    /// @notice Returns all PENDING entries (off-chain admin dashboard helper).
    function getPendingWaitlist() external view returns (WaitlistEntry[] memory result) {
        address[] storage addrs = waitlistAddresses;
        uint256 total = addrs.length;

        // Two-pass: count then fill (avoids dynamic-array resizing).
        uint256 count;
        for (uint256 i; i < total;) {
            if (_waitlist[addrs[i]].status == WaitlistStatus.PENDING) { unchecked { ++count; } }
            unchecked { ++i; }
        }
        result = new WaitlistEntry[](count);
        uint256 j;
        for (uint256 i; i < total;) {
            if (_waitlist[addrs[i]].status == WaitlistStatus.PENDING) {
                result[j] = _waitlist[addrs[i]];
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    /// @notice Pre-computes the hash the admin must sign for a given wallet.
    function buildWaitlistHash(address wallet) external view returns (bytes32) {
        return _buildWaitlistHash(wallet, waitlistNonce[wallet]);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADMIN — MATCH MANAGEMENT
    // ═════════════════════════════════════════════════════════════════════════

    function createMatch(CreateMatchParams calldata p)
        external onlyAdmin returns (uint256 matchIndex)
    {
        if (p.commenceTime <= block.timestamp) revert MatchAlreadyStarted();
        if (p.homeOddBP <= BP_DENOM || p.drawOddBP <= BP_DENOM || p.awayOddBP <= BP_DENOM)
            revert OddsTooLow();

        matchIndex = matches.length;
        matches.push(Match({
            matchId:      p.matchId,
            homeTeam:     p.homeTeam,
            awayTeam:     p.awayTeam,
            league:       p.league,
            commenceTime: p.commenceTime,
            homeOddBP:    p.homeOddBP,
            drawOddBP:    p.drawOddBP,
            awayOddBP:    p.awayOddBP,
            poolHome:     0,
            poolDraw:     0,
            poolAway:     0,
            result:       Outcome.NONE,
            status:       MatchStatus.OPEN,
            resolvedAt:   0
        }));
        emit MatchCreated(matchIndex);
    }

    function closeMatch(uint256 idx) external onlyAdmin matchExists(idx) {
        if (matches[idx].status != MatchStatus.OPEN) revert NotOpen();
        matches[idx].status = MatchStatus.CLOSED;
        emit MatchClosed(idx);
    }

    function resolveMatch(uint256 idx, Outcome result) external onlyAdmin matchExists(idx) {
        Match storage m = matches[idx];
        MatchStatus s = m.status;
        if (s != MatchStatus.OPEN && s != MatchStatus.CLOSED) revert AlreadyResolvedOrCancelled();
        if (result == Outcome.NONE)                           revert InvalidResult();
        if (block.timestamp < m.commenceTime)                 revert MatchNotStarted();

        m.result     = result;
        m.status     = MatchStatus.RESOLVED;
        m.resolvedAt = block.timestamp;
        emit MatchResolved(idx, result);
    }

    function cancelMatch(uint256 idx) external onlyAdmin matchExists(idx) {
        MatchStatus s = matches[idx].status;
        if (s == MatchStatus.RESOLVED || s == MatchStatus.CANCELLED) revert AlreadyResolved();
        matches[idx].status = MatchStatus.CANCELLED;
        emit MatchCancelled(idx);
    }

    function updateOdds(uint256 idx, uint256 h, uint256 d, uint256 a)
        external onlyAdmin matchExists(idx)
    {
        if (matches[idx].status != MatchStatus.OPEN) revert NotOpen();
        if (h <= BP_DENOM || d <= BP_DENOM || a <= BP_DENOM) revert OddsTooLow();
        Match storage m = matches[idx];
        m.homeOddBP = h;
        m.drawOddBP = d;
        m.awayOddBP = a;
        emit OddsUpdated(idx, h, d, a);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADMIN — FINANCE
    // ═════════════════════════════════════════════════════════════════════════

    function withdrawFees() external onlyAdmin {
        uint256 amount = totalFeesCollected;
        if (amount == 0) revert NoFees();
        totalFeesCollected = 0;
        if (!cUSD.transfer(feeRecipient, amount)) revert TransferFailed();
        emit FeeWithdrawn(feeRecipient, amount);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function setFeeRecipient(address r) external onlyAdmin {
        if (r == address(0)) revert ZeroAddress();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedSet(_paused);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER — BETTING
    // ═════════════════════════════════════════════════════════════════════════

    function placeBet(uint256 idx, Outcome sel, uint256 stakeWei)
        external
        whenNotPaused
        matchExists(idx)
        onlyApprovedOrUnrestricted
        returns (uint256 betIndex)
    {
        betIndex = _placeBet(idx, sel, stakeWei, 1);
    }

    function placeLeveragedBet(uint256 idx, Outcome sel, uint256 stakeWei, uint256 leverage)
        external
        whenNotPaused
        matchExists(idx)
        onlyApprovedOrUnrestricted
        returns (uint256 betIndex)
    {
        if (leverage < 2 || leverage > MAX_LEVERAGE) revert BadLeverage();
        betIndex = _placeBet(idx, sel, stakeWei, leverage);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER — CLAIMING
    // ═════════════════════════════════════════════════════════════════════════

    function claimWinnings(uint256 betIndex) external whenNotPaused {
        Bet storage bet = _validateClaim(betIndex);
        if (matches[bet.matchIndex].status != MatchStatus.RESOLVED) revert MatchNotResolved();

        bet.claimed = true; // CEI: mark before transfer

        if (bet.selection == matches[bet.matchIndex].result) {
            uint256 maxPayout = bet.maxPayout;
            uint256 fee       = (maxPayout * PLATFORM_FEE_BP) / BP_DENOM;
            uint256 payout    = maxPayout - fee;
            unchecked { totalFeesCollected += fee; }
            if (!cUSD.transfer(msg.sender, payout)) revert TransferFailed();
            emit WinningsClaimed(betIndex, msg.sender, payout);
        }
        // Lost bets: collateral already in contract; no transfer needed.
    }

    function claimRefund(uint256 betIndex) external whenNotPaused {
        Bet storage bet = _validateClaim(betIndex);
        if (matches[bet.matchIndex].status != MatchStatus.CANCELLED) revert MatchNotCancelled();

        uint256 refund = bet.collateral;
        bet.claimed = true; // CEI: mark before transfer

        if (!cUSD.transfer(msg.sender, refund)) revert TransferFailed();
        emit RefundClaimed(betIndex, msg.sender, refund);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═════════════════════════════════════════════════════════════════════════

    function _validateClaim(uint256 betIndex) private view returns (Bet storage bet) {
        if (betIndex >= bets.length)          revert InvalidBet();
        bet = bets[betIndex];
        if (bet.bettor != msg.sender)         revert NotYourBet();
        if (bet.claimed)                      revert AlreadyClaimed();
    }

    function _placeBet(
        uint256 idx,
        Outcome sel,
        uint256 stakeWei,
        uint256 leverage
    ) internal returns (uint256 betIndex) {
        Match storage m = matches[idx];

        if (m.status != MatchStatus.OPEN)       revert BettingClosed();
        if (block.timestamp >= m.commenceTime)  revert MatchStarted();
        if (sel == Outcome.NONE)                revert InvalidSelection();
        if (stakeWei < MIN_STAKE)               revert BelowMinStake();
        if (stakeWei > MAX_STAKE)               revert AboveMaxStake();

        uint256 collateral = stakeWei * leverage;
        uint256 oddBP      = _getOddBP(m, sel);
        uint256 maxPayout  = (collateral * oddBP) / BP_DENOM;

        // Pool tracks total collateral committed to each outcome.
        if      (sel == Outcome.HOME) m.poolHome += collateral;
        else if (sel == Outcome.DRAW) m.poolDraw += collateral;
        else                          m.poolAway += collateral;

        if (!cUSD.transferFrom(msg.sender, address(this), collateral)) revert TransferFailed();

        betIndex = bets.length;
        bets.push(Bet({
            bettor:      msg.sender,
            matchIndex:  idx,
            selection:   sel,
            stake:       stakeWei,
            collateral:  collateral,
            leverage:    leverage,
            maxPayout:   maxPayout,
            claimed:     false,
            isLeveraged: leverage > 1
        }));

        userBets[msg.sender].push(betIndex);
        userBetsForMatch[idx][msg.sender].push(betIndex);

        emit BetPlaced(betIndex, idx, msg.sender, sel, stakeWei, collateral, leverage, maxPayout);
    }

    function _getOddBP(Match storage m, Outcome sel) private view returns (uint256) {
        if (sel == Outcome.HOME) return m.homeOddBP;
        if (sel == Outcome.DRAW) return m.drawOddBP;
        return m.awayOddBP;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    function getMatchCount() external view returns (uint256) { return matches.length; }
    function getBetCount()   external view returns (uint256) { return bets.length;    }

    function getMatchInfo(uint256 idx)
        external view matchExists(idx) returns (MatchInfoView memory v)
    {
        Match storage m = matches[idx];
        v = MatchInfoView({
            matchId:      m.matchId,
            homeTeam:     m.homeTeam,
            awayTeam:     m.awayTeam,
            league:       m.league,
            commenceTime: m.commenceTime
        });
    }

    function getMatchState(uint256 idx)
        external view matchExists(idx) returns (MatchStateView memory v)
    {
        Match storage m = matches[idx];
        v = MatchStateView({
            homeOddBP:  m.homeOddBP,
            drawOddBP:  m.drawOddBP,
            awayOddBP:  m.awayOddBP,
            poolHome:   m.poolHome,
            poolDraw:   m.poolDraw,
            poolAway:   m.poolAway,
            result:     m.result,
            status:     m.status,
            resolvedAt: m.resolvedAt
        });
    }

    function getBet(uint256 betIndex) external view returns (Bet memory) {
        if (betIndex >= bets.length) revert InvalidBet();
        return bets[betIndex];
    }

    function getUserBets(address user) external view returns (uint256[] memory) {
        return userBets[user];
    }

    function getUserBetsForMatch(uint256 idx, address user)
        external view returns (uint256[] memory)
    {
        return userBetsForMatch[idx][user];
    }

    /// @notice Returns indices of all OPEN matches.
    function getOpenMatches() external view returns (uint256[] memory indices) {
        uint256 total = matches.length;
        uint256 count;
        for (uint256 i; i < total;) {
            if (matches[i].status == MatchStatus.OPEN) { unchecked { ++count; } }
            unchecked { ++i; }
        }
        indices = new uint256[](count);
        uint256 j;
        for (uint256 i; i < total;) {
            if (matches[i].status == MatchStatus.OPEN) {
                indices[j] = i;
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    function isBetWinner(uint256 betIndex) external view returns (bool) {
        if (betIndex >= bets.length) revert InvalidBet();
        Bet storage b = bets[betIndex];
        return matches[b.matchIndex].status == MatchStatus.RESOLVED
            && b.selection == matches[b.matchIndex].result;
    }
}
