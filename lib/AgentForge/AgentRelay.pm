package AgentForge::AgentRelay;

use 5.014;
use strict;
use warnings;

use Encode qw(encode);
use HTTP::Tiny ();
use JSON::PP ();
use Time::HiRes qw(sleep time);
use Digest::SHA qw(sha256_hex);

use AgentForge::AgentRelay::Generated ();

our $VERSION = '0.1.0';
our $MANAGED_ORIGIN = 'https://relay.web-tasarimci.com';

my %RETRYABLE = map { $_ => 1 } qw(429 502 503 504);
my %PRIVATE_SEGMENT = map { $_ => 1 } qw(admin saas-admin internal webhooks payments checkout);

sub new {
    my ($class, %args) = @_;
    my $api_key = $args{api_key};
    my $bearer_token = $args{bearer_token};

    if ((!defined($api_key) || $api_key eq '') && (!defined($bearer_token) || $bearer_token eq '')) {
        die AgentForge::AgentRelay::AuthError->new(
            status      => 401,
            code        => 'AUTH_REQUIRED',
            message     => 'AgentRelay authentication is required.',
            account_url => $MANAGED_ORIGIN . '/account',
        );
    }
    die "provide exactly one API key or Bearer token\n"
        if defined($api_key) && defined($bearer_token);

    my $credential = defined($api_key) ? $api_key : $bearer_token;
    die "credential must be a non-empty scalar\n"
        if ref($credential) || !defined($credential) || $credential eq '';

    my $origin = defined($args{origin}) ? $args{origin} : $MANAGED_ORIGIN;
    $origin =~ s{/+\z}{};
    _validate_origin($origin, $args{allow_custom_origin}, $args{allow_insecure_loopback});

    my $timeout = defined($args{timeout}) ? $args{timeout} : 15;
    my $retries = defined($args{retries}) ? $args{retries} : 1;
    die "timeout must be positive\n" unless $timeout =~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ && $timeout > 0;
    die "retries must be a nonnegative integer\n" unless $retries =~ /\A\d+\z/;

    my $self = bless {
        credential => "$credential",
        origin     => $origin,
        timeout    => 0 + $timeout,
        retries    => 0 + $retries,
        user_agent => 'AgentForge-AgentRelay/' . $VERSION . ' perl',
        http       => HTTP::Tiny->new(
            timeout    => 0 + $timeout,
            verify_SSL => 1,
            agent      => 'AgentForge-AgentRelay/' . $VERSION . ' perl',
        ),
    }, $class;

    return $self;
}

sub origin { return $_[0]->{origin}; }

