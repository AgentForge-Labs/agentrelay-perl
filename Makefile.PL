use 5.014;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'AgentForge::AgentRelay',
    VERSION_FROM     => 'lib/AgentForge/AgentRelay.pm',
    ABSTRACT_FROM    => 'lib/AgentForge/AgentRelay.pm',
    AUTHOR           => 'AgentForge Labs',
    LICENSE          => 'agpl_3',
    MIN_PERL_VERSION => '5.014',
    PREREQ_PM        => {
        'Digest::SHA' => 0,
        'Encode'      => 0,
        'HTTP::Tiny'  => 0,
        'JSON::PP'    => 0,
        'Time::HiRes' => 0,
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            homepage   => 'https://github.com/AgentForge-Labs/agentrelay-perl',
            repository => {
                type => 'git',
                url  => 'https://github.com/AgentForge-Labs/agentrelay-perl.git',
                web  => 'https://github.com/AgentForge-Labs/agentrelay-perl',
            },
            bugtracker => {
                web => 'https://github.com/AgentForge-Labs/agentrelay-perl/issues',
            },
        },
    },
);
