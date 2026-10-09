# Vendored test dependencies

These files exist only so the test suite can run a real Uniswap v4 `PoolManager` offline, at the
address the token hard-codes, and swap SBEE through it with the launch pool's 1.25% fee. Nothing in
this directory is deployed and nothing in `src/` imports it.

| Path | Origin | Commit | Licence |
| --- | --- | --- | --- |
| `v4-core/src/**` | https://github.com/Uniswap/v4-core (`src/`, without `src/test/`) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `v4-core/licenses/` (BUSL-1.1 / MIT per file header) |
| `solmate/src/auth/Owned.sol` | https://github.com/transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `solmate/LICENSE` (AGPL-3.0) |

One local change, because the project's `foundry.toml` is protected and no `solmate/` remapping
can be added:

- `v4-core/src/ProtocolFees.sol`: `import {Owned} from "solmate/src/auth/Owned.sol";` became
  `import {Owned} from "../../solmate/src/auth/Owned.sol";`

Everything else is byte-for-byte upstream. Both repositories were copied as plain files; there is
no git submodule.
