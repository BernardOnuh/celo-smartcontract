// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title PredictEarn
 * @notice Football prediction market on Celo using cUSD.
 *         Supports standard pool bets and leveraged bets.
 *         Also includes a waitlist registry.
 *
 * Flow:
 *  1. Owner registers matches via registerMatch().
 *  2. Users approve cUSD and call placeBet() or placeLeveragedBet().
 *  3. Owner resolves matches via resolveMatch() with the winning outcome.
 *  4. Winners call claimWinnings(); cancelled-match bettors call claimRefund().
 *
 * Waitlist:
 *  - Anyone calls joinWaitlist(referralCode) to register interest.
 *  - Owner emits events and can query the list.
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}


contract PredictEarn {

    // ────────────────────────────────────────────────────────────
    //  Constants & immutables
    // ────────────────────────────────────────────────────────────

    address public immutable owner;
    IERC20  public immutable cUSD;

    uint256 public constant PLATFORM_FEE_BPS = 100;   // 1%
    uint256 public constant MIN_STAKE         = 0.5e19; // 0.05 cUSD
    uint256 public constant MAX_LEVERAGE      = 100;

    // cUSD on Celo mainnet: 0x765DE816845861e75A25fCA122bb6898B8B1282b
    // cUSD on Alfajores:    0x874069Fa1Eb16D44d622F2e0Ca25eeA162369bC1

    // ────────────────────────────────────────────────────────────
    //  Enums
    // ────────────────────────────────────────────────────────────

    enum Outcome { Home, Draw, Away, Unresolved, Cancelled }

    // ────────────────────────────────────────────────────────────
    //  Structs
    // ────────────────────────────────────────────────────────────

    struct Match {
        string  matchId;          // TheOddsAPI ID (off-chain reference)
        string  description;      // e.g. "Man City vs Man United"
        uint256 commenceTime;     // Unix timestamp — betting closes here
        Outcome result;
        bool    resolved;
        bool    cancelled;
        // Pool balances per outcome (in cUSD wei)
        uint256 poolHome;
        uint256 poolDraw;
        uint256 poolAway;
        uint256 totalPool;
    }

    struct Bet {
        address bettor;
        uint32  matchIndex;
        Outcome selection;
        uint256 stake;        // amount bettor intended to stake
        uint256 collateral;   // stake * leverage (locked from bettor)
        uint8   leverage;     // 1 = standard
        bool    claimed;
    }

    struct WaitlistEntry {
        address wallet;
        string  email;          // optional — bettor can pass "" for privacy
        string  referralCode;   // optional referral
        uint256 registeredAt;
    }

    // ────────────────────────────────────────────────────────────
    //  State
    // ────────────────────────────────────────────────────────────

    Match[]          public matches;
    Bet[]            public bets;
    WaitlistEntry[]  public waitlist;

    /// matchId (string) → on-chain index + 1  (0 means not registered)
    mapping(string => uint256)  public matchIdToIndex;

    /// bettor → list of bet indices
    mapping(address => uint256[]) public userBets;

    /// bettor → waitlist slot + 1  (0 means not registered)
    mapping(address => uint256)   public waitlistSlot;

    uint256 public collectedFees;

    // ────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────

    event MatchRegistered(uint256 indexed matchIndex, string matchId, string description, uint256 commenceTime);
    event BetPlaced(uint256 indexed betIndex, address indexed bettor, uint32 matchIndex, Outcome selection, uint256 collateral, uint8 leverage);
    event MatchResolved(uint32 indexed matchIndex, Outcome result);
    event MatchCancelled(uint32 indexed matchIndex);
    event WinningsClaimed(uint256 indexed betIndex, address indexed bettor, uint256 payout);
    event RefundClaimed(uint256 indexed betIndex, address indexed bettor, uint256 refund);
    event FeeWithdrawn(address indexed to, uint256 amount);
    event WaitlistJoined(address indexed wallet, uint256 slot, string referralCode);

    // ────────────────────────────────────────────────────────────
    //  Modifiers
    // ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier validMatch(uint32 idx) {
        require(idx < matches.length, "Invalid match");
        _;
    }

    // ────────────────────────────────────────────────────────────
    //  Constructor
    // ────────────────────────────────────────────────────────────

    constructor(address _cUSD) {
        owner = msg.sender;
        cUSD  = IERC20(_cUSD);
    }

    // ════════════════════════════════════════════════════════════
    //  ADMIN — Match management
    // ════════════════════════════════════════════════════════════

    /**
     * @notice Register a new match. Can be called any time before betting closes.
     * @param matchId       TheOddsAPI game ID (string key used by front-end)
     * @param description   Human-readable label, e.g. "Arsenal vs Chelsea"
     * @param commenceTime  Unix timestamp when the match starts (betting closes)
     */
    function registerMatch(
        string calldata matchId,
        string calldata description,
        uint256 commenceTime
    ) external onlyOwner {
        require(matchIdToIndex[matchId] == 0, "Already registered");
        require(commenceTime > block.timestamp, "Must be in the future");

        uint256 idx = matches.length;
        matches.push(Match({
            matchId:      matchId,
            description:  description,
            commenceTime: commenceTime,
            result:       Outcome.Unresolved,
            resolved:     false,
            cancelled:    false,
            poolHome:     0,
            poolDraw:     0,
            poolAway:     0,
            totalPool:    0
        }));

        matchIdToIndex[matchId] = idx + 1; // store 1-indexed
        emit MatchRegistered(idx, matchId, description, commenceTime);
    }

    /**
     * @notice Resolve a match with the final outcome.
     *         Must be called after commenceTime.
     */
     
    function resolveMatch(uint32 matchIndex, Outcome result) external onlyOwner validMatch(matchIndex) {
        Match storage m = matches[matchIndex];
        require(!m.resolved && !m.cancelled, "Already finalised");
        require(result == Outcome.Home || result == Outcome.Draw || result == Outcome.Away, "Invalid result");

        m.result   = result;
        m.resolved = true;
        emit MatchResolved(matchIndex, result);
    }

    /**
     * @notice Cancel a match (e.g. postponed). All bettors get full refunds.
     */
    function cancelMatch(uint32 matchIndex) external onlyOwner validMatch(matchIndex) {
        Match storage m = matches[matchIndex];
        require(!m.resolved && !m.cancelled, "Already finalised");
        m.cancelled = true;
        emit MatchCancelled(matchIndex);
    }

    // ════════════════════════════════════════════════════════════
    //  USER — Place bets
    // ════════════════════════════════════════════════════════════

    /**
     * @notice Place a standard (1x leverage) bet.
     * @param matchId   TheOddsAPI game ID
     * @param selection Home=0, Draw=1, Away=2
     * @param stake     Amount in cUSD wei (≥ 0.5 cUSD)
     */
    function placeBet(
        string calldata matchId,
        Outcome selection,
        uint256 stake
    ) external {
        _placeBet(matchId, selection, stake, 1);
    }

    /**
     * @notice Place a leveraged bet. Collateral = stake × leverage.
     *         You lose all collateral if you're wrong; payout is also multiplied.
     * @param leverage  1–100
     */
    function placeLeveragedBet(
        string calldata matchId,
        Outcome selection,
        uint256 stake,
        uint8   leverage
    ) external {
        require(leverage >= 2 && leverage <= MAX_LEVERAGE, "Invalid leverage");
        _placeBet(matchId, selection, stake, leverage);
    }

    function _placeBet(
        string calldata matchId,
        Outcome selection,
        uint256 stake,
        uint8   leverage
    ) internal {
        require(stake >= MIN_STAKE, "Stake too small");
        require(
            selection == Outcome.Home ||
            selection == Outcome.Draw ||
            selection == Outcome.Away,
            "Invalid selection"
        );

        uint256 idx1 = matchIdToIndex[matchId];
        require(idx1 != 0, "Match not registered");
        uint32 matchIndex = uint32(idx1 - 1);

        Match storage m = matches[matchIndex];
        require(!m.resolved && !m.cancelled, "Match finalised");
        require(block.timestamp < m.commenceTime, "Betting closed");

        uint256 collateral = stake * leverage;

        // Pull collateral from bettor
        require(
            cUSD.transferFrom(msg.sender, address(this), collateral),
            "Transfer failed"
        );

        // Add to pool
        if      (selection == Outcome.Home) m.poolHome += collateral;
        else if (selection == Outcome.Draw) m.poolDraw += collateral;
        else                                m.poolAway += collateral;
        m.totalPool += collateral;

        uint256 betIndex = bets.length;
        bets.push(Bet({
            bettor:     msg.sender,
            matchIndex: matchIndex,
            selection:  selection,
            stake:      stake,
            collateral: collateral,
            leverage:   leverage,
            claimed:    false
        }));

        userBets[msg.sender].push(betIndex);
        emit BetPlaced(betIndex, msg.sender, matchIndex, selection, collateral, leverage);
    }

    // ════════════════════════════════════════════════════════════
    //  USER — Claim winnings / refunds
    // ════════════════════════════════════════════════════════════

    /**
     * @notice Claim winnings for a won bet.
     *         Payout = (your collateral / winning-side pool) × total pool × (1 - fee)
     */
    function claimWinnings(uint256 betIndex) external {
        Bet storage bet = bets[betIndex];
        require(bet.bettor == msg.sender, "Not your bet");
        require(!bet.claimed, "Already claimed");

        Match storage m = matches[bet.matchIndex];
        require(m.resolved, "Not resolved yet");
        require(bet.selection == m.result, "Bet lost");

        uint256 winningPool = _winningPool(m);
        require(winningPool > 0, "Empty winning pool");

        // Proportional share of total pool, minus platform fee
        uint256 grossPayout = (bet.collateral * m.totalPool) / winningPool;
        uint256 fee         = (grossPayout * PLATFORM_FEE_BPS) / 10_000;
        uint256 netPayout   = grossPayout - fee;

        collectedFees += fee;
        bet.claimed = true;

        require(cUSD.transfer(msg.sender, netPayout), "Transfer failed");
        emit WinningsClaimed(betIndex, msg.sender, netPayout);
    }

    /**
     * @notice Claim a full refund for a bet on a cancelled match.
     */
    function claimRefund(uint256 betIndex) external {
        Bet storage bet = bets[betIndex];
        require(bet.bettor == msg.sender, "Not your bet");
        require(!bet.claimed, "Already claimed");

        Match storage m = matches[bet.matchIndex];
        require(m.cancelled, "Match not cancelled");

        bet.claimed = true;
        require(cUSD.transfer(msg.sender, bet.collateral), "Transfer failed");
        emit RefundClaimed(betIndex, msg.sender, bet.collateral);
    }

    // ════════════════════════════════════════════════════════════
    //  ADMIN — Fee withdrawal
    // ════════════════════════════════════════════════════════════

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = collectedFees;
        require(amount > 0, "Nothing to withdraw");
        collectedFees = 0;
        require(cUSD.transfer(to, amount), "Transfer failed");
        emit FeeWithdrawn(to, amount);
    }

    // ════════════════════════════════════════════════════════════
    //  WAITLIST
    // ════════════════════════════════════════════════════════════

    /**
     * @notice Join the platform waitlist. One entry per wallet.
     * @param email        Optional e-mail string (stored on-chain; keep privacy in mind).
     *                     Pass "" to omit.
     * @param referralCode Optional referral code from an existing user.
     */
    function joinWaitlist(string calldata email, string calldata referralCode) external {
        require(waitlistSlot[msg.sender] == 0, "Already on waitlist");

        uint256 slot = waitlist.length + 1; // 1-indexed
        waitlist.push(WaitlistEntry({
            wallet:       msg.sender,
            email:        email,
            referralCode: referralCode,
            registeredAt: block.timestamp
        }));

        waitlistSlot[msg.sender] = slot;
        emit WaitlistJoined(msg.sender, slot, referralCode);
    }

    /// @notice Returns true if the caller is on the waitlist.
    function isOnWaitlist(address wallet) external view returns (bool) {
        return waitlistSlot[wallet] != 0;
    }

    /// @notice Returns the waitlist position (1-indexed) for a wallet.
    function getWaitlistPosition(address wallet) external view returns (uint256) {
        return waitlistSlot[wallet];
    }

    /// @notice Total number of waitlist entries.
    function waitlistCount() external view returns (uint256) {
        return waitlist.length;
    }

    // ════════════════════════════════════════════════════════════
    //  READ HELPERS
    // ════════════════════════════════════════════════════════════

    /// @notice Returns all on-chain match indices and their matchIds.
    function getMatchCount() external view returns (uint256) {
        return matches.length;
    }

    /// @notice Returns pool data for a match by its TheOddsAPI matchId.
    function getPoolByMatchId(string calldata matchId)
        external view
        returns (uint256 home, uint256 draw, uint256 away, uint256 total)
    {
        uint256 idx1 = matchIdToIndex[matchId];
        require(idx1 != 0, "Not registered");
        Match storage m = matches[idx1 - 1];
        return (m.poolHome, m.poolDraw, m.poolAway, m.totalPool);
    }

    /// @notice Returns all bet indices for a given bettor.
    function getUserBetIndices(address bettor) external view returns (uint256[] memory) {
        return userBets[bettor];
    }

    /// @notice Returns full bet data for a given index.
    function getBet(uint256 betIndex)
        external view
        returns (
            address bettor,
            uint32  matchIndex,
            Outcome selection,
            uint256 stake,
            uint256 collateral,
            uint8   leverage,
            bool    claimed
        )
    {
        Bet storage b = bets[betIndex];
        return (b.bettor, b.matchIndex, b.selection, b.stake, b.collateral, b.leverage, b.claimed);
    }

    /// @notice Returns match struct fields (split to avoid stack-too-deep).
    function getMatch(uint32 idx)
        external view
        returns (
            string memory matchId,
            string memory description,
            uint256 commenceTime,
            Outcome result,
            bool resolved,
            bool cancelled,
            uint256 poolHome,
            uint256 poolDraw,
            uint256 poolAway,
            uint256 totalPool
        )
    {
        Match storage m = matches[idx];
        return (
            m.matchId, m.description, m.commenceTime,
            m.result, m.resolved, m.cancelled,
            m.poolHome, m.poolDraw, m.poolAway, m.totalPool
        );
    }

    // ────────────────────────────────────────────────────────────
    //  Internal helpers
    // ────────────────────────────────────────────────────────────

    function _winningPool(Match storage m) internal view returns (uint256) {
        if (m.result == Outcome.Home) return m.poolHome;
        if (m.result == Outcome.Draw) return m.poolDraw;
        return m.poolAway;
    }
}
