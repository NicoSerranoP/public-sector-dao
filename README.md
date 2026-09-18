# Public sector DAO [![Foundry][foundry-badge]][foundry] [![License: AGPL v3][license-badge]][license]

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg
[license]: https://opensource.org/licenses/AGPL-v3
[license-badge]: https://img.shields.io/badge/License-AGPL_v3-blue.svg

## Introduction

This is a on-chain community participation platform where citizens will be able to register themselves using NFT tokens minted by an authorized stakeholder. Every project will be submitted as a proposal to the DAO and the voting process will be only open for token holders or delegated representatives.

## Features

NFTVoting is an Aragon OSx Plugin, designed to conduct governance processes where the voting power of each member is determined by an [IVotes compatible](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/governance/utils/IVotes.sol) [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token. Each NFT counts as exactly one vote.

Three voting modes:
- Early execution: Execute when there's mathematical certainty that the proposal can't be defeated
- Vote replacement: Allow to change votes until the proposal ends
- Standard mode: No vote replacement or early execution.

One token contract is provided for convenience:
- GovernanceERC721: Mint vote NFTs to a predefined set of addresses. Holders transfer with the standard `transferFrom` / `safeTransferFrom`; the DAO (or whoever holds the permission) can force-transfer via `adminTransfer` and revoke via `burn`.

If you already have an IVotes compatible ERC-721 token, you can simply import it.

Other features:
- Automatic self-delegation on mint/transfer, so every NFT counts unless the holder delegates elsewhere
- Granular permission management for proposal creation, proposal execution, token minting/burning/transfer
- Minimum voting power requirements for proposers

## How voting works

`NFTVoting` is the majority voting implementation. Voting power comes from an
[OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes) compatible
[ERC-721](https://eips.ethereum.org/EIPS/eip-721) governance token, where each token counts as exactly
one unit of voting power.

### Parameterization

We define two parameters

$$\texttt{support} = \frac{N_\text{yes}}{N_\text{yes} + N_\text{no}} \in [0,1]$$

and

$$\texttt{participation} = \frac{N_\text{yes} + N_\text{no} + N_\text{abstain}}{N_\text{total}} \in [0,1],$$

where $N_\text{yes}$, $N_\text{no}$, and $N_\text{abstain}$ are the yes, no, and abstain votes that have
been cast and $N_\text{total}$ is the total voting power available at proposal creation time.

#### Limit Values: Support Threshold & Minimum Participation

Two limit values are associated with these parameters and decide if a proposal execution should be
possible: $\texttt{supportThreshold} \in [0,1)$ and $\texttt{minParticipation} \in [0,1]$.

For threshold values, $>$ comparison is used. This **does not** include the threshold value.
E.g., for $\texttt{supportThreshold} = 50\%$, the criterion is fulfilled if there is at least one more
yes than no votes ($N_\text{yes} = N_\text{no} + 1$). For minimum values, $\ge{}$ comparison is used.
This **does** include the minimum participation value. E.g., for $\texttt{minParticipation} = 40\%$ and
$N_\text{total} = 10$, the criterion is fulfilled if 4 out of 10 votes were casted.

Majority voting implies that the support threshold is set with
$$\texttt{supportThreshold} \ge 50\% .$$
However, this is not enforced by the contract code and developers can make unsafe parameters and only
the frontend will warn about bad parameter settings.

### Execution Criteria

After the vote is closed, two criteria decide if the proposal passes.

#### The Support Criterion

For a proposal to pass, the required ratio of yes and no votes must be met:
$$(1- \texttt{supportThreshold}) \cdot N_\text{yes} > \texttt{supportThreshold} \cdot N_\text{no}.$$
Note, that the inequality yields the simple majority voting condition for
$\texttt{supportThreshold}=\frac{1}{2}$.

#### The Participation Criterion

For a proposal to pass, the minimum voting power must have been cast:
$$N_\text{yes} + N_\text{no} + N_\text{abstain} \ge \texttt{minVotingPower},$$
where $\texttt{minVotingPower} = \texttt{minParticipation} \cdot N_\text{total}$.

### Vote Replacement

The contract allows votes to be replaced. Voters can vote multiple times and only the latest
voteOption is tallied.

### Early Execution

This contract allows a proposal to be executed early, iff the vote outcome cannot change anymore by
more people voting. Accordingly, vote replacement and early execution are mutually exclusive options.
The outcome cannot change anymore iff the support threshold is met even if all remaining votes are no
votes. We call this number the worst-case number of no votes and define it as

$$N_\text{no, worst-case} = N_\text{no} + \texttt{remainingVotes}$$

where

$$\texttt{remainingVotes} =
N_\text{total}-\underbrace{(N_\text{yes}+N_\text{no}+N_\text{abstain})}_{\text{turnout}}.$$

We can use this quantity to calculate the worst-case support that would be obtained if all remaining
votes are casted with no:

$$
\begin{align*}
  \texttt{worstCaseSupport}
  &= \frac{N_\text{yes}}{N_\text{yes} + (N_\text{no, worst-case})} \\[3mm]
  &= \frac{N_\text{yes}}{N_\text{yes} + (N_\text{no} + \texttt{remainingVotes})} \\[3mm]
  &= \frac{N_\text{yes}}{N_\text{yes} +  N_\text{no} + N_\text{total}
     - (N_\text{yes} + N_\text{no} + N_\text{abstain})} \\[3mm]
  &= \frac{N_\text{yes}}{N_\text{total} - N_\text{abstain}}
\end{align*}
$$

In analogy, we can modify the support criterion from above to allow for early execution:

$$
\begin{align*}
  (1 - \texttt{supportThreshold}) \cdot N_\text{yes}
  &> \texttt{supportThreshold} \cdot  N_\text{no, worst-case} \\[3mm]
  &> \texttt{supportThreshold} \cdot (N_\text{no} + \texttt{remainingVotes}) \\[3mm]
  &> \texttt{supportThreshold} \cdot (N_\text{no}
    + N_\text{total}-(N_\text{yes}+N_\text{no}+N_\text{abstain})) \\[3mm]
  &> \texttt{supportThreshold} \cdot (N_\text{total} - N_\text{yes} - N_\text{abstain})
\end{align*}
$$

Accordingly, early execution is possible when the vote is open, the modified support criterion, and
the participation criterion are met.

## Prerequisites
- [Foundry](https://getfoundry.sh/)
- [just](https://github.com/casey/just)

Optional:

- [Docker](https://www.docker.com) (recommended for deploying)

## Getting Started

Clone the repository with submodules and initialize it for a network:

```bash
git clone --recurse-submodules <repo-url>
just init          # defaults to mainnet, e.g. `just init sepolia`
```

`just init` fetches submodules, creates `.env` from `.env.example`, and selects the network. Edit `.env` to add your secrets (`DEPLOYER_KEY`, `ETHERSCAN_API_KEY`, …) and the install settings described below. Alternatively, resolve them with the [`vars`](https://github.com/vars-cli/vars) secret manager — the keys this project needs are declared in [`.vars.yaml`](./.vars.yaml), and just-foundry's recipes call `vars resolve` automatically when `vars` is installed.

Network settings (RPC URL, chain id, verifier, and the Aragon OSx addresses) come from `lib/just-foundry/networks/<network>.env` — switch with `just switch <network>`, inspect the resolved values with `just env`, and create a local editable copy with `just switch <network> override`.

### Using just

`just` is the task launcher for the project; the generic recipes are imported from [`lib/just-foundry`](https://github.com/aragon/just-foundry). Run `just` (or `just help`) to list them:

```
$ just
[setup]
init network="mainnet"       Fetch submodules, scaffold .env and select the network
switch network override=""   Select the active network
setup                        Install Foundry

[script]
predeploy                    Dry-run the install script (no broadcast)
deploy *args                 Run tests, then broadcast + verify

[test]
test *args                   Run unit tests (fork tests excluded)
test-fork *args               Run fork tests (requires RPC_URL)
test-coverage                Generate an HTML coverage report under ./report

[verification]
verify type="" script=""     Verify the latest broadcast (etherscan|blockscout|sourcify)

[develop]
clean                        Clean build artifacts and reports
storage-info contract        Show a contract's storage layout
check-upgrade from to        Check storage-layout upgrade compatibility

[helpers]
env                          Show the resolved environment (values + sources)
```

There are also `balance`, `refund`, `gas-price`, `nonce` and `clean-nonce` deployer helpers (run `just <name>`).

## Testing

Run the suites with `just`:

```sh
just test          # unit tests (fork tests excluded)
just test-fork     # fork tests (requires a reachable RPC_URL for the active network)
just test-coverage # HTML coverage report under ./report
```

`just test` checks the logic's accordance to the specs; `just test-fork` additionally requires `RPC_URL` (from the selected network or `.env`) and exercises the full install flow (`script/InstallNFTVoting.s.sol`) against a real `DAOFactory` on a fork, including a full create → vote → execute proposal cycle.

## Installing the plugin

`script/InstallNFTVoting.s.sol` deploys and initializes the `NFTVoting` plugin directly (no `PluginSetupProcessor`/`PluginRepo` involved) and wires up its permissions. It supports two flows, selected by `EXISTING_DAO_ADDRESS`:

- **New DAO** (default, `EXISTING_DAO_ADDRESS` unset): creates a DAO via Aragon's `DAOFactory` and installs the plugin on it in the same run.
- **Existing DAO** (`EXISTING_DAO_ADDRESS` set): installs onto an already-deployed DAO. This requires the deployer key to already hold `EXECUTE_PERMISSION_ID` on that DAO — installing into an existing, fully decentralized DAO otherwise requires a governance proposal instead of a direct broadcast transaction.

For both flows, the script revokes the installer's direct `EXECUTE_PERMISSION_ID` on the DAO as the last action of the install batch, so DAO execution is handed over to governance/plugin permissions atomically.

All install parameters (token, voting settings, target config, …) are read from environment variables — see the "INSTALL SETTINGS" section in [`.env.example`](./.env.example) for the full list and their defaults.

```sh
just switch <network>
just predeploy     # simulate (no broadcast)
just deploy        # run tests, then broadcast + verify; logs to ./logs
```

### Deployment Checklist

When running a production deployment ceremony, you can use these steps as a reference:

- [ ] I have cloned the official repository on my computer and I have checked out the `main` branch
- [ ] I am using the latest official docker engine, running a Debian Linux (stable) image
  - [ ] I have run `docker run --rm -it -v .:/deployment debian:bookworm-slim`
  - [ ] I have run `apt update && apt install -y curl git vim neovim bc`
  - [ ] I have installed `just` (`curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin`)
  - [ ] I have run `curl -L https://foundry.paradigm.xyz | bash`
  - [ ] I have run `source /root/.bashrc`
  - [ ] I have run `foundryup`
  - [ ] I have run `cd /deployment`
  - [ ] I have run `just init <network>`
- [ ] I am opening an editor on the `/deployment` folder, within the Docker container
- [ ] The `.env` file contains the correct parameters for the deployment
  - [ ] I have created a new burner wallet with `cast wallet new` and copied the private key to `DEPLOYER_KEY` within `.env`
  - [ ] I have selected the correct network with `just switch <network>` (this sets RPC_URL, CHAIN_ID and the verifier)
  - [ ] I have set `ETHERSCAN_API_KEY` or `BLOCKSCOUT_HOST_NAME` (when relevant to the target network)
  - [ ] I have set the install settings (`EXISTING_DAO_ADDRESS` or new-DAO/token/voting settings) as described above
  - [ ] I have run `just env` and confirmed the resolved values
  - [ ] I am the only person of the ceremony that will operate the deployment wallet
- [ ] All the tests run clean (`just test`)
- My computer:
  - [ ] Is running in a safe location and using a trusted network
  - [ ] It exposes no services or ports
    - MacOS: `sudo lsof -iTCP -sTCP:LISTEN -nP`
    - Linux: `netstat -tulpn`
    - Windows: `netstat -nao -p tcp`
  - [ ] The wifi or wired network in use does not expose any ports to a WAN
- [ ] I have run `just predeploy` and the simulation completes with no errors
- [ ] The deployment wallet has sufficient native token for gas
  - At least, 15% more than the amount estimated during the simulation
- [ ] `just test` still runs clean
- [ ] I have run `git status` and it reports no local changes
- [ ] The current local git branch (`main`) corresponds to its counterpart on `origin`
  - [ ] I confirm that the rest of members of the ceremony pulled the last git commit on `main` and reported the same commit hash as my output for `git log -n 1`
- [ ] I have initiated the production deployment with `just deploy`

### Post deployment checklist

- [ ] The deployment process completed with no errors
- [ ] All the project's smart contracts are correctly verified on the reference block explorer of the target network.
- [ ] The output of the latest `logs/InstallNFTVoting-<network>-<timestamp>.log` file corresponds to the console output
- [ ] A file called `artifacts/install-nft-<network>-<timestamp>.json` has been created, and the addresses match those logged to the screen
- [ ] I verified that the deployment wallet no longer has direct DAO execute rights:
  - `cast call <DAO_ADDRESS> "isGranted(address,address,bytes32,bytes)(bool)" <DAO_ADDRESS> <DEPLOYER_ADDRESS> $(cast keccak "EXECUTE_PERMISSION") "0x"` returns `false`
- [ ] I have uploaded the following files to a shared location:
  - `logs/InstallNFTVoting-<network>-<timestamp>.log` (the last one)
  - `artifacts/install-nft-<network>-<timestamp>.json`  (the last one)
  - `broadcast/InstallNFTVoting.s.sol/<chain-id>/run-<timestamp>.json` (the last one, or `run-latest.json`)
- [ ] The rest of members confirm that the values are correct
- [ ] I have transferred the remaining funds of the deployment wallet to the address that originally funded it
  - `just refund`

This concludes the deployment ceremony.

## Contract source verification

When running a deployment with `just deploy`, Foundry will attempt to verify the contracts on the corresponding block explorer.

If you need to verify on multiple explorers or the automatic verification did not work, use the `verify` recipe with the desired verifier:

```sh
just verify etherscan   # or: blockscout, sourcify
just verify blockscout
just verify sourcify
```

These use the last deployment data under `broadcast/InstallNFTVoting.s.sol/<chain-id>/run-latest.json`.
- Ensure that the required variables are set within the `.env` file (or the active network).

This flow will attempt to verify all the contracts in one go, but you may still need to issue additional manual verifications, depending on the circumstances.

### Routescan verification (manual)

```sh
$ forge verify-contract <address> <path/to/file.sol>:<contract-name> --verifier-url 'https://api.routescan.io/v2/network/<testnet|mainnet>/evm/<chain-id>/etherscan' --etherscan-api-key "verifyContract" --num-of-optimizations 200 --compiler-version 0.8.28 --constructor-args <args>
```

Where:
- `<address>` is the address of the contract to verify
- `<path/to/file.sol>:<contract-name>` is the path of the source file along with the contract name
- `<testnet|mainnet>` the type of network
- `<chain-id>` the ID of the chain
- `<args>` the constructor arguments
  - Get them with `$(cast abi-encode "constructor(address param1, uint256 param2,...)" param1 param2 ...)`

## Security 🔒

If you believe you've found a security issue, we encourage you to notify us. We welcome working with you to resolve the issue promptly.

Security Contact Email: sirt@aragon.org

Please do not use the public issue tracker to report security issues.

### Security tools used

1. [Pashov skills](https://github.com/pashov/skills): AI Agent skills to run a Solidity audit. Results saved in [/audits/pashov](./audits/pashov/). Findings in report have been addressed

1. [ETHSkills](https://github.com/austintgriffith/ethskills): AI Agent skills built by Austin Griffin (author of ScaffoldETH). Results will be saved in [/audits/ethskills](./audits/ethskills/).

1. [Trail of Bits skills](https://github.com/trailofbits/skills): AI Agent skills to run a Solidity audit. Results will be saved in [/audits/trailofbits](./audits/trailofbits/).

1. [Slither](https://github.com/crytic/slither): static analysis tool to detect known vulnerabilities in Ethereum.

1. [Halmos](https://github.com/a16z/halmos): symbolic testing for Solidity contracts as an entry point for formal verification


## Contributing 🤝

Contributions are welcome! Please read our contributing guidelines to get started.

## License 📄

This project is licensed under AGPL-3.0-or-later.

## Support 💬

For support, join our Discord server or open an issue in the repository.
