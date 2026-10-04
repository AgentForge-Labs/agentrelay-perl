use 5.014;
use strict;
use warnings;
use Test::More;
no warnings 'once';

use_ok('AgentForge::AgentRelay');
use_ok('AgentForge::AgentRelay::Generated');

is($AgentForge::AgentRelay::VERSION, '0.1.0', 'version is pinned');
is(scalar(keys %AgentForge::AgentRelay::Generated::OPERATIONS), 10, 'generated operation count');

done_testing;
