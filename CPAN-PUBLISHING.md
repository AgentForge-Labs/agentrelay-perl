# CPAN publication

The canonical public source is `AgentForge-Labs/agentrelay-perl`. The CPAN
distribution name is `AgentForge-AgentRelay` and the primary module is
`AgentForge::AgentRelay`.

## Release gates

1. `python3 sdk/generate.py --language perl --check`
2. `python3 sdk/check_snapshots.py`
3. `perl Makefile.PL && make test && make dist && make disttest`
4. Run the hosted conformance fixture in `sdk/perl-conformance`.
5. Verify the built tarball installs into a clean Perl environment.
6. Upload the exact tested tarball to PAUSE/CPAN.

## Authentication boundary

CPAN publication requires a PAUSE account credential or upload token owned by
AgentForge Labs. These publication credentials must be GitHub environment
secrets and must never be committed, logged, or bundled in the distribution.

The current repository has no PAUSE/CPAN upload secret configured. Until an
authorized PAUSE credential is added, the release workflow can build and
validate the exact CPAN tarball but cannot perform the final public upload.
