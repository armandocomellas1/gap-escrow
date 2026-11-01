// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  GAPEscrow
 * @notice Escrow de apuestas 1v1 para GAP (Gaming Access Portal) en BNB Smart Chain.
 *
 *  FLUJO
 *  ─────
 *   1. createMatch  : el creador deposita X BNB              -> ABIERTA.
 *   2. joinMatch    : el rival deposita la MISMA X BNB       -> LLENA (bote = 2X).
 *   3. submitResult : durante 4h cada jugador reporta Win / Lose / Draw.
 *        · "Perdí" -> concesión inequívoca: liquida AL INSTANTE a favor del rival
 *          (inmediata para que no pueda retractarse abriendo una disputa después).
 *        · Draw + Draw -> reembolsa 100% a cada uno (sin comisión).
 *        · Cualquier otra combinación (Win+Win, Win+Draw) -> DISPUTA.
 *   4. openDispute  : cualquier jugador puede escalar a disputa dentro de esas 4h.
 *   5. escalateUnreported : pasadas las 4h con UN solo reporte, ese reporte NO se
 *        auto-paga. Tanto un "Gané" como un "Empate" solitarios FAVORECEN a quien los
 *        firma, así que ambos pasan a disputa y los arbitra el operador con evidencia.
 *        (Un "Perdí" nunca llega aquí: ya se liquidó al instante.)
 *   6. resolveDispute (operador): decide ganador o empate, con hash de evidencia.
 *   7. withdraw     : cada quien retira su saldo (patrón "pull", seguro).
 *
 *  TIEMPOS (el dinero NUNCA queda atrapado)
 *  ────────────────────────────────────────
 *   · Cancelar: el creador puede cancelar mientras nadie se una.
 *   · Reporte : 4h desde que se llena para reportar o disputar.
 *   · Sin corroborar: tras 4h, un reporte solitario pasa a disputa.
 *   · Disputa : pasadas 4h sin resolver, CUALQUIERA puede reclamar el reembolso 100%
 *     a ambos; si nadie lo reclama, el operador todavía puede resolver.
 *   · Abandono: si NADIE reportó ni disputó, tras 8h cualquiera dispara el
 *     reembolso a ambos.
 *
 *  SEGURIDAD
 *  ─────────
 *   · Los pagos usan un libro de saldos interno (credits) + withdraw() con guardia
 *     anti-reentrancy. withdraw()/withdrawFees() son las UNICAS que envían BNB.
 *   · El owner controla comisión, operador, pausa y reembolsos de emergencia, pero
 *     NO puede enviarse a sí mismo las apuestas activas: solo retira comisiones
 *     acumuladas (feesAccrued). El escrow de los jugadores es intocable para él.
 *   · El operador solo puede pagar al creador o al rival de una disputa (o empate);
 *     jamás a una dirección arbitraria.
 */
