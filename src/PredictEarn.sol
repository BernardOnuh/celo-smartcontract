// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

library ECDSA {
    function recover(bytes32 hash, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "ECDSA: bad sig length");
        bytes32 r;
        bytes32 s;
        uint8   v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "ECDSA: bad v");
        return ecrecover(
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)),
            v, r, s
        );
    }
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PredictEarn {
    using ECDSA for bytes32;

    address public constant CUSD_ADDRESS    = 0x765DE816845861e75A25fCA122bb6898B8B1282a;
    IERC20  public constant cUSD            = IERC20(CUSD_ADDRESS);

    uint256 public constant MIN_STAKE       = 0.5  ether;
    uint256 public constant MAX_STAKE       = 500  ether;
    uint256 public constant PLATFORM_FEE_BP = 250;
    uint256 public constant MAX_LEVERAGE    = 100;

    enum Outcome        { NONE, HOME, DRAW, AWAY }
    enum MatchStatus    { OPEN, CLOSED, RESOLVED, CANCELLED }
    enum WaitlistStatus { NONE, PENDING, APPROVED, REVOKED }

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
        uint256 collateral;
        uint256 leverage;
        uint256 maxPayout;
        bool    claimed;
        bool    isLeveraged;
    }

    struct WaitlistEntry {
        address        wallet;
        uint256        registeredAt;
        uint256        approvedAt;
        WaitlistStatus status;
    }

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

    struct BetView {
        address bettor;
        uint256 matchIndex;
        Outcome selection;
        uint256 stake;
        uint256 collateral;
        uint256 leverage;
        uint256 maxPayout;
        bool    claimed;
        bool    isLeveraged;
    }

    // ── State ─────────────────────────────────────────────────────────────────
    address public admin;
    address public feeRecipient;

    Match[] public matches;
    Bet[]   public bets;

    mapping(uint256 => mapping(address => uint256[])) public userBetsForMatch;
    mapping(address => uint256[])                     public userBets;

    uint256 public totalFeesCollected;
    bool    public waitlistGatingEnabled;

    mapping(address => WaitlistEntry) private _waitlist;
    mapping(address => bytes)         private _signatures;
    mapping(address => bytes32)       private _messageHashes;

    address[]                   public waitlistAddresses;
    mapping(address => uint256) public waitlistNonce;

    // ── Events ────────────────────────────────────────────────────────────────
    event MatchCreated(uint256 indexed matchIndex);
    event MatchClosed(uint256 indexed matchIndex);
    event MatchResolved(uint256 indexed matchIndex, Outcome result);
    event MatchCancelled(uint256 indexed matchIndex);
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
    event WinningsClaimed(uint256 indexed betIndex, address indexed bettor, uint256 payout);
    event RefundClaimed(uint256 indexed betIndex, address indexed bettor, uint256 amount);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event WaitlistRegistered(address indexed wallet, uint256 nonce, uint256 position);
    event WaitlistApproved(address indexed wallet, address indexed approvedBy);
    event WaitlistRevoked(address indexed wallet, address indexed revokedBy);
    event WaitlistGatingChanged(bool enabled);

    modifier onlyAdmin() {
        require(msg.sender == admin, "PredictEarn: not admin");
        _;
    }

    modifier matchExists(uint256 idx) {
        require(idx < matches.length, "PredictEarn: invalid match");
        _;
    }

    modifier onlyApprovedOrUnrestricted() {
        if (waitlistGatingEnabled) {
            require(
                _waitlist[msg.sender].status == WaitlistStatus.APPROVED,
                "PredictEarn: not on approved waitlist"
            );
        }
        _;
    }

    constructor(address _feeRecipient) {
        admin        = msg.sender;
        feeRecipient = _feeRecipient;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — USER
    // ═════════════════════════════════════════════════════════════════════════

    function registerForWaitlist(bytes calldata signature) external {
        WaitlistStatus current = _waitlist[msg.sender].status;
        require(
            current == WaitlistStatus.NONE || current == WaitlistStatus.REVOKED,
            "PredictEarn: already registered"
        );
        require(signature.length == 65, "PredictEarn: bad signature length");

        _verifySignature(signature);

        uint256 nonce = waitlistNonce[msg.sender];
        waitlistNonce[msg.sender] = nonce + 1;

        if (current == WaitlistStatus.NONE) {
            waitlistAddresses.push(msg.sender);
        }

        _waitlist[msg.sender] = WaitlistEntry({
            wallet:       msg.sender,
            registeredAt: block.timestamp,
            approvedAt:   0,
            status:       WaitlistStatus.PENDING
        });

        _signatures[msg.sender] = signature;

        emit WaitlistRegistered(msg.sender, nonce, waitlistAddresses.length);
    }

    function _verifySignature(bytes calldata signature) private {
        uint256 nonce = waitlistNonce[msg.sender];
        uint256 chainId;
        assembly { chainId := chainid() }

        bytes32 msgHash = keccak256(
            abi.encodePacked("PredictEarn waitlist", msg.sender, nonce, chainId)
        );

        address recovered = msgHash.recover(signature);
        require(recovered == msg.sender, "PredictEarn: signature mismatch");

        _messageHashes[msg.sender] = msgHash;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — ADMIN
    // ═════════════════════════════════════════════════════════════════════════

    function approveWaitlist(address wallet) external onlyAdmin {
        require(_waitlist[wallet].status == WaitlistStatus.PENDING, "PredictEarn: not pending");
        _waitlist[wallet].status     = WaitlistStatus.APPROVED;
        _waitlist[wallet].approvedAt = block.timestamp;
        emit WaitlistApproved(wallet, msg.sender);
    }

    function approveWaitlistBatch(address[] calldata wallets) external onlyAdmin {
        for (uint256 i = 0; i < wallets.length; i++) {
            if (_waitlist[wallets[i]].status == WaitlistStatus.PENDING) {
                _waitlist[wallets[i]].status     = WaitlistStatus.APPROVED;
                _waitlist[wallets[i]].approvedAt = block.timestamp;
                emit WaitlistApproved(wallets[i], msg.sender);
            }
        }
    }

    function revokeWaitlist(address wallet) external onlyAdmin {
        WaitlistStatus s = _waitlist[wallet].status;
        require(
            s == WaitlistStatus.APPROVED || s == WaitlistStatus.PENDING,
            "PredictEarn: nothing to revoke"
        );
        _waitlist[wallet].status = WaitlistStatus.REVOKED;
        emit WaitlistRevoked(wallet, msg.sender);
    }

    function setWaitlistGating(bool enabled) external onlyAdmin {
        waitlistGatingEnabled = enabled;
        emit WaitlistGatingChanged(enabled);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  WAITLIST — VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    function getWaitlistEntry(address wallet)       external view returns (WaitlistEntry memory) { return _waitlist[wallet]; }
    function getWaitlistSignature(address wallet)   external view returns (bytes memory)         { return _signatures[wallet]; }
    function getWaitlistMessageHash(address wallet) external view returns (bytes32)              { return _messageHashes[wallet]; }
    function waitlistStatusOf(address wallet)       external view returns (WaitlistStatus)       { return _waitlist[wallet].status; }
    function waitlistLength()                       external view returns (uint256)              { return waitlistAddresses.length; }

    function getWaitlistPage(uint256 offset, uint256 limit)
        external view returns (WaitlistEntry[] memory page)
    {
        uint256 total = waitlistAddresses.length;
        if (offset >= total) return page;
        uint256 end = offset + limit > total ? total : offset + limit;
        page = new WaitlistEntry[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _waitlist[waitlistAddresses[i]];
        }
    }

    function getPendingWaitlist() external view returns (WaitlistEntry[] memory result) {
        uint256 count;
        for (uint256 i = 0; i < waitlistAddresses.length; i++) {
            if (_waitlist[waitlistAddresses[i]].status == WaitlistStatus.PENDING) count++;
        }
        result = new WaitlistEntry[](count);
        uint256 j;
        for (uint256 i = 0; i < waitlistAddresses.length; i++) {
            if (_waitlist[waitlistAddresses[i]].status == WaitlistStatus.PENDING) {
                result[j++] = _waitlist[waitlistAddresses[i]];
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ADMIN
    // ═════════════════════════════════════════════════════════════════════════

    function createMatch(CreateMatchParams calldata p)
        external onlyAdmin returns (uint256 matchIndex)
    {
        require(p.commenceTime > block.timestamp, "PredictEarn: match already started");
        require(
            p.homeOddBP > 10000 && p.drawOddBP > 10000 && p.awayOddBP > 10000,
            "PredictEarn: odds must be > 1.0"
        );
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
        require(matches[idx].status == MatchStatus.OPEN, "PredictEarn: not open");
        matches[idx].status = MatchStatus.CLOSED;
        emit MatchClosed(idx);
    }

    function resolveMatch(uint256 idx, Outcome result) external onlyAdmin matchExists(idx) {
        Match storage m = matches[idx];
        require(
            m.status == MatchStatus.OPEN || m.status == MatchStatus.CLOSED,
            "PredictEarn: already resolved or cancelled"
        );
        require(result != Outcome.NONE,            "PredictEarn: invalid result");
        require(block.timestamp >= m.commenceTime, "PredictEarn: match not started yet");
        m.result     = result;
        m.status     = MatchStatus.RESOLVED;
        m.resolvedAt = block.timestamp;
        emit MatchResolved(idx, result);
    }

    function cancelMatch(uint256 idx) external onlyAdmin matchExists(idx) {
        require(matches[idx].status != MatchStatus.RESOLVED, "PredictEarn: already resolved");
        matches[idx].status = MatchStatus.CANCELLED;
        emit MatchCancelled(idx);
    }

    function updateOdds(uint256 idx, uint256 h, uint256 d, uint256 a)
        external onlyAdmin matchExists(idx)
    {
        require(matches[idx].status == MatchStatus.OPEN, "PredictEarn: not open");
        matches[idx].homeOddBP = h;
        matches[idx].drawOddBP = d;
        matches[idx].awayOddBP = a;
    }

    function withdrawFees() external onlyAdmin {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "PredictEarn: no fees");
        totalFeesCollected = 0;
        require(cUSD.transfer(feeRecipient, amount), "PredictEarn: fee transfer failed");
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "PredictEarn: zero address");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function setFeeRecipient(address r) external onlyAdmin {
        require(r != address(0), "PredictEarn: zero address");
        feeRecipient = r;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  USER
    // ═════════════════════════════════════════════════════════════════════════

    function placeBet(uint256 idx, Outcome sel, uint256 stakeWei)
        external matchExists(idx) onlyApprovedOrUnrestricted returns (uint256)
    {
        return _placeBet(idx, sel, stakeWei, 1);
    }

    function placeLeveragedBet(uint256 idx, Outcome sel, uint256 stakeWei, uint256 leverage)
        external matchExists(idx) onlyApprovedOrUnrestricted returns (uint256)
    {
        require(leverage >= 1 && leverage <= MAX_LEVERAGE, "PredictEarn: bad leverage");
        return _placeBet(idx, sel, stakeWei, leverage);
    }

    function claimWinnings(uint256 betIndex) external {
        require(betIndex < bets.length,  "PredictEarn: invalid bet");
        Bet storage bet = bets[betIndex];
        require(bet.bettor == msg.sender, "PredictEarn: not your bet");
        require(!bet.claimed,             "PredictEarn: already claimed");
        require(matches[bet.matchIndex].status == MatchStatus.RESOLVED, "PredictEarn: not resolved");
        bet.claimed = true;
        if (bet.selection == matches[bet.matchIndex].result) {
            uint256 fee    = (bet.maxPayout * PLATFORM_FEE_BP) / 10000;
            uint256 payout = bet.maxPayout - fee;
            totalFeesCollected += fee;
            require(cUSD.transfer(msg.sender, payout), "PredictEarn: payout failed");
            emit WinningsClaimed(betIndex, msg.sender, payout);
        }
    }

    function claimRefund(uint256 betIndex) external {
        require(betIndex < bets.length,  "PredictEarn: invalid bet");
        Bet storage bet = bets[betIndex];
        require(bet.bettor == msg.sender, "PredictEarn: not your bet");
        require(!bet.claimed,             "PredictEarn: already claimed");
        require(matches[bet.matchIndex].status == MatchStatus.CANCELLED, "PredictEarn: not cancelled");
        bet.claimed = true;
        uint256 refund = bet.collateral;
        require(cUSD.transfer(msg.sender, refund), "PredictEarn: refund failed");
        emit RefundClaimed(betIndex, msg.sender, refund);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  INTERNAL
    // ═════════════════════════════════════════════════════════════════════════

    function _placeBet(uint256 idx, Outcome sel, uint256 stakeWei, uint256 leverage)
        internal returns (uint256 betIndex)
    {
        uint256 maxPayout = _validateAndCollect(idx, sel, stakeWei, leverage);
        betIndex = _recordBet(idx, sel, stakeWei, leverage, maxPayout);
    }

    function _validateAndCollect(
        uint256 idx,
        Outcome sel,
        uint256 stakeWei,
        uint256 leverage
    ) internal returns (uint256 maxPayout) {
        Match storage m = matches[idx];
        require(m.status == MatchStatus.OPEN,     "PredictEarn: betting closed");
        require(block.timestamp < m.commenceTime, "PredictEarn: match started");
        require(sel != Outcome.NONE,              "PredictEarn: invalid selection");
        require(stakeWei >= MIN_STAKE,            "PredictEarn: below min stake");
        require(stakeWei <= MAX_STAKE,            "PredictEarn: above max stake");

        uint256 collateral = stakeWei * leverage;
        maxPayout = (collateral * _getOddBP(m, sel)) / 10000;

        require(
            cUSD.transferFrom(msg.sender, address(this), collateral),
            "PredictEarn: transfer failed"
        );

        if      (sel == Outcome.HOME) m.poolHome += stakeWei;
        else if (sel == Outcome.DRAW) m.poolDraw += stakeWei;
        else                          m.poolAway += stakeWei;
    }

    function _recordBet(
        uint256 idx,
        Outcome sel,
        uint256 stakeWei,
        uint256 leverage,
        uint256 maxPayout
    ) internal returns (uint256 betIndex) {
        uint256 collateral = stakeWei * leverage;
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

    function _getOddBP(Match storage m, Outcome sel) internal view returns (uint256) {
        if (sel == Outcome.HOME) return m.homeOddBP;
        if (sel == Outcome.DRAW) return m.drawOddBP;
        return m.awayOddBP;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ═════════════════════════════════════════════════════════════════════════

    function getMatchCount() external view returns (uint256) { return matches.length; }
    function getBetCount()   external view returns (uint256) { return bets.length; }

    function getMatchInfo(uint256 idx)
        external view matchExists(idx) returns (MatchInfoView memory v)
    {
        Match storage m = matches[idx];
        v.matchId      = m.matchId;
        v.homeTeam     = m.homeTeam;
        v.awayTeam     = m.awayTeam;
        v.league       = m.league;
        v.commenceTime = m.commenceTime;
    }

    function getMatchState(uint256 idx)
        external view matchExists(idx) returns (MatchStateView memory v)
    {
        Match storage m = matches[idx];
        v.homeOddBP  = m.homeOddBP;
        v.drawOddBP  = m.drawOddBP;
        v.awayOddBP  = m.awayOddBP;
        v.poolHome   = m.poolHome;
        v.poolDraw   = m.poolDraw;
        v.poolAway   = m.poolAway;
        v.result     = m.result;
        v.status     = m.status;
        v.resolvedAt = m.resolvedAt;
    }

    function getBet(uint256 betIndex)
        external view returns (BetView memory v)
    {
        require(betIndex < bets.length, "PredictEarn: invalid bet");
        Bet storage b = bets[betIndex];
        v.bettor      = b.bettor;
        v.matchIndex  = b.matchIndex;
        v.selection   = b.selection;
        v.stake       = b.stake;
        v.collateral  = b.collateral;
        v.leverage    = b.leverage;
        v.maxPayout   = b.maxPayout;
        v.claimed     = b.claimed;
        v.isLeveraged = b.isLeveraged;
    }

    function getUserBets(address user) external view returns (uint256[] memory) {
        return userBets[user];
    }

    function getUserBetsForMatch(uint256 idx, address user)
        external view returns (uint256[] memory)
    {
        return userBetsForMatch[idx][user];
    }

    function getOpenMatches() external view returns (uint256[] memory indices) {
        uint256 count;
        for (uint256 i = 0; i < matches.length; i++) {
            if (matches[i].status == MatchStatus.OPEN) count++;
        }
        indices = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < matches.length; i++) {
            if (matches[i].status == MatchStatus.OPEN) indices[j++] = i;
        }
    }

    function isBetWinner(uint256 betIndex) external view returns (bool) {
        require(betIndex < bets.length, "PredictEarn: invalid bet");
        Bet storage b = bets[betIndex];
        return matches[b.matchIndex].status == MatchStatus.RESOLVED
            && b.selection == matches[b.matchIndex].result;
    }
}