sub request {
    my ($self, $method, $path, %args) = @_;
    $method = uc(_scalar($method, 'method'));
    die "unsupported HTTP method\n" unless $method =~ /\A(?:GET|POST|PUT|PATCH|DELETE)\z/;

    $path = _safe_path($path);
    _scope_check($path, $args{workspace_id}, $args{agent_id});

    my $billable = $args{billable} ? 1 : 0;
    die "extension writes must declare billable => 1\n" if $method ne 'GET' && !$billable;
    die "GET cannot be billable\n" if $method eq 'GET' && $billable;

    my $idempotency_key = $args{idempotency_key};
    if ($billable) {
        $idempotency_key = _idempotency_key() unless defined($idempotency_key);
        die "invalid idempotency key length\n"
            if ref($idempotency_key) || length($idempotency_key) < 8 || length($idempotency_key) > 200;
    }

    my $query = _query_string($args{query});
    my $url = $self->{origin} . $path . ($query eq '' ? '' : '?' . $query);

    my $content;
    my $content_type = $args{content_type};
    if (exists $args{body} && defined $args{body}) {
        if (ref($args{body}) eq 'HASH') {
            $content = JSON::PP->new->canonical(1)->utf8(1)->encode($args{body});
            $content_type ||= 'application/json';
        }
        elsif (!ref($args{body})) {
            $content = $args{body};
        }
        else {
            die "body must be a hash reference, scalar bytes, or undef\n";
        }
    }

    my %headers = (
        Authorization => 'Bearer ' . $self->{credential},
        Accept        => 'application/json, application/octet-stream',
        'User-Agent'  => $self->{user_agent},
    );
    $headers{'Content-Type'} = $content_type if defined($content_type) && $content_type ne '';
    $headers{'Idempotency-Key'} = "$idempotency_key" if defined($idempotency_key);

    my $retry = $args{retry} ? 1 : 0;
    my $attempts = ($retry && ($method eq 'GET' || defined($idempotency_key)))
        ? $self->{retries} + 1
        : 1;

    ATTEMPT:
    for my $attempt (0 .. $attempts - 1) {
        my $response;
        my $ok = eval {
            my %request = (headers => \%headers);
            $request{content} = $content if defined($content);
            $response = $self->{http}->request($method, $url, \%request);
            1;
        };
        if (!$ok) {
            if ($attempt + 1 >= $attempts) {
                die AgentForge::AgentRelay::Error->new(
                    status  => 0,
                    code    => 'NETWORK_ERROR',
                    message => 'network request failed',
                );
            }
            sleep(_backoff($attempt));
            next ATTEMPT;
        }

        if ($response->{success}) {
            my $media = lc($response->{headers}{'content-type'} || '');
            my $body = defined($response->{content}) ? $response->{content} : '';
            if (index($media, 'json') >= 0 && length($body)) {
                my $decoded = eval { JSON::PP->new->utf8(1)->decode($body) };
                die AgentForge::AgentRelay::Error->new(
                    status  => 0,
                    code    => 'INVALID_RESPONSE',
                    message => 'invalid JSON response',
                ) if $@;
                return $decoded;
            }
            return $body;
        }

        my $status = 0 + ($response->{status} || 0);
        my $detail = {};
        if (defined($response->{content}) && length($response->{content})) {
            my $decoded = eval { JSON::PP->new->utf8(1)->decode($response->{content}) };
            $detail = $decoded->{error}
                if ref($decoded) eq 'HASH' && ref($decoded->{error}) eq 'HASH';
        }

        if ($status == 599 && !%{$detail}) {
            my $reason = _redact($response->{reason} || 'network request failed', $self->{credential});
            my $error = AgentForge::AgentRelay::Error->new(
                status  => 0,
                code    => 'NETWORK_ERROR',
                message => $reason,
            );
            if ($attempt + 1 >= $attempts) {
                die $error;
            }
            sleep(_backoff($attempt));
            next ATTEMPT;
        }

        my $error = _condition($status, $detail, $self->{credential});
        if ($attempt + 1 >= $attempts
            || !$RETRYABLE{$status}
            || $error->code eq 'QUOTA_EXCEEDED') {
            die $error;
        }
        sleep(_backoff($attempt));
    }

    die "unreachable\n";
}

sub call {
    my ($self, $operation_id, %args) = @_;
    $operation_id = _scalar($operation_id, 'operation_id');
    my $op = $AgentForge::AgentRelay::Generated::OPERATIONS{$operation_id}
        or die "unknown operation\n";

    my $path_values = $args{path} || {};
    die "path must be a hash reference\n" unless ref($path_values) eq 'HASH';
    my @supplied = sort keys %{$path_values};
    my @expected = sort @{ $op->{path_params} };
    die "path parameters do not match operation\n"
        unless join("\0", @supplied) eq join("\0", @expected);

    my $query = $args{query};
    if (defined($query)) {
        die "query must be a hash reference\n" unless ref($query) eq 'HASH';
        my %allowed = map { $_ => 1 } @{ $op->{query_params} };
        for my $name (keys %{$query}) {
            die "query parameters do not match operation\n" unless $allowed{$name};
        }
    }

    my $route = $op->{path};
    for my $name (@{ $op->{path_params} }) {
        my $value = _scalar($path_values->{$name}, 'path parameter');
        die "invalid path parameter\n" if index($value, '/') >= 0;
        my $encoded = _percent_encode($value);
        $route =~ s/\{\Q$name\E\}/$encoded/g;
    }

    my $body = $args{body};
    my $content_type = $args{content_type};
    if (($op->{request_media} || '') eq 'multipart/form-data') {
        die "multipart body must be a hash reference\n" unless ref($body) eq 'HASH';
        ($body, $content_type) = _multipart($body);
    }

    return $self->request(
        $op->{method},
        $route,
        workspace_id    => $path_values->{workspaceId},
        agent_id        => $path_values->{agentId},
        query           => $query,
        body            => $body,
        content_type    => (defined($content_type) ? $content_type : $op->{request_media}),
        idempotency_key => $args{idempotency_key},
        billable        => $op->{idempotent_write},
        retry           => 1,
    );
}