contract GAPEscrow {
    // ───────────────────────── Roles & configuración ─────────────────────────
    address public owner;        // admin: comisión, operador, pausa, emergencias
    address public pendingOwner; // traspaso de owner en dos pasos (evita perderlo por un typo)
    address public operator;     // resuelve disputas (wallet backend / treasury de GAP)
    bool    public paused;    // congela creación/unión de partidas y el reporte de resultados
    uint64  public pausedAt;  // cuándo se pausó (arranca el retardo de emergencia)

    uint16 public feeBps;                        // comisión actual (basis points; 100 = 1%)
    uint16 public constant MAX_FEE_BPS = 1000;   // TOPE inmutable = 10%
    uint256 public constant REPORT_WINDOW  = 4 hours; // plazo para reportar tras llenarse
    uint256 public constant DISPUTE_WINDOW = 4 hours; // plazo del operador para resolver
    uint256 public constant EMERGENCY_DELAY = 24 hours; // espera tras pausar antes de rescatar

    // ───────────────────────────── Contabilidad ──────────────────────────────
    mapping(address => uint256) public credits; // saldo retirable de cada usuario
    uint256 public feesAccrued;                  // comisiones del owner (separadas del escrow)

    // ─────────────────────────── Modelo de datos ─────────────────────────────
    enum Outcome { None, Win, Lose, Draw }
    enum Status  { None, Open, Full, Disputed, Settled, Refunded }

    struct Match {
        address creator;
        address joiner;
        uint256 betAmount;     // por jugador; bote = 2 * betAmount
        uint16  feeBps;        // comisión fijada al crear (no cambia en vuelo)
        uint64  createdAt;
        uint64  filledAt;      // inicia el reloj de reporte
        uint64  disputedAt;    // inicia el reloj de disputa
        Outcome creatorReport;
        Outcome joinerReport;
        Status  status;
        address winner;        // set al liquidar (address(0) = empate)
        string  gameId;
        string  referralId;
    }

    uint256 public matchCount;
    mapping(uint256 => Match) private _matches;
    mapping(address => uint256[]) private _userMatchIds; // para "My Matches"

    // ───────────────────────────────  Eventos  ───────────────────────────────
    event MatchCreated(uint256 indexed id, address indexed creator, uint256 betAmount, string gameId, string referralId);
    event MatchCancelled(uint256 indexed id);
    event MatchJoined(uint256 indexed id, address indexed joiner);
    event ResultSubmitted(uint256 indexed id, address indexed player, Outcome outcome);
    event MatchSettled(uint256 indexed id, address indexed winner, uint256 payout, uint256 fee);
    event MatchRefunded(uint256 indexed id, string reason);
    event DisputeOpened(uint256 indexed id, address indexed by);
    event DisputeResolved(uint256 indexed id, address indexed winner, bytes32 evidenceHash); // winner == 0 => empate
    event Withdrawal(address indexed account, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event OperatorUpdated(address indexed operator);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);

    // ──────────────────────────────  Modifiers  ──────────────────────────────
    uint256 private _lock = 1;
    modifier nonReentrant() {
        require(_lock == 1, "reentrant");
        _lock = 2;
        _;
        _lock = 1;
    }
    modifier onlyOwner()    { require(msg.sender == owner, "not owner"); _; }
    modifier onlyOperator() { require(msg.sender == operator, "not operator"); _; }
    modifier whenNotPaused(){ require(!paused, "paused"); _; }
    modifier validMatch(uint256 id) { require(id != 0 && id <= matchCount, "bad id"); _; }

    // ─────────────────────────────  Constructor  ─────────────────────────────
    constructor(address _operator, uint16 _feeBps) {
        require(_operator != address(0), "operator=0");
        require(_feeBps <= MAX_FEE_BPS, "fee>max");
        owner = msg.sender;
        operator = _operator;
        feeBps = _feeBps;
        emit OwnershipTransferred(address(0), msg.sender);
        emit OperatorUpdated(_operator);
        emit FeeUpdated(_feeBps);
    }

    // ═══════════════════════════════  Jugadores  ═════════════════════════════

    /// @notice Crea una partida y deposita la apuesta (el monto es msg.value).
    function createMatch(string calldata gameId, string calldata referralId)
        external
        payable
        whenNotPaused
        returns (uint256 id)
    {
        require(msg.value > 0, "bet=0");
        require(bytes(gameId).length != 0, "gameId empty");

        id = ++matchCount;
        Match storage m = _matches[id];
        m.creator    = msg.sender;
        m.betAmount  = msg.value;
        m.feeBps     = feeBps;                 // se congela la comisión vigente
        m.createdAt  = uint64(block.timestamp);
        m.status     = Status.Open;
        m.gameId     = gameId;
        m.referralId = referralId;

        _userMatchIds[msg.sender].push(id);
        emit MatchCreated(id, msg.sender, msg.value, gameId, referralId);
    }

    /// @notice El creador cancela y recupera su BNB, solo mientras nadie se haya unido.
    function cancelMatch(uint256 id) external validMatch(id) {
        Match storage m = _matches[id];
        require(m.status == Status.Open, "not open");
        require(msg.sender == m.creator, "not creator");

        m.status = Status.Refunded;
        credits[m.creator] += m.betAmount;
        emit MatchCancelled(id);
        emit MatchRefunded(id, "cancelled");
    }

    /// @notice Un rival se une depositando EXACTAMENTE la misma apuesta.
    function joinMatch(uint256 id) external payable whenNotPaused validMatch(id) {
        Match storage m = _matches[id];
        require(m.status == Status.Open, "not open");
        require(msg.sender != m.creator, "own match");
        require(msg.value == m.betAmount, "bet mismatch");

        m.joiner   = msg.sender;
        m.filledAt = uint64(block.timestamp);
        m.status   = Status.Full;

        _userMatchIds[msg.sender].push(id);
        emit MatchJoined(id, msg.sender);
    }

    /// @notice Cada jugador reporta su resultado. Al reportar ambos, se liquida solo.
    function submitResult(uint256 id, Outcome outcome) external whenNotPaused validMatch(id) {
        require(
            outcome == Outcome.Win || outcome == Outcome.Lose || outcome == Outcome.Draw,
            "bad outcome"
        );
        Match storage m = _matches[id];
        require(m.status == Status.Full, "not reporting phase");
        require(block.timestamp < uint256(m.filledAt) + REPORT_WINDOW, "report window closed");

        if (msg.sender == m.creator) {
            require(m.creatorReport == Outcome.None, "already reported");
            m.creatorReport = outcome;
        } else if (msg.sender == m.joiner) {
            require(m.joinerReport == Outcome.None, "already reported");
            m.joinerReport = outcome;
        } else {
            revert("not a player");
        }
        emit ResultSubmitted(id, msg.sender, outcome);

        // Declararse perdedor es una concesión inequívoca: se liquida AL INSTANTE, así
        // nadie puede retractarse después abriendo una disputa para forzar el reembolso.
        if (outcome == Outcome.Lose) {
            _settleWin(id, m, msg.sender == m.creator ? m.joiner : m.creator);
            return;
        }

        if (m.creatorReport != Outcome.None && m.joinerReport != Outcome.None) {
            _resolveReports(id, m);
        }
    }

    /// @notice Cualquier jugador puede abrir disputa mientras la partida siga llena.
    function openDispute(uint256 id) external validMatch(id) {
        Match storage m = _matches[id];
        require(m.status == Status.Full, "not disputable");
        require(block.timestamp < uint256(m.filledAt) + REPORT_WINDOW, "report window closed");
        require(msg.sender == m.creator || msg.sender == m.joiner, "not a player");
        // Hay que mojarse antes de escalar: sin un reporte propio firmado no puedes
        // disputar, así el silencio deja de ser una vía de escape gratuita.
        require(
            msg.sender == m.creator
                ? m.creatorReport != Outcome.None
                : m.joinerReport != Outcome.None,
            "report first"
        );

        m.status = Status.Disputed;
        m.disputedAt = uint64(block.timestamp);
        emit DisputeOpened(id, msg.sender);
    }

    /// @notice Pasadas las 4h con un solo reporte, ese reporte NO se auto-paga: tanto un
    ///         "Gané" como un "Empate" solitarios favorecen a quien los firma, así que
    ///         los arbitra el operador con evidencia. (Un "Perdí" nunca llega aquí: se
    ///         liquidó al instante en submitResult.) Cualquiera puede llamarla; el
    ///         resultado no depende de quién la llame.
    function escalateUnreported(uint256 id) external validMatch(id) {
        Match storage m = _matches[id];
        require(m.status == Status.Full, "not full");
        require(block.timestamp >= uint256(m.filledAt) + REPORT_WINDOW, "report window open");
        require(
            (m.creatorReport == Outcome.None) != (m.joinerReport == Outcome.None),
            "not single report"
        );

        m.status = Status.Disputed;
        m.disputedAt = uint64(block.timestamp);
        emit DisputeOpened(id, msg.sender);
    }

    // ═══════════════════════════════  Operador  ══════════════════════════════

    /// @notice El operador resuelve una disputa: winner = creador o rival, o 0 = empate.
    function resolveDispute(uint256 id, address winner, bytes32 evidenceHash)
        external
        onlyOperator
        validMatch(id)
    {
        Match storage m = _matches[id];
        require(m.status == Status.Disputed, "not disputed");
        // El árbitro no puede arbitrar una partida en la que él mismo juega.
        require(msg.sender != m.creator && msg.sender != m.joiner, "operator is player");

        if (winner == address(0)) {
            _settleDraw(id, m, "dispute-draw");
        } else {
            require(winner == m.creator || winner == m.joiner, "winner not player");
            _settleWin(id, m, winner);
        }
        emit DisputeResolved(id, winner, evidenceHash);
    }

    // ═════════════════════════════  Redes de seguridad  ══════════════════════

    /// @notice Reembolso por timeout. Cualquiera puede llamarlo cuando aplica:
    ///  · Disputa sin resolver 4h despues de abrirse  -> reembolso a ambos.
    ///  · Partida llena y abandonada por completo (4h reporte + 4h disputa) -> reembolso.
    function refundExpired(uint256 id) external validMatch(id) {
        Match storage m = _matches[id];

        if (m.status == Status.Disputed) {
            require(block.timestamp >= uint256(m.disputedAt) + DISPUTE_WINDOW, "dispute window open");
            _settleDraw(id, m, "dispute-timeout");
        } else if (m.status == Status.Full) {
            // Solo aplica si NADIE reportó; si uno reportó, se usa settleUnreported.
            require(
                m.creatorReport == Outcome.None && m.joinerReport == Outcome.None,
                "use escalateUnreported"
            );
            require(
                block.timestamp >= uint256(m.filledAt) + REPORT_WINDOW + DISPUTE_WINDOW,
                "not expired"
            );
            _settleDraw(id, m, "abandoned");
        } else {
            revert("not refundable");
        }
    }

    // ═══════════════════════════════  Retiros  ═══════════════════════════════

    /// @notice Retira todo tu saldo acumulado (premios y reembolsos).
    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        require(amount != 0, "no balance");
        credits[msg.sender] = 0;                       // efecto antes de la interacción
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    // ════════════════════════════════  Owner  ════════════════════════════════

    /// @notice Retira comisiones acumuladas (dinero de GAP). NO toca el escrow.
    function withdrawFees(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        require(amount <= feesAccrued, "exceeds fees");
        feesAccrued -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "transfer failed");
        emit FeesWithdrawn(to, amount);
    }

    /// @notice Reembolso de emergencia de UNA partida. El dinero vuelve SIEMPRE a los
    ///         jugadores (creador/rival), nunca al owner. Válvula de rescate segura.
    function emergencyRefund(uint256 id) external onlyOwner validMatch(id) {
        // Válvula de rescate, no un veto: exige el contrato pausado Y 24h de espera, de
        // modo que la emergencia sea pública y observable, nunca atómica. Mientras tanto
        // los jugadores pueden seguir cancelando, cobrando y reclamando reembolsos.
        require(paused, "pause first");
        require(block.timestamp >= uint256(pausedAt) + EMERGENCY_DELAY, "emergency delay");
        Match storage m = _matches[id];
        if (m.status == Status.Open) {
            m.status = Status.Refunded;
            credits[m.creator] += m.betAmount;         // solo el creador había depositado
            emit MatchRefunded(id, "emergency");
        } else if (m.status == Status.Full || m.status == Status.Disputed) {
            _settleDraw(id, m, "emergency");
        } else {
            revert("already closed");
        }
    }

    function setFee(uint16 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "fee>max");
        feeBps = _feeBps;
        emit FeeUpdated(_feeBps);
    }

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "operator=0");
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    /// @notice Traspaso de owner en DOS pasos: un typo aquí ya no te deja fuera del
    ///         contrato para siempre, porque el destinatario debe aceptar.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner=0");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setPaused(bool _paused) external onlyOwner {
        if (_paused && !paused) pausedAt = uint64(block.timestamp); // no reinicia el reloj
        if (!_paused) pausedAt = 0;
        paused = _paused;
        emit PausedSet(_paused);
    }

    // ═════════════════════════════  Liquidación  ═════════════════════════════

    /// @dev Los "Perdí" ya se liquidaron al instante en submitResult, así que aquí solo
    ///      llegan combinaciones de Win/Draw (ambos reportes auto-favorables).
    function _resolveReports(uint256 id, Match storage m) private {
        if (m.creatorReport == Outcome.Draw && m.joinerReport == Outcome.Draw) {
            _settleDraw(id, m, "draw");
        } else {
            // Ambos reclaman algo que les favorece -> alguien miente -> disputa.
            m.status = Status.Disputed;
            m.disputedAt = uint64(block.timestamp);
            emit DisputeOpened(id, msg.sender);
        }
    }

    function _settleWin(uint256 id, Match storage m, address winner) private {
        uint256 pot    = m.betAmount * 2;
        uint256 fee    = (pot * m.feeBps) / 10_000;
        uint256 payout = pot - fee;

        m.winner = winner;
        m.status = Status.Settled;
        if (fee != 0) feesAccrued += fee;
        credits[winner] += payout;
        emit MatchSettled(id, winner, payout, fee);
    }

    function _settleDraw(uint256 id, Match storage m, string memory reason) private {
        m.status = Status.Refunded;
        credits[m.creator] += m.betAmount;
        credits[m.joiner]  += m.betAmount;
        emit MatchRefunded(id, reason);
    }

    // ═══════════════════════════════  Lecturas  ══════════════════════════════

    function getMatch(uint256 id) external view returns (Match memory) {
        return _matches[id];
    }

    function getUserMatchIds(address user) external view returns (uint256[] memory) {
        return _userMatchIds[user];
    }

    /// @notice Página de partidas (ids 1..matchCount). El frontend filtra ABIERTAS
    ///         para "Join" y por participante para "My Matches".
    function getMatches(uint256 offset, uint256 limit) external view returns (Match[] memory page) {
        if (offset >= matchCount) return new Match[](0);
        uint256 end = offset + limit;
        if (end > matchCount) end = matchCount;
        page = new Match[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _matches[i + 1]; // ids son 1-based
        }
    }
}
