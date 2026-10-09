"""PyInstaller entry point for the packaged GUI."""

import sys

from shuffledetector.gui.app import main

if __name__ == "__main__":
    sys.exit(main())
