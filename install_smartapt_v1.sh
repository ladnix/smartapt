#!/bin/bash
set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
NC='\033[0m'

# ==== CHECK FOR ROOT ==== #
if [[ $EUID -ne 0 ]]; then
    echo -e "[${RED}error${NC}] Please run as root: sudo $0"
    exit 1
fi

# ==== DEFINE PATHS ==== #
BIN_PATH="/usr/local/bin/smartapt"
MAN_PATH="/usr/share/man/man1/smartapt.1"
COMPLETE_PATH="/etc/bash_completion.d/smartapt"
STATE_DIR="/var/lib/smartapt"
LOG_FILE="/var/log/smartapt.log"

# ==== CREATE DIRECTORIES ==== #
for dir in \
    "$(dirname "$BIN_PATH")" \
    "$(dirname "$MAN_PATH")" \
    "$(dirname "$COMPLETE_PATH")" \
    "$STATE_DIR" \
    "$(dirname "$LOG_FILE")"
do
    mkdir -p "$dir"
done

touch "$LOG_FILE"

# ==== MAIN SCRIPT ==== #
echo "[1/3] Installing smartapt..."
cat > "$BIN_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

STATE_DIR="/var/lib/smartapt"
LOG_FILE="/var/log/smartapt.log"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
msg() { echo -e "[${BLUE}info${NC}] $1"; log " [info]  $1"; }
warn() { echo -e "[${YELLOW}warn${NC}] $1"; log " [warn]  $1"; }
error() { echo -e "[${RED}error${NC}] $1"; log " [error]  $1"; }
success() { echo -e "[${GREEN}ok${NC}] $1"; log " [ok]  $1"; }

usage() {
    echo -e "${YELLOW}smartapt - track install dependencies${NC}"
    echo -e "  ${BLUE}install <package>${NC} - install and track dependencies"
    echo -e "  ${BLUE}remove <package>${NC} - remove with tracked dependencies"
    echo -e "  ${BLUE}undo${NC} - restore last removed packages"
    echo -e "  ${BLUE}show <package>${NC} - show dependencies for removal"
    echo -e "  ${BLUE}list${NC} - list tracked packages"
    echo -e "  ${BLUE}--help${NC} - display this help"
    exit 0
}

if ! command -v apt >/dev/null 2>&1; then
    echo -e "[${RED}error${NC}] apt not found."
    exit 1
fi

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

if [[ "$1" == "--help" ]]; then usage; fi

if [[ "$1" == "list" ]]; then
    echo -e "${BLUE}Tracked packages:${NC}"
    ls "$STATE_DIR" | grep _tracked.txt | sed 's/_tracked.txt//'
    exit 0
fi

if [[ "$1" == "show" && -n "${2:-}" ]]; then
    FILE="$STATE_DIR/${2}_tracked.txt"
    if [[ -f "$FILE" ]]; then
        echo -e "${BLUE}To be removed with $2:${NC}"
        nl -w2 -s'. ' "$FILE"
    else
        warn "No info found for $2"
    fi
    exit 0
fi

if [[ "$1" == "undo" ]]; then
    LAST_REMOVE="$STATE_DIR/last_remove.txt"
    if [[ -f "$LAST_REMOVE" ]]; then
        msg "Restoring last removed packages..."
        apt install -y $(cat "$LAST_REMOVE")
        success "Packages restored."
        rm -f "$LAST_REMOVE"
    else
        warn "No last removal info found."
    fi
    exit 0
fi

if [[ "$#" -ne 2 ]]; then usage; fi

ACTION="$1"
PKG="$2"
BEFORE_MANUAL="$STATE_DIR/${PKG}_manual_before.txt"
AFTER_MANUAL="$STATE_DIR/${PKG}_manual_after.txt"
BEFORE_AUTO="$STATE_DIR/${PKG}_auto_before.txt"
AFTER_AUTO="$STATE_DIR/${PKG}_auto_after.txt"
TRACKED="$STATE_DIR/${PKG}_tracked.txt"

