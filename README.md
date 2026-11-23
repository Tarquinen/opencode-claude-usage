# opencode-claude-usage

Shows your Claude subscription usage in the OpenCode Desktop session header: the 5 hour and weekly limits of every Claude Code account you are signed in to.

## Installation

Requires OpenCode Desktop 2.3.0 or newer on Linux or Windows. macOS is not supported, because Claude Code keeps its login in the Keychain there.

1. Install Claude Code and sign in with `claude auth login`. An existing login is reused.
2. Install the plugin:

   ```sh
   opencode plugin add github:Tarquinen/opencode-claude-usage
   ```

The usage bars appear in the header of every session. Hover or click them for details.

Extra accounts are picked up from any `~/.claude-*` folder, such as one signed in with `CLAUDE_CONFIG_DIR="$HOME/.claude-2" claude auth login`.

## Updating

```sh
opencode plugin update github:Tarquinen/opencode-claude-usage
```
