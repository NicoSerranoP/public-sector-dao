default: help
import 'lib/just-foundry/justfile'

# The deploy script run by `just deploy` / `just predeploy`.
DEPLOY_SCRIPT := "script/InstallNFTVoting.s.sol:InstallNFTVotingScript"

# Run only the top-level unit tests (excludes fork and invariant suites)
[group('test')]
test-unit *args:
    #!/usr/bin/env bash
    set -euo pipefail
    forge test --no-match-contract "InstallNFTVotingTest|NFTVotingInvariantsTest" {{ args }}

# Run the invariant/fuzz suite at low verbosity (exclude unit and fork suites)
[group('test')]
test-invariant *args:
    #!/usr/bin/env bash
    set -euo pipefail
    forge test --match-path "./test/invariant/*.sol" {{ args }}

# Run the fork tests (exclude unit and invariant suites)
[group('test')]
test-fork *args:
    #!/usr/bin/env bash
    set -euo pipefail
    forge test --match-path "./test/fork/*.sol" {{ args }}

# Deploy: run tests then broadcast with --slow (one block per tx; deploy nft in one block and plugin in another)
[group('script')]
deploy *args:
    just test
    just run {{ DEPLOY_SCRIPT }} --slow {{ args }}

# Fetch submodules, scaffold .env and select the network (default: mainnet)
[group('setup')]
init network="mainnet":
    #!/usr/bin/env bash
    set -euo pipefail
    git submodule update --init --recursive
    if [ ! -f .env ] && [ -f .env.example ]; then
        cp .env.example .env
        echo "Created .env from .env.example — edit it with your settings."
    fi
    if ! command -v forge &>/dev/null; then
        echo "Error: Foundry is not installed. Run 'just setup' to install it."
        exit 1
    fi
    just switch {{ network }}
