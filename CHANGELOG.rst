=========
Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`_,
and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

Unreleased
==========

Added
-----
* Upstream Sync (v0.19.0): Integrated upstream lightweight analysis engine for instant completion, hover, and go-to-definitions.
* Crystal 1.21 Compatibility: Native Execution Contexts concurrency support and compatibility fixes for Crystal 1.21.
* CLI Option flags: Added ``--log``/``-l`` (to set log severity level) and ``--version``/``-v`` CLI flags.
* CLI Option flags: Added ``--stdio`` flag as a valid no-op to support existing editor plugins (like Emacs/Vim).
* Automatic discovery: Added automatic discovery of ``src/requires.cr`` for finding project entry points.

Changed
-------
* CI & Container: Updated ``Containerfile`` to Crystal 1.21.0-alpine and dropped deprecated ``-Dpreview_mt`` flag.
* Modernized cache: Modernized result cache implementation.
* GC Tuning: Tuned Boehm GC configuration.

Fixed
-----
* Core Stability: Resolved critical deadlocks and infinite loops.
* Sync Drift: Resolved document synchronization drift and improved formatting safety.
* Warnings: Suppressed deprecated ``Random::DEFAULT`` warnings in Crystal standard library.

