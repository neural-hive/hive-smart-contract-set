// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HIVE is ERC20, ERC20Capped, Ownable2Step {
    uint256 public constant MAX_SUPPLY = 100_000_000_000 ether;

    struct Minter {
        uint256 allocation; // Maximum HIVE this minter is allowed to mint
        uint256 minted;     // HIVE already minted by this minter
        bool active;
    }

    mapping(address => Minter) public minters;

    event MinterSet(
        address indexed minter,
        uint256 allocation
    );

    event MinterRevoked(
        address indexed minter
    );

    event TokensMinted(
        address indexed minter,
        address indexed recipient,
        uint256 amount
    );

    error ZeroAddress();
    error InvalidAllocation();
    error NotMinter();
    error MinterAllocationExceeded();

    constructor(address initialOwner)
        ERC20("HIVE", "HIVE")
        ERC20Capped(MAX_SUPPLY)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }
    }

    /**
     * @notice Authorize a minter with a maximum lifetime allocation.
     *
     * Example:
     *
     * setMinter(saleContract, 50_000_000 ether)
     *
     * means the sale contract can mint at most
     * 50 million HIVE in total.
     */
    function setMinter(
        address minter,
        uint256 allocation
    ) external onlyOwner {
        if (minter == address(0)) {
            revert ZeroAddress();
        }

        if (allocation == 0) {
            revert InvalidAllocation();
        }

        minters[minter] = Minter({
            allocation: allocation,
            minted: 0,
            active: true
        });

        emit MinterSet(minter, allocation);
    }

    /**
     * @notice Revoke a minter.
     *
     * Already-minted HIVE is unaffected.
     * The minter simply cannot mint anymore.
     */
    function revokeMinter(address minter)
        external
        onlyOwner
    {
        minters[minter].active = false;

        emit MinterRevoked(minter);
    }

    /**
     * @notice Mint HIVE.
     *
     * The caller must:
     * 1. Be an active minter.
     * 2. Have enough remaining allocation.
     * 3. Not cause total supply to exceed 100B.
     */
    function mint(
        address to,
        uint256 amount
    ) external {
        if (to == address(0)) {
            revert ZeroAddress();
        }

        Minter storage minter = minters[msg.sender];

        if (!minter.active) {
            revert NotMinter();
        }

        if (amount > minter.allocation - minter.minted) {
            revert MinterAllocationExceeded();
        }

        minter.minted += amount;

        _mint(to, amount);

        emit TokensMinted(
            msg.sender,
            to,
            amount
        );
    }

    /**
     * @notice Returns how much this minter can still mint.
     */
    function remainingMinterAllocation(
        address minter
    ) external view returns (uint256) {
        Minter memory m = minters[minter];

        if (!m.active) {
            return 0;
        }

        return m.allocation - m.minted;
    }

    /**
     * @dev Required because ERC20Capped and ERC20 both
     * implement _update().
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}