sub list_workspaces {
    my ($self, %args) = @_;
    my %query = (limit => defined($args{limit}) ? $args{limit} : 50);
    $query{cursor} = $args{cursor} if defined($args{cursor});
    return $self->call('listWorkspaces', query => \%query);
}

sub list_agents {
    my ($self, $workspace_id, %args) = @_;
    my %query = (limit => defined($args{limit}) ? $args{limit} : 50);
    $query{cursor} = $args{cursor} if defined($args{cursor});
    return $self->call(
        'listAgents',
        path  => { workspaceId => _scalar($workspace_id, 'workspace_id') },
        query => \%query,
    );
}

sub send_message {
    my ($self, $workspace_id, $agent_id, $text, %args) = @_;
    my $parse_mode = defined($args{parse_mode}) ? $args{parse_mode} : 'plain';
    return $self->call(
        'sendAgentMessage',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
        },
        body => {
            text      => _scalar($text, 'text'),
            parseMode => $parse_mode,
        },
        idempotency_key => $args{idempotency_key},
    );
}

sub send_notification { goto &send_message; }

sub send_file {
    my ($self, $workspace_id, $agent_id, $file, %args) = @_;
    die "file must be scalar bytes\n" if ref($file);
    my %body = (
        kind     => defined($args{kind}) ? $args{kind} : 'document',
        file     => defined($file) ? $file : '',
        filename => defined($args{filename}) ? $args{filename} : 'upload.bin',
    );
    $body{caption} = $args{caption} if defined($args{caption});
    return $self->call(
        'sendAgentFile',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
        },
        body            => \%body,
        idempotency_key => $args{idempotency_key},
    );
}

sub list_inbox {
    my ($self, $workspace_id, $agent_id, %args) = @_;
    my %query = (limit => defined($args{limit}) ? $args{limit} : 50);
    $query{cursor} = $args{cursor} if defined($args{cursor});
    return $self->call(
        'listInboxEvents',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
        },
        query => \%query,
    );
}

sub get_inbox_event {
    my ($self, $workspace_id, $agent_id, $event_id) = @_;
    return $self->call(
        'getInboxEvent',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
            eventId     => _scalar($event_id, 'event_id'),
        },
    );
}

sub reply {
    my ($self, $workspace_id, $agent_id, $event_id, $text, %args) = @_;
    my $parse_mode = defined($args{parse_mode}) ? $args{parse_mode} : 'plain';
    return $self->call(
        'replyToInboxEvent',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
            eventId     => _scalar($event_id, 'event_id'),
        },
        body => {
            text      => _scalar($text, 'text'),
            parseMode => $parse_mode,
        },
        idempotency_key => $args{idempotency_key},
    );
}

sub reply_file {
    my ($self, $workspace_id, $agent_id, $event_id, $file, %args) = @_;
    die "file must be scalar bytes\n" if ref($file);
    my %body = (
        kind     => defined($args{kind}) ? $args{kind} : 'document',
        file     => defined($file) ? $file : '',
        filename => defined($args{filename}) ? $args{filename} : 'upload.bin',
    );
    $body{caption} = $args{caption} if defined($args{caption});
    return $self->call(
        'replyToInboxEventWithFile',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
            eventId     => _scalar($event_id, 'event_id'),
        },
        body            => \%body,
        idempotency_key => $args{idempotency_key},
    );
}

sub download_file {
    my ($self, $workspace_id, $agent_id, $file_id) = @_;
    return $self->call(
        'downloadAgentFile',
        path => {
            workspaceId => _scalar($workspace_id, 'workspace_id'),
            agentId     => _scalar($agent_id, 'agent_id'),
            fileId      => _scalar($file_id, 'file_id'),
        },
    );
}