if [[ "$ACTION" == "install" ]]; then
    msg "Saving pre-install state..."
    apt-mark showmanual | sort > "$BEFORE_MANUAL"
    apt-mark showauto | sort > "$BEFORE_AUTO"

    msg "Simulating installation of $PKG..."
    apt install --dry-run "$PKG"

    echo
    read -rp "Proceed with installation of $PKG? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Installation canceled."
        exit 0
    fi

    msg "Installing $PKG..."
    if apt install -y "$PKG"; then

        set +e
        apt-mark showmanual | sort > "$AFTER_MANUAL"
        apt-mark showauto | sort > "$AFTER_AUTO"

        msg "Calculating newly installed packages..."
        comm -13 "$BEFORE_MANUAL" "$AFTER_MANUAL" > \
        "$STATE_DIR/tmp_manual_added.txt"
        comm -13 "$BEFORE_AUTO" "$AFTER_AUTO" > \
        "$STATE_DIR/tmp_auto_added.txt"
        cat "$STATE_DIR/tmp_manual_added.txt" "$STATE_DIR/tmp_auto_added.txt" \
        | sort > "$TRACKED"
        msg "Adding direct dependencies of $PKG..."
        apt-cache depends "$PKG" | awk '/Depends:/ {print $2}' >> "$TRACKED"
        sort -u "$TRACKED" -o "$TRACKED"
        rm -f "$STATE_DIR/tmp_manual_added.txt" "$STATE_DIR/tmp_auto_added.txt"

        if [[ -s "$TRACKED" ]]; then
            msg "Marking auto dependencies..."
            xargs -r apt-mark auto < "$TRACKED"
        else
            warn "No new packages tracked."
        fi

        apt-mark manual "$PKG"
        success "Installed $PKG with tracking."
    else
        error "Failed to install $PKG"
        rm -f "$BEFORE_MANUAL" "$AFTER_MANUAL" "$BEFORE_AUTO" "$AFTER_AUTO" \
        "$TRACKED"
    fi

