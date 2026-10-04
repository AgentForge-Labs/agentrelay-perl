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


## Current publication status (2026-10-04)

The tested 0.1.0 source tree is public at
`https://github.com/AgentForge-Labs/agentrelay-perl`.

The live MetaCPAN release endpoint for `AgentForge-AgentRelay` currently
returns HTTP 404 / `Not found`, confirming that no CPAN release has been
uploaded yet.

The commercial repository currently exposes only the repository-level
`PYPI_API_TOKEN` Actions secret and only a `pypi` deployment environment.
There is no `PAUSE_USER` or `PAUSE_PASSWORD` credential and no configured
`cpan` environment with publication credentials. The release workflow
therefore intentionally fails closed before upload until an authorized
AgentForge Labs PAUSE credential is configured.

Once those PAUSE credentials are added, the workflow rebuilds the exact
versioned tarball, uploads it with CPAN::Uploader, waits for the MetaCPAN
release to become visible, and performs a clean public-CPAN install smoke.
