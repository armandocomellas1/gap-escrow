# GAP Gaming Access Portal — GAPEscrow

The escrow smart contract used by [GAP Gaming Access Portal](https://gamingaccessportal.com/), deployed on **BNB Smart Chain (BSC)** mainnet (chain ID 56). Two players stake the same amount of BNB on a 1v1 match, and the contract holds both stakes until the match is settled.

This repository contains the verified Solidity source of the contract. The GAP web app is closed-source.

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56)

## Contract Addresses

| Network | Core Contract | Token Contract |
|---------|---------------|----------------|
| BNB Smart Chain Mainnet (56) | GAPEscrow: [`0x3D7dBD781aa9c33d9FAA5F03D27BB5F910c5Ca32`](https://bscscan.com/address/0x3D7dBD781aa9c33d9FAA5F03D27BB5F910c5Ca32) | None — GAP has no token |

- **Deployment transaction**: [`0xa6d747a8620f0a73fa5a1918ef1de734a21e34cea7a9f663f04f4efd0ffdad8c`](https://bscscan.com/tx/0xa6d747a8620f0a73fa5a1918ef1de734a21e34cea7a9f663f04f4efd0ffdad8c), block 112294623 (2026-07-26)
- **Source verification**: [Sourcify, exact match](https://repo.sourcify.dev/56/0x3D7dBD781aa9c33d9FAA5F03D27BB5F910c5Ca32). [`contracts/GAPEscrow.sol`](contracts/GAPEscrow.sol) is byte for byte the verified source, including its CRLF line endings and original Spanish comments.

## Technology Stack

- **Blockchain**: BNB Smart Chain (BSC) mainnet
- **Smart contract**: Solidity 0.8.24, single contract, no external libraries, native BNB only
- **Compiler settings**: solc 0.8.24+commit.e11b9ed9, optimizer enabled (200 runs), EVM version `paris`, viaIR off

## Features

- **Both stakes in escrow before anyone plays.** The opponent must send exactly the creator's stake to join, so neither player holds the other's money.
- **A fee only when a match has a winner.** The winner is credited 90% of the pot at the current 10% rate; draws, cancellations and refunds return 100% of each stake. The fee is frozen per match and capped at 10% in the contract.
- **Timeouts instead of stuck stakes.** If a dispute is still open 4 hours after it started, or nobody reported 8 hours after the match filled, anyone can trigger a full refund of both stakes.
- **Pull-based withdrawals.** Winnings and refunds are credited in the contract and withdrawn with `withdraw()`, which the pause switch never blocks.
- **Fixed code.** No proxy, `delegatecall` or `selfdestruct`; the deployed code cannot be changed.

## Roles

- Players report results themselves. Contested results are decided by a single **operator** wallet run by GAP.
- The **owner** can pause new matches, joins and result reports; set the fee for future matches (never above 10%); replace the operator; withdraw accrued fees; and, after a pause of at least 24 hours, refund a match's stakes to its own players. No function lets the owner or the operator withdraw player stakes.
- Today the owner and the operator are the same wallet.

## Links

- Website: https://gamingaccessportal.com/
- Docs: https://gamingaccessportal.com/docs
- Discord: https://discord.gg/ZAaq67nfZ8

## Disclaimer

18+ only, and only where it is legal for you. GAP is not affiliated with or endorsed by any game publisher. GAPEscrow has not yet been audited by a third party. Smart contracts can contain bugs, and you can lose what you stake. The source is licensed under MIT (see the SPDX header in the contract).
