use 5.014;
use strict;
use warnings;
use Test::More;

use AgentForge::AgentRelay;

my $client = AgentForge::AgentRelay->new(api_key => 'example-only');
isa_ok($client, 'AgentForge::AgentRelay');
is($client->origin, 'https://relay.web-tasarimci.com', 'managed origin is default');

my $missing = eval { AgentForge::AgentRelay->new(); 1 };
ok(!$missing, 'missing auth fails');
isa_ok($@, 'AgentForge::AgentRelay::AuthError');
is($@->code, 'AUTH_REQUIRED', 'missing auth has structured code');

my $double = eval {
    AgentForge::AgentRelay->new(api_key => 'a', bearer_token => 'b');
    1;
};
ok(!$double, 'two credentials rejected');
like("$@", qr/exactly one/, 'credential error explains requirement');

my $bad_origin = eval {
    AgentForge::AgentRelay->new(
        api_key             => 'a',
        origin              => 'http://example.test',
        allow_custom_origin => 1,
    );
    1;
};
ok(!$bad_origin, 'insecure non-loopback origin rejected');

my $loopback = AgentForge::AgentRelay->new(
    api_key                 => 'a',
    origin                  => 'http://127.0.0.1:9999',
    allow_custom_origin     => 1,
    allow_insecure_loopback => 1,
);
is($loopback->origin, 'http://127.0.0.1:9999', 'loopback test origin requires explicit opt-in');

my $unsafe = eval {
    $client->request(
        'GET',
        '/v1/workspaces/w1/agents/a1/../../admin',
        workspace_id => 'w1',
        agent_id     => 'a1',
    );
    1;
};
ok(!$unsafe, 'path traversal rejected');

my $write = eval {
    $client->request(
        'POST',
        '/v1/workspaces/w1/agents/a1/future',
        workspace_id => 'w1',
        agent_id     => 'a1',
        body         => { x => 1 },
    );
    1;
};
ok(!$write, 'extension writes require billable declaration');
like("$@", qr/billable/, 'billable requirement is explicit');

done_testing;
