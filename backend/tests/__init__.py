"""Test package. Library logs are kept to warnings so test output shows only what failed."""
import os

os.environ.setdefault("VITRINA_LOG_LEVEL", "WARNING")