elif [[ "$ACTION" == "remove" ]]; then
    if [[ ! -f "$TRACKED" ]]; then
        error "No install info for $PKG"
        exit 1
    fi

    TO_REMOVE=()
    TO_SKIP=()

    echo
    echo -e "${YELLOW}Checking each package before removal...${NC}"
    
    while read -r dep <&3; do
        if [[ -z "$dep" ]]; then
            continue
        fi

        echo
        echo -e "${BLUE}Checking dependency: $dep${NC}"

        USERS=$(apt-cache rdepends "$dep" 2>/dev/null | awk '/^ /{print $1}' \
        | grep -v "^$dep\$" | sort -u)
        if [[ -n "USERS" ]]; then
            USERS_COUNT=$(echo "$USERS" | wc -l)
            if [[ "$USERS_COUNT" -gt 10 ]]; then
                echo -e "${YELLOW}Package '$dep' is used by \
                $USERS_COUNT other packages.${NC}"
                read -p "Show full list? [y/N]: " SHOW_LIST
                if [[ "$SHOW_LIST" =~ ^[Yy]$ ]]; then
                    echo "$USERS" | nl -w2 -s'. '
                fi
            else
                echo -e "${YELLOW}Package '$dep' is used by other \
                packages:${NC}"
                echo "$USERS" | nl -w2 -s'. '
            fi
        else
            echo -e "${GREEN}Package '$dep' has no external users.${NC}"
        fi

        echo
        read -p "REMOVE $dep? [y/N]: " CONFIRM_DEP
        if [[ "$CONFIRM_DEP" =~ ^[Yy]$ ]]; then
            TO_REMOVE+=("$dep")
        else
            TO_SKIP+=("$dep")
        fi
    done 3< "$TRACKED"

    echo
    echo -e "${YELLOW}Summary of your choices:${NC}"
    echo

    if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
        echo -e "${GREEN}Will be removed:${NC}"
        i=1
        for dep in "${TO_REMOVE[@]}"; do
            echo " $i. $dep"
            ((i++))
        done
    else
        echo -e "${GREEN}Nothing selected for removal.${NC}"
    fi

    if [[ ${#TO_SKIP[@]} -gt 0 ]]; then
        echo
        echo -e "${RED}Skipped:${NC}"
        j=1
        for dep in "${TO_SKIP[@]}"; do
            echo " $j. $dep"
            ((j++))
        done
    fi
    
    echo
    read -rp "Proceed with removal of selected packages? [y/N]: " CONFIRM_FINAL
    if [[ ! "$CONFIRM_FINAL" =~ ^[Yy]$ ]]; then
        warn "Removal canceled."
        exit 0
    fi

    if [[ ${#TO_REMOVE[@]} -gt 0 ]]; then
        echo "${TO_REMOVE[@]}" > "$STATE_DIR/last_remove.txt"
        msg "Saved list of removed packages for possible undo."

        msg "Removing selected packages..."
        apt remove --purge -y "${TO_REMOVE[@]}"
        success "Selected packages removed."
    else
        warn "No packages to remove."
    fi

    rm -f "$BEFORE_MANUAL" "$AFTER_MANUAL" "$BEFORE_AUTO" "$AFTER_AUTO" \
    "$TRACKED"
    success "Tracking files cleaned."
else
    usage
fi
EOF
chmod +x "$BIN_PATH"
echo -e "[${GREEN}ok${NC}] in $BIN_PATH"

# ==== AUTOCOMPLETE SCRIPT ==== #
echo "[2/3] Installing autocomplete..."
cat > "$COMPLETE_PATH" <<'EOF'
_smartapt_completions() {
    local cur prev pkgs
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="install remove undo list show --help"

    case "$prev" in
        install)
            return 0
            ;;
        remove|show)
            if [[ ! -d /var/lib/smartapt ]]; then
                return 0
            fi
            pkgs=$(ls 2>/dev/null /var/lib/smartapt 2>/dev/null \
            | grep '_tracked.txt' | sed 's/_tracked.txt//')
            COMPREPLY=( $(compgen -W "$pkgs" -- "$cur") )
            return 0
            ;;
        *)
            COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
            return 0
            ;;
    esac
}
complete -F _smartapt_completions smartapt
EOF
echo -e "[${GREEN}ok${NC}] in $COMPLETE_PATH"

# ==== MAN PAGE ==== #
echo "[3/3] Installing man-page..."
cat > "$MAN_PATH" <<'EOF'
.TH SMARTAPT 1 "2025" "v1.0" "SmartApt Manual"
.SH NAME
smartapt \- install and remove packages with dependency tracking
.SH SYNOPSIS
.B smartapt
[ install <package> | remove <package> | undo | list | show <package> | --help ]
.SH DESCRIPTION
SmartApt is a system-wide wrapper for APT with dependency tracking.
It records additional packages installed with a target and allows for clean 
removal later.
All state is saved in /var/lib/smartapt/
Logs are written to /var/log/smartapt.log
.SH COMMANDS
.TP
.B install <package>
Install the specified package and track newly added dependencies.
.TP
.B remove <package>
Remove the specified package and any dependencies tracked during installation.
.TP
.B undo
Restore the last removed packages.
.TP
.B list
Show all packages with saved tracking info.
.TP
.B show <package>
Show dependencies tracked with the package.
.TP
.B --help
Display this help message.
.SH EXAMPLES
To install the package 'curl' and track its dependencies:
.PP
$ smartapt install curl
.PP
To remove the package 'curl' and its associated dependencies:
.PP
$ smartapt remove curl
.PP
To undo last remove:
.PP
$ smartapt undo
.PP
To list all tracked packages:
.PP
$ smartapt list 
.PP
To show the package and dependencies:
.PP
$ smartapt show <package>
.PP
.SH AUTHOR
alex
EOF
gzip -f "$MAN_PATH"
echo -e "[${GREEN}ok${NC}] in $MAN_PATH"

# ==== DONE ==== #
echo -e "[${GREEN}complete${NC}] Type: smartapt --help"

