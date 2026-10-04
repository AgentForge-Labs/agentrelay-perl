# AgentForge::AgentRelay

Official Perl client for the **hosted AgentRelay** service.

## Install

After the CPAN release is activated:

~~~bash
cpanm AgentForge::AgentRelay
~~~

or:

~~~bash
cpan AgentForge::AgentRelay
~~~

The distribution name is `AgentForge-AgentRelay`.

## Free hosted account

Create a free account at `https://relay.web-tasarimci.com/account`. The Free
plan includes 1,000 metered hosted relay operations per calendar month. Keep
the API key outside source code:

~~~bash
export AGENTRELAY_API_KEY='...'
~~~

~~~perl
use AgentForge::AgentRelay;

my $relay = AgentForge::AgentRelay->new(
    api_key => $ENV{AGENTRELAY_API_KEY},
);

$relay->send_message('workspace-id', 'agent-id', 'Build finished');
~~~

Billable writes automatically receive an idempotency key and retries preserve
that same key. A caller-provided `idempotency_key` can preserve identity
across process restarts.

## Product boundary

This is a thin client for the AgentForge-managed AgentRelay service. It is not
the self-hosted AgentForge Telegram Gateway Community Edition. Normal hosted
calls do not require Telegram bot tokens or Telegram chat IDs and do not fall
back to localhost.

The package contains no AgentRelay backend or hosted service credentials.
Quota and delivery enforcement remain server-side.

## Development

~~~bash
perl Makefile.PL
make test
make dist
make disttest
~~~

The runtime dependencies are Perl core modules on supported Perl versions.

## License

GNU Affero General Public License v3.0 only.