sub pages {
    my ($self, $operation_id, %args) = @_;
    my $path = $args{path} || {};
    my $limit = defined($args{limit}) ? $args{limit} : 50;
    my @items;
    my $cursor;

    while (1) {
        my %query = (limit => $limit);
        $query{cursor} = $cursor if defined($cursor) && $cursor ne '';
        my $result = $self->call($operation_id, path => $path, query => \%query);
        die AgentForge::AgentRelay::Error->new(
            status  => 0,
            code    => 'INVALID_RESPONSE',
            message => 'expected paginated response',
        ) unless ref($result) eq 'HASH' && ref($result->{items}) eq 'ARRAY';

        push @items, @{ $result->{items} };
        $cursor = $result->{nextCursor};
        last if !defined($cursor) || $cursor eq '';
    }
    return \@items;
}

sub _validate_origin {
    my ($origin, $allow_custom, $allow_loopback) = @_;
    die "origin must be an HTTPS origin\n" if $origin =~ /[\s\@?#]/;

    my $https = $origin =~ m{\Ahttps://[^/?#]+\z};
    my $loopback = $origin =~ m{\Ahttp://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?\z};
    die "origin must be an HTTPS origin\n"
        unless $https || ($allow_loopback && $loopback);
    die "custom origin requires allow_custom_origin => 1\n"
        if $origin ne $MANAGED_ORIGIN && !$allow_custom;
    return 1;
}

sub _safe_path {
    my ($path) = @_;
    $path = _scalar($path, 'path');
    die "only public v1 paths are allowed\n"
        if $path !~ m{\A/v1/} || $path =~ m{^[A-Za-z][A-Za-z0-9+.-]*://} || $path =~ /[?#]/;
    die "encoded path separators and traversal are forbidden\n"
        if $path =~ /%(?:2f|5c|2e|25)/i;

    my $decoded = _percent_decode($path);
    my @parts = split m{/}, $decoded, -1;
    die "invalid path\n"
        if index($decoded, '\\') >= 0
        || index($decoded, '//') >= 0
        || grep { $_ eq '' || $_ eq '.' || $_ eq '..' } @parts[1 .. $#parts];

    my $public = $decoded eq '/v1/service'
        || $decoded eq '/v1/workspaces'
        || index($decoded, '/v1/workspaces/') == 0;
    die "private paths are not available through the hosted client\n" unless $public;
    die "private paths are not available through the hosted client\n"
        if grep { $PRIVATE_SEGMENT{$_} } @parts;
    return $path;
}

sub _scope_check {
    my ($path, $workspace_id, $agent_id) = @_;
    my $decoded = _percent_decode($path);
    my @parts = split m{/}, $decoded, -1;

    die "workspace scope is required\n"
        if @parts >= 4 && !defined($workspace_id);
    die "agent scope is required\n"
        if @parts >= 6 && $parts[4] eq 'agents' && !defined($agent_id);
    die "workspace scope mismatch\n"
        if defined($workspace_id) && (@parts < 4 || $parts[3] ne $workspace_id);
    die "agent scope mismatch\n"
        if defined($agent_id)
        && (@parts < 6 || $parts[4] ne 'agents' || $parts[5] ne $agent_id);
    return 1;
}

sub _multipart {
    my ($fields) = @_;
    my $boundary = 'agentrelay-' . substr(sha256_hex(join(':', $$, time(), rand(), {})), 0, 40);
    my @chunks;
    my $filename = exists($fields->{filename}) ? $fields->{filename} : 'upload.bin';
    die "invalid filename\n" if !defined($filename) || ref($filename) || $filename =~ /[\r\n"\\\/]/;

    for my $name (sort keys %{$fields}) {
        next if $name eq 'filename';
        die "invalid multipart field name\n" unless $name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
        next unless defined($fields->{$name});

        my $head = '--' . $boundary . "\r\n"
            . 'Content-Disposition: form-data; name="' . $name . '"';
        my $value = $fields->{$name};

        if ($name eq 'file') {
            die "file must be scalar bytes\n" if ref($value);
            $head .= '; filename="' . $filename . '"' . "\r\n"
                . 'Content-Type: application/octet-stream';
        }
        else {
            die "multipart field must be scalar\n" if ref($value);
        }

        push @chunks, $head . "\r\n\r\n" . $value . "\r\n";
    }
    push @chunks, '--' . $boundary . "--\r\n";
    return (join('', @chunks), 'multipart/form-data; boundary=' . $boundary);
}

sub _condition {
    my ($status, $detail, $credential) = @_;
    my $code = _redact(defined($detail->{code}) ? $detail->{code} : 'HTTP_ERROR', $credential);
    my $message = _redact(defined($detail->{message}) ? $detail->{message} : 'request failed', $credential);
    my $class = 'AgentForge::AgentRelay::Error';
    $class = 'AgentForge::AgentRelay::QuotaError' if $code eq 'QUOTA_EXCEEDED';
    $class = 'AgentForge::AgentRelay::AuthError'
        if $code =~ /\A(?:UNAUTHORIZED|FORBIDDEN|AUTH_REQUIRED|INVALID_API_KEY)\z/;
    $class = 'AgentForge::AgentRelay::DeliveryError' if $code =~ /\ADELIVERY/;

    return $class->new(
        status              => $status,
        code                => $code,
        message             => $message,
        request_id          => _redact($detail->{requestId}, $credential),
        retry_after_seconds => _integer_or_undef($detail->{retryAfterSeconds}),
        upgrade_url         => _redact($detail->{upgradeUrl}, $credential),
        account_url         => _redact($detail->{accountUrl}, $credential),
        quota_used          => _integer_or_undef($detail->{quotaUsed}),
        quota_limit         => _integer_or_undef($detail->{quotaLimit}),
        quota_reset_at      => _redact($detail->{quotaResetAt}, $credential),
    );
}

sub _redact {
    my ($value, $credential) = @_;
    return undef unless defined($value);
    my $text = "$value";
    $text =~ s/\Q$credential\E/[REDACTED]/g if defined($credential) && $credential ne '';
    return $text;
}

sub _integer_or_undef {
    my ($value) = @_;
    return undef if !defined($value) || ref($value) || $value !~ /\A-?\d+\z/;
    return 0 + $value;
}

sub _idempotency_key {
    return sha256_hex(join(':', $$, time(), rand(), {}));
}

sub _backoff {
    my ($attempt) = @_;
    my $delay = 0.25 * (2 ** $attempt);
    return $delay > 2 ? 2 : $delay;
}

sub _query_string {
    my ($query) = @_;
    return '' unless defined($query);
    die "query must be a hash reference\n" unless ref($query) eq 'HASH';

    my @pairs;
    for my $name (sort keys %{$query}) {
        next unless defined($query->{$name});
        my @values = ref($query->{$name}) eq 'ARRAY'
            ? @{ $query->{$name} }
            : ($query->{$name});
        for my $value (@values) {
            die "query values must be scalar\n" if ref($value);
            push @pairs, _percent_encode($name) . '=' . _percent_encode("$value");
        }
    }
    return join('&', @pairs);
}

sub _percent_encode {
    my ($value) = @_;
    my $bytes = encode('UTF-8', "$value");
    $bytes =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge;
    return $bytes;
}

sub _percent_decode {
    my ($value) = @_;
    $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $value;
}

sub _scalar {
    my ($value, $name) = @_;
    die "$name must be a non-empty scalar string\n"
        if !defined($value) || ref($value) || "$value" eq '';
    return "$value";
}

package AgentForge::AgentRelay::Error;

use strict;
use warnings;
use overload '""' => 'as_string', fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless {
        status              => defined($args{status}) ? 0 + $args{status} : 0,
        code                => defined($args{code}) ? "$args{code}" : 'UNKNOWN',
        message             => defined($args{message}) ? "$args{message}" : 'request failed',
        request_id          => $args{request_id},
        retry_after_seconds => $args{retry_after_seconds},
        upgrade_url         => $args{upgrade_url},
        account_url         => $args{account_url},
        quota_used          => $args{quota_used},
        quota_limit         => $args{quota_limit},
        quota_reset_at      => $args{quota_reset_at},
    }, $class;
}

sub as_string {
    my ($self) = @_;
    return sprintf 'AgentRelay %s (%d): %s', $self->{code}, $self->{status}, $self->{message};
}

for my $field (qw(status code message request_id retry_after_seconds upgrade_url account_url quota_used quota_limit quota_reset_at)) {
    no strict 'refs';
    *{$field} = sub { return $_[0]->{$field}; };
}

package AgentForge::AgentRelay::AuthError;
our @ISA = ('AgentForge::AgentRelay::Error');

package AgentForge::AgentRelay::QuotaError;
our @ISA = ('AgentForge::AgentRelay::Error');

package AgentForge::AgentRelay::DeliveryError;
our @ISA = ('AgentForge::AgentRelay::Error');

package AgentForge::AgentRelay;

1;

__END__

=head1 NAME

AgentForge::AgentRelay - Official Perl client for the hosted AgentRelay service

=head1 SYNOPSIS

  use AgentForge::AgentRelay;

  my $client = AgentForge::AgentRelay->new(
      api_key => $ENV{AGENTRELAY_API_KEY},
  );

  my $delivery = $client->send_message(
      'workspace-id',
      'agent-id',
      'Build finished',
  );

=head1 DESCRIPTION

AgentForge::AgentRelay is the official thin Perl client for hosted AgentRelay.
It defaults to C<https://relay.web-tasarimci.com> and uses an AgentRelay API
key or Bearer token. Hosted quota, idempotency enforcement, routing and
delivery remain server-side.

This module is not the self-hosted AgentForge Telegram Gateway Community
Edition. Normal hosted calls never ask for Telegram bot tokens or Telegram
chat IDs and never silently fall back to localhost.

=head1 FREE ACCOUNT QUICKSTART

Create a free hosted account at
C<https://relay.web-tasarimci.com/account>. The Free plan includes 1,000
metered hosted relay operations per calendar month. Keep the API key outside
source code and pass it through an environment variable:

  export AGENTRELAY_API_KEY='...'

  use AgentForge::AgentRelay;

  my $relay = AgentForge::AgentRelay->new(
      api_key => $ENV{AGENTRELAY_API_KEY},
      timeout => 15,
      retries => 1,
  );

  $relay->send_message('workspace-id', 'agent-id', 'hello');

=head1 METHODS

=head2 new

  my $relay = AgentForge::AgentRelay->new(
      api_key => $api_key,
  );

Provide exactly one of C<api_key> or C<bearer_token>. Custom origins require
C<allow_custom_origin =E<gt> 1>; insecure HTTP is allowed only for an explicit
loopback test origin with C<allow_insecure_loopback =E<gt> 1>.

=head2 send_message

  $relay->send_message($workspace_id, $agent_id, $text);

Billable writes receive an idempotency key automatically. Pass
C<idempotency_key> to preserve identity across process restarts.

=head2 reply

  $relay->reply($workspace_id, $agent_id, $event_id, $text);

=head2 send_file

  $relay->send_file(
      $workspace_id,
      $agent_id,
      $bytes,
      filename => 'report.pdf',
      kind     => 'document',
  );

=head2 reply_file

Reply to an inbox event with multipart file bytes.

=head2 list_inbox

List inbox events with cursor pagination.

=head2 get_inbox_event

Fetch one inbox event.

=head2 download_file

Download a hosted file and return its raw byte string.

=head2 list_workspaces

List hosted workspaces.

=head2 list_agents

List agents for one workspace.

=head2 pages

Collect every page from a generated cursor-list operation and return an array
reference.

=head2 call

Invoke a generated OpenAPI operation. The operation table is pinned to the
packaged hosted contract snapshot.

=head2 request

Forward-compatible public-v1 extension point. Unknown writes must explicitly
set C<billable =E<gt> 1>; only public hosted paths are accepted.

=head1 ERRORS

API failures are thrown as objects derived from
C<AgentForge::AgentRelay::Error>. Authentication, quota and delivery failures
use C<AgentForge::AgentRelay::AuthError>,
C<AgentForge::AgentRelay::QuotaError> and
C<AgentForge::AgentRelay::DeliveryError>. Safe accessors include C<status>,
C<code>, C<request_id>, C<retry_after_seconds>, C<upgrade_url>,
C<account_url>, C<quota_used>, C<quota_limit> and C<quota_reset_at>.

Server-provided error text is credential-redacted before it is exposed.

=head1 PRODUCT BOUNDARY

The CPAN distribution is a hosted-service client. It does not contain the
AgentRelay backend, Telegram bot credentials, or the self-hosted Telegram
gateway. Installing the module is free; hosted service usage requires an
AgentRelay account and is metered server-side.

=head1 LICENSE

GNU Affero General Public License version 3 only.

=head1 AUTHOR

AgentForge Labs

=cut
