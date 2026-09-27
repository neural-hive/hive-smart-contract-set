// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IHIVE {
    function mint(
        address to,
        uint256 amount
    ) external;

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract HIVESale is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================
    // Payment tokens
    // =========================================================

    IHIVE public immutable hive;

    IERC20 public immutable usdt;

    IERC20 public immutable fdusd;

    uint8 public immutable usdtDecimals;

    uint8 public immutable fdusdDecimals;

    // =========================================================
    // Exchange rates
    // =========================================================

    /*
     * HIVE received for 1 BNB.
     *
     * Example:
     *
     * bnbRate = 100_000 ether
     *
     * means:
     *
     * 1 BNB = 100,000 HIVE
     */
    uint256 public bnbRate;

    /*
     * HIVE received for 1 USDT.
     *
     * Example:
     *
     * usdtRate = 2_000 ether
     *
     * means:
     *
     * 1 USDT = 2,000 HIVE
     */
    uint256 public usdtRate;

    /*
     * HIVE received for 1 FDUSD.
     *
     * Example:
     *
     * fdusdRate = 2_000 ether
     *
     * means:
     *
     * 1 FDUSD = 2,000 HIVE
     */
    uint256 public fdusdRate;

    // =========================================================
    // Payment switches
    // =========================================================

    bool public bnbEnabled;
    bool public usdtEnabled;
    bool public fdusdEnabled;

    // =========================================================
    // Refund switch
    // =========================================================

    /*
     * Only the owner can change this.
     *
     * false:
     *      refund() cannot be used.
     *
     * true:
     *      eligible contributors can refund their
     *      individual contributions.
     */
    bool public refundEnabled;

    // =========================================================
    // Contribution tracking
    // =========================================================

    enum PaymentType {
        BNB,
        USDT,
        FDUSD
    }

    struct Contribution {
        address buyer;

        PaymentType paymentType;

        uint256 paymentAmount;

        uint256 hiveAmount;

        uint256 timestamp;

        bool refunded;
    }

    /*
     * Every contribution is stored separately.
     *
     * Example:
     *
     * Alice pays 1 BNB
     * Alice pays 10 USDT
     * Alice pays another 5 USDT
     *
     * These become three separate Contribution records.
     */
    Contribution[] private contributions;

    /*
     * Contribution IDs belonging to each buyer.
     */
    mapping(address => uint256[]) private buyerContributionIds;

    // =========================================================
    // Events
    // =========================================================

    event BnbRateUpdated(
        uint256 oldRate,
        uint256 newRate
    );

    event UsdtRateUpdated(
        uint256 oldRate,
        uint256 newRate
    );

    event FdusdRateUpdated(
        uint256 oldRate,
        uint256 newRate
    );

    event BnbEnabledUpdated(
        bool enabled
    );

    event UsdtEnabledUpdated(
        bool enabled
    );

    event FdusdEnabledUpdated(
        bool enabled
    );

    event RefundEnabledUpdated(
        bool enabled
    );

    event HivePurchasedWithBNB(
        address indexed buyer,
        uint256 indexed contributionId,
        uint256 bnbPaid,
        uint256 hiveReceived
    );

    event HivePurchasedWithUSDT(
        address indexed buyer,
        uint256 indexed contributionId,
        uint256 usdtPaid,
        uint256 hiveReceived
    );

    event HivePurchasedWithFDUSD(
        address indexed buyer,
        uint256 indexed contributionId,
        uint256 fdusdPaid,
        uint256 hiveReceived
    );

    event ContributionRefunded(
        address indexed buyer,
        uint256 indexed contributionId,
        PaymentType paymentType,
        uint256 paymentAmount,
        uint256 hiveReturned
    );

    event BnbWithdrawn(
        address indexed to,
        uint256 amount
    );

    event TokenWithdrawn(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // =========================================================
    // Errors
    // =========================================================

    error ZeroAddress();

    error InvalidRate();

    error ZeroPayment();

    error PaymentDisabled();

    error InvalidToken();

    error TransferFailed();

    error RefundDisabled();

    error InvalidContribution();

    error NotContributionOwner();

    error AlreadyRefunded();

    error InsufficientRefundBalance();

    error InvalidHiveAmount();

    // =========================================================
    // Constructor
    // =========================================================

    constructor(
        address initialOwner,
        address hiveAddress,
        address usdtAddress,
        address fdusdAddress,
        uint256 initialBnbRate,
        uint256 initialUsdtRate,
        uint256 initialFdusdRate
    )
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) ||
            hiveAddress == address(0) ||
            usdtAddress == address(0) ||
            fdusdAddress == address(0)
        ) {
            revert ZeroAddress();
        }

        if (
            initialBnbRate == 0 ||
            initialUsdtRate == 0 ||
            initialFdusdRate == 0
        ) {
            revert InvalidRate();
        }

        hive = IHIVE(hiveAddress);

        usdt = IERC20(usdtAddress);

        fdusd = IERC20(fdusdAddress);

        usdtDecimals = _getDecimals(usdtAddress);

        fdusdDecimals = _getDecimals(fdusdAddress);

        bnbRate = initialBnbRate;

        usdtRate = initialUsdtRate;

        fdusdRate = initialFdusdRate;

        bnbEnabled = true;
        usdtEnabled = true;
        fdusdEnabled = true;

        /*
         * Refunds start disabled.
         *
         * Owner explicitly enables them later.
         */
        refundEnabled = false;
    }

    // =========================================================
    // Buy with BNB
    // =========================================================

    function buyWithBNB()
        external
        payable
        nonReentrant
    {
        if (!bnbEnabled) {
            revert PaymentDisabled();
        }

        if (msg.value == 0) {
            revert ZeroPayment();
        }

        uint256 hiveAmount =
            (msg.value * bnbRate) / 1 ether;

        if (hiveAmount == 0) {
            revert InvalidHiveAmount();
        }

        /*
         * Record contribution BEFORE minting.
         *
         * If mint() reverts, the entire transaction reverts,
         * including this storage change.
         */
        uint256 contributionId = contributions.length;

        contributions.push(
            Contribution({
                buyer: msg.sender,
                paymentType: PaymentType.BNB,
                paymentAmount: msg.value,
                hiveAmount: hiveAmount,
                timestamp: block.timestamp,
                refunded: false
            })
        );

        buyerContributionIds[msg.sender].push(
            contributionId
        );

        hive.mint(
            msg.sender,
            hiveAmount
        );

        emit HivePurchasedWithBNB(
            msg.sender,
            contributionId,
            msg.value,
            hiveAmount
        );
    }

    // =========================================================
    // Buy with USDT
    // =========================================================

    function buyWithUSDT(
        uint256 usdtAmount
    )
        external
        nonReentrant
    {
        if (!usdtEnabled) {
            revert PaymentDisabled();
        }

        if (usdtAmount == 0) {
            revert ZeroPayment();
        }

        uint256 hiveAmount =
            _calculateTokenAmount(
                usdtAmount,
                usdtDecimals,
                usdtRate
            );

        if (hiveAmount == 0) {
            revert InvalidHiveAmount();
        }

        /*
         * Pull USDT from buyer.
         *
         * Therefore the buyer must approve this sale
         * contract to spend USDT first.
         */
        usdt.safeTransferFrom(
            msg.sender,
            address(this),
            usdtAmount
        );

        uint256 contributionId = contributions.length;

        contributions.push(
            Contribution({
                buyer: msg.sender,
                paymentType: PaymentType.USDT,
                paymentAmount: usdtAmount,
                hiveAmount: hiveAmount,
                timestamp: block.timestamp,
                refunded: false
            })
        );

        buyerContributionIds[msg.sender].push(
            contributionId
        );

        /*
         * If minting fails, the entire transaction reverts,
         * including the USDT transfer and contribution record.
         */
        hive.mint(
            msg.sender,
            hiveAmount
        );

        emit HivePurchasedWithUSDT(
            msg.sender,
            contributionId,
            usdtAmount,
            hiveAmount
        );
    }

    // =========================================================
    // Buy with FDUSD
    // =========================================================

    function buyWithFDUSD(
        uint256 fdusdAmount
    )
        external
        nonReentrant
    {
        if (!fdusdEnabled) {
            revert PaymentDisabled();
        }

        if (fdusdAmount == 0) {
            revert ZeroPayment();
        }

        uint256 hiveAmount =
            _calculateTokenAmount(
                fdusdAmount,
                fdusdDecimals,
                fdusdRate
            );

        if (hiveAmount == 0) {
            revert InvalidHiveAmount();
        }

        /*
         * Pull FDUSD from buyer.
         *
         * Buyer must approve this sale contract first.
         */
        fdusd.safeTransferFrom(
            msg.sender,
            address(this),
            fdusdAmount
        );

        uint256 contributionId = contributions.length;

        contributions.push(
            Contribution({
                buyer: msg.sender,
                paymentType: PaymentType.FDUSD,
                paymentAmount: fdusdAmount,
                hiveAmount: hiveAmount,
                timestamp: block.timestamp,
                refunded: false
            })
        );

        buyerContributionIds[msg.sender].push(
            contributionId
        );

        hive.mint(
            msg.sender,
            hiveAmount
        );

        emit HivePurchasedWithFDUSD(
            msg.sender,
            contributionId,
            fdusdAmount,
            hiveAmount
        );
    }

    // =========================================================
    // Refund control
    // =========================================================

    /*
     * ONLY OWNER.
     *
     * The owner can turn the refund system on or off.
     */
    function setRefundEnabled(
        bool enabled
    )
        external
        onlyOwner
    {
        refundEnabled = enabled;

        emit RefundEnabledUpdated(enabled);
    }

    // =========================================================
    // Refund
    // =========================================================

    /*
     * Refund one specific contribution.
     *
     * IMPORTANT:
     *
     * The refund amount is NOT calculated using the current
     * exchange rate.
     *
     * The exact original paymentAmount is returned.
     *
     * Example:
     *
     * Alice:
     *
     * pays 10 USDT
     * receives 20,000 HIVE
     *
     * Later owner changes rate.
     *
     * Refund:
     *
     * Alice returns 20,000 HIVE
     * Alice receives exactly 10 USDT
     */
    function refund(
        uint256 contributionId
    )
        external
        nonReentrant
    {
        if (!refundEnabled) {
            revert RefundDisabled();
        }

        if (contributionId >= contributions.length) {
            revert InvalidContribution();
        }

        Contribution storage contribution =
            contributions[contributionId];

        if (contribution.buyer != msg.sender) {
            revert NotContributionOwner();
        }

        if (contribution.refunded) {
            revert AlreadyRefunded();
        }

        /*
         * Mark refunded BEFORE external calls.
         *
         * ReentrancyGuard is also active, giving us another
         * layer of protection.
         */
        contribution.refunded = true;

        /*
         * First take the exact HIVE amount back from the buyer.
         *
         * Therefore the buyer must approve this sale contract
         * to spend the required HIVE amount.
         */
        bool hiveTransferSuccess =
            hive.transferFrom(
                msg.sender,
                address(this),
                contribution.hiveAmount
            );

        if (!hiveTransferSuccess) {
            revert TransferFailed();
        }

        // -----------------------------------------------------
        // Refund original payment
        // -----------------------------------------------------

        if (contribution.paymentType == PaymentType.BNB) {

            uint256 amount = contribution.paymentAmount;

            if (address(this).balance < amount) {
                revert InsufficientRefundBalance();
            }

            (bool success, ) =
                payable(msg.sender).call{value: amount}("");

            if (!success) {
                revert TransferFailed();
            }

        } else if (
            contribution.paymentType == PaymentType.USDT
        ) {

            uint256 amount = contribution.paymentAmount;

            if (
                usdt.balanceOf(address(this)) < amount
            ) {
                revert InsufficientRefundBalance();
            }

            usdt.safeTransfer(
                msg.sender,
                amount
            );

        } else if (
            contribution.paymentType == PaymentType.FDUSD
        ) {

            uint256 amount = contribution.paymentAmount;

            if (
                fdusd.balanceOf(address(this)) < amount
            ) {
                revert InsufficientRefundBalance();
            }

            fdusd.safeTransfer(
                msg.sender,
                amount
            );

        } else {
            revert InvalidToken();
        }

        emit ContributionRefunded(
            msg.sender,
            contributionId,
            contribution.paymentType,
            contribution.paymentAmount,
            contribution.hiveAmount
        );
    }

    // =========================================================
    // Contribution views
    // =========================================================

    /*
     * Total number of contributions ever made.
     */
    function contributionCount()
        external
        view
        returns (uint256)
    {
        return contributions.length;
    }

    /*
     * Get a single contribution.
     */
    function getContribution(
        uint256 contributionId
    )
        external
        view
        returns (Contribution memory)
    {
        if (contributionId >= contributions.length) {
            revert InvalidContribution();
        }

        return contributions[contributionId];
    }

    /*
     * Get all contribution IDs belonging to an address.
     *
     * The frontend can then call getContribution() for each ID.
     */
    function getBuyerContributionIds(
        address buyer
    )
        external
        view
        returns (uint256[] memory)
    {
        return buyerContributionIds[buyer];
    }

    /*
     * Get the latest `count` contributions.
     *
     * For your frontend you can call:
     *
     * recentContributions(5)
     *
     * to get the most recent five.
     *
     * If fewer than `count` exist, it returns all available
     * contributions.
     */
    function recentContributions(
        uint256 count
    )
        external
        view
        returns (Contribution[] memory result)
    {
        uint256 total = contributions.length;

        if (count > total) {
            count = total;
        }

        result = new Contribution[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] =
                contributions[total - 1 - i];
        }
    }

    /*
     * Returns the contribution IDs of the most recent
     * contributions.
     *
     * This can be cheaper than returning full structs if the
     * frontend only needs IDs first.
     */
    function recentContributionIds(
        uint256 count
    )
        external
        view
        returns (uint256[] memory result)
    {
        uint256 total = contributions.length;

        if (count > total) {
            count = total;
        }

        result = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = total - 1 - i;
        }
    }

    // =========================================================
    // Rate management
    // =========================================================

    function setBnbRate(
        uint256 newRate
    )
        external
        onlyOwner
    {
        if (newRate == 0) {
            revert InvalidRate();
        }

        uint256 oldRate = bnbRate;

        bnbRate = newRate;

        emit BnbRateUpdated(
            oldRate,
            newRate
        );
    }

    function setUsdtRate(
        uint256 newRate
    )
        external
        onlyOwner
    {
        if (newRate == 0) {
            revert InvalidRate();
        }

        uint256 oldRate = usdtRate;

        usdtRate = newRate;

        emit UsdtRateUpdated(
            oldRate,
            newRate
        );
    }

    function setFdusdRate(
        uint256 newRate
    )
        external
        onlyOwner
    {
        if (newRate == 0) {
            revert InvalidRate();
        }

        uint256 oldRate = fdusdRate;

        fdusdRate = newRate;

        emit FdusdRateUpdated(
            oldRate,
            newRate
        );
    }

    // =========================================================
    // Enable / disable payment methods
    // =========================================================

    function setBnbEnabled(
        bool enabled
    )
        external
        onlyOwner
    {
        bnbEnabled = enabled;

        emit BnbEnabledUpdated(enabled);
    }

    function setUsdtEnabled(
        bool enabled
    )
        external
        onlyOwner
    {
        usdtEnabled = enabled;

        emit UsdtEnabledUpdated(enabled);
    }

    function setFdusdEnabled(
        bool enabled
    )
        external
        onlyOwner
    {
        fdusdEnabled = enabled;

        emit FdusdEnabledUpdated(enabled);
    }

    // =========================================================
    // Withdraw BNB
    // =========================================================

    function withdrawBNB(
        address payable to
    )
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount =
            address(this).balance;

        if (amount == 0) {
            return;
        }

        (bool success, ) =
            to.call{value: amount}("");

        if (!success) {
            revert TransferFailed();
        }

        emit BnbWithdrawn(
            to,
            amount
        );
    }

    // =========================================================
    // Withdraw USDT
    // =========================================================

    function withdrawUSDT(
        address to
    )
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount =
            usdt.balanceOf(address(this));

        if (amount == 0) {
            return;
        }

        usdt.safeTransfer(
            to,
            amount
        );

        emit TokenWithdrawn(
            address(usdt),
            to,
            amount
        );
    }

    // =========================================================
    // Withdraw FDUSD
    // =========================================================

    function withdrawFDUSD(
        address to
    )
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        uint256 amount =
            fdusd.balanceOf(address(this));

        if (amount == 0) {
            return;
        }

        fdusd.safeTransfer(
            to,
            amount
        );

        emit TokenWithdrawn(
            address(fdusd),
            to,
            amount
        );
    }

    // =========================================================
    // Quotes
    // =========================================================

    function quoteBNB(
        uint256 bnbAmount
    )
        external
        view
        returns (uint256)
    {
        return
            (bnbAmount * bnbRate) /
            1 ether;
    }

    function quoteUSDT(
        uint256 usdtAmount
    )
        external
        view
        returns (uint256)
    {
        return _calculateTokenAmount(
            usdtAmount,
            usdtDecimals,
            usdtRate
        );
    }

    function quoteFDUSD(
        uint256 fdusdAmount
    )
        external
        view
        returns (uint256)
    {
        return _calculateTokenAmount(
            fdusdAmount,
            fdusdDecimals,
            fdusdRate
        );
    }

    // =========================================================
    // Internal functions
    // =========================================================

    function _calculateTokenAmount(
        uint256 paymentAmount,
        uint8 paymentDecimals,
        uint256 rate
    )
        internal
        pure
        returns (uint256)
    {
        uint256 divisor =
            10 ** uint256(paymentDecimals);

        return
            (paymentAmount * rate) /
            divisor;
    }

    function _getDecimals(
        address token
    )
        internal
        view
        returns (uint8)
    {
        (bool success, bytes memory data) =
            token.staticcall(
                abi.encodeWithSignature("decimals()")
            );

        if (!success || data.length < 32) {
            revert InvalidToken();
        }

        return abi.decode(data, (uint8));
    }

    // =========================================================
    // Reject accidental BNB transfers
    // =========================================================

    receive() external payable {
        revert("Use buyWithBNB");
    }

    fallback() external payable {
        revert("Invalid function");
    }
}