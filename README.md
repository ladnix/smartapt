# smartapt

**smartapt** is a wrapper for `apt` that tracks installed package dependencies, allowing you to cleanly remove them later. It's like an "install with undo for apt.

## Features

- `smartapt install <package>` - Installs a package and records added dependencies
- `smartapt remove <package>` - Interactively removes a package and tracked dependencies
- `smartapt undo` - Restores the last removed package with its dependencies
- `smartapt list` - Lists tracked packages
- `smartapt show <package>` - Displays dependecies tracked for a package
- Logs all actions to `/var/log/smartapt.log`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/ladnix/smartapt/main/smartapt_installer_v1.sh | sudo bash

