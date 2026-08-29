# Codex Account Switcher

Cycles through accounts in the Codex desktop app.

## Usage

1. Set the account count and `PackageFamilyName` in `config.json`.
2. Sign in to the first account in Codex.
3. Run `switch-codex-account.cmd`.
4. If prompted, sign in to the next account.
5. Run `switch-codex-account.cmd` again to switch to the next account.

Account data is stored in the local `data` folder.

You do not need to close Codex before running the script. It automatically closes and restarts the app.
