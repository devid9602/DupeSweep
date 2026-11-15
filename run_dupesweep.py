"""Launcher used by the packaged app (PyInstaller) and for running from source."""
import multiprocessing
import sys

if __name__ == "__main__":
    multiprocessing.freeze_support()
    from dupesweep.gui.app import main
    sys.exit(main())
