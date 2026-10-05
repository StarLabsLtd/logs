# ------------------------------------------------------------
# Dependency check
# ------------------------------------------------------------

echo
echo "============================================================"
echo "DEPENDENCY CHECK"
echo "============================================================"

MISSING=""

command -v libinput >/dev/null 2>&1 || MISSING="$MISSING libinput-tools"
command -v evtest >/dev/null 2>&1 || MISSING="$MISSING evtest"

if [ -n "$MISSING" ]; then
    echo
    echo "Some diagnostic tools required for the pen test are not installed."
    echo
    echo "Required packages:$MISSING"
    echo

    printf "Would you like to install them now? [Y/n]: "
    read answer </dev/tty
    answer=${answer:-Y}

    case "$answer" in
        [Yy]*)
            echo
            echo "Installing required diagnostic tools..."
            echo

            if command -v apt-get >/dev/null 2>&1; then
                apt-get update
                apt-get install -y $MISSING
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y libinput-utils evtest
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Sy --noconfirm libinput evtest
            else
                echo
                echo "Unable to automatically install the required tools."
                echo "Please install libinput and evtest using your"
                echo "distribution's package manager, then run the test again."
                exit 1
            fi

            echo
            echo "Required tools installed successfully."
            echo "Continuing with the pen test..."
            echo
            ;;
        *)
            echo
            echo "Installation cancelled."
            echo "The pen test cannot continue without these tools."
            exit 1
            ;;
    esac
else
    echo
    echo "✓ All required diagnostic tools are installed."
fi
