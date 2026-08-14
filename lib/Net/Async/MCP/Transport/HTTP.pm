package Net::Async::MCP::Transport::HTTP;
# ABSTRACT: Streamable HTTP MCP transport via Net::Async::HTTP
use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future;
use JSON::MaybeXS;
use Carp qw( croak );

=head1 SYNOPSIS

    # Usually created automatically by Net::Async::MCP
    use IO::Async::Loop;
    use Net::Async::MCP;

    my $loop = IO::Async::Loop->new;
    my $mcp = Net::Async::MCP->new(
        url => 'https://example.com/mcp',
    );
    $loop->add($mcp);

=head1 DESCRIPTION

L<Net::Async::MCP::Transport::HTTP> communicates with a remote MCP server
over HTTP using the Streamable HTTP transport defined in the MCP specification
(2026-07-28). Requests are sent as HTTP POST with JSON-RPC bodies, and
responses may arrive as either C<application/json> or C<text/event-stream>
(Server-Sent Events).

Session management is handled automatically via the C<Mcp-Session-Id> header.
If the server assigns a session ID during initialization, it is included in
all subsequent requests.

This transport is selected automatically by L<Net::Async::MCP> when constructed
with a C<url> argument.

=cut

sub _init {
  my ( $self, $params ) = @_;
  $self->{url} = delete $params->{url}
    or croak "url is required";
  $self->{next_id}    = 0;
  $self->{session_id} = undef;
  $self->{json}       = JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1);
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  if (exists $params{url}) {
    $self->{url} = delete $params{url};
  }
  $self->SUPER::configure(%params);
}

sub _add_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_add_to_loop($loop);

  require Net::Async::HTTP;

  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 0,
  );
  $self->{http} = $http;
  $self->add_child($http);
}

sub send_request {
  my ( $self, $method, $params ) = @_;

  my $id = ++$self->{next_id};
  my $request = {
    jsonrpc => '2.0',
    id      => $id,
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $body = $self->{json}->encode($request);

  my @headers = (
    'Content-Type' => 'application/json',
    'Accept'       => 'application/json, text/event-stream',
  );
  if (defined $self->{session_id}) {
    push @headers, 'Mcp-Session-Id' => $self->{session_id};
  }

  require HTTP::Request;
  my $http_req = HTTP::Request->new(
    POST => $self->{url},
    [ @headers ],
    $body,
  );

  return $self->{http}->do_request(request => $http_req)->then(sub {
    my ( $response ) = @_;
    return $self->_handle_response($response);
  });
}

=method send_request

    my $future = $transport->send_request($method, \%params);

Sends a JSON-RPC request as an HTTP POST to the MCP endpoint. The request
includes C<Accept: application/json, text/event-stream> to support both
direct JSON responses and SSE streams.

Returns a L<Future> that resolves to the C<result> value from the JSON-RPC
response. Handles both C<application/json> and C<text/event-stream> response
content types.

If the server answers with a non-2xx status, a JSON-RPC error in the body wins
over the status: MCP servers render errors such as C<METHOD_NOT_FOUND> with a
404 and a rejected C<_meta> with a 400, so the future fails with that
C<MCP error $code: $message>. A 404 without a JSON-RPC error body is treated as
an expired session and drops the stored session ID; any other status without a
JSON-RPC error body fails with the HTTP status line.

=cut

sub send_notification {
  my ( $self, $method, $params ) = @_;

  my $request = {
    jsonrpc => '2.0',
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $body = $self->{json}->encode($request);

  my @headers = (
    'Content-Type' => 'application/json',
    'Accept'       => 'application/json, text/event-stream',
  );
  if (defined $self->{session_id}) {
    push @headers, 'Mcp-Session-Id' => $self->{session_id};
  }

  require HTTP::Request;
  my $http_req = HTTP::Request->new(
    POST => $self->{url},
    [ @headers ],
    $body,
  );

  return $self->{http}->do_request(request => $http_req)->then(sub {
    return Future->done;
  });
}

=method send_notification

    my $future = $transport->send_notification($method, \%params);

Sends a JSON-RPC notification (no C<id> field, no response expected) as an
HTTP POST. The server typically responds with HTTP 202 Accepted. Returns an
immediately resolved L<Future> once the HTTP request completes.

=cut

sub close {
  my ( $self ) = @_;

  if (defined $self->{session_id}) {
    require HTTP::Request;
    my $http_req = HTTP::Request->new(
      DELETE => $self->{url},
      [ 'Mcp-Session-Id' => $self->{session_id} ],
    );
    return $self->{http}->do_request(request => $http_req)->then(sub {
      $self->{session_id} = undef;
      return Future->done;
    })->else(sub {
      $self->{session_id} = undef;
      return Future->done;
    });
  }

  return Future->done;
}

=method close

    my $future = $transport->close;

Terminates the MCP session by sending an HTTP DELETE request to the MCP
endpoint with the C<Mcp-Session-Id> header. If no session is active, returns
an immediately resolved L<Future>.

=cut

sub is_alive { 1 }

=method is_alive

    my $alive = $transport->is_alive;

Always true: the transport holds no connection between requests, so a dead
endpoint only shows up when a request is actually made. Used by
L<Net::Async::MCP/ping> for its transport-level liveness check.

=cut

sub _handle_response {
  my ( $self, $response ) = @_;

  my $status = $response->code;

  unless ($response->is_success) {
    # An MCP server renders JSON-RPC errors with a non-2xx status taken from
    # the request context (400 for a rejected _meta, 403 for insufficient
    # scope, 404 for METHOD_NOT_FOUND), so the body carries the real error and
    # must win over the HTTP status. Only a non-2xx without a JSON-RPC error
    # body is an HTTP-level problem.
    if (my $error = $self->_jsonrpc_error_from_body($response)) {
      return Future->fail($error);
    }

    if ($status == 404) {
      $self->{session_id} = undef;
      return Future->fail("MCP session expired (HTTP 404)");
    }

    return Future->fail("MCP HTTP error: " . $response->status_line);
  }

  # Capture session ID from response headers
  my $session_id = $response->header('Mcp-Session-Id');
  if (defined $session_id) {
    $self->{session_id} = $session_id;
  }

  my $content_type = $response->content_type // '';

  # charset => 'none' undoes Content-Encoding but leaves the body as UTF-8
  # bytes, which is what the JSON decoder below expects; letting
  # decoded_content apply the charset too would decode text/event-stream twice.
  if ($content_type =~ m{^application/json}i) {
    return $self->_handle_json_response($response->decoded_content(charset => 'none'));
  }
  elsif ($content_type =~ m{^text/event-stream}i) {
    return $self->_handle_sse_response($response->decoded_content(charset => 'none'));
  }

  # 202 Accepted with no body (for notifications/responses)
  if ($status == 202) {
    return Future->done(undef);
  }

  return Future->fail("MCP HTTP unexpected content-type: $content_type");
}

sub _jsonrpc_error_from_body {
  my ( $self, $response ) = @_;

  my $body = eval { $response->decoded_content(charset => 'none') };
  return undef unless defined $body && length $body;

  my $data = eval { $self->{json}->decode($body) };
  return undef unless ref $data eq 'HASH';

  # Not every JSON error body is a JSON-RPC one: an MCP server answers a bad
  # method with {error => 'Method not allowed'}, and a gateway in between may
  # invent its own shape.
  my $err = $data->{error};
  return undef unless ref $err eq 'HASH' && defined $err->{code};

  return "MCP error $err->{code}: $err->{message}";
}

sub _handle_json_response {
  my ( $self, $body ) = @_;

  my $data = eval { $self->{json}->decode($body) };
  return Future->fail("MCP HTTP invalid JSON: $@") if $@;
  return Future->fail("MCP HTTP invalid response") unless ref $data eq 'HASH';

  if (my $err = $data->{error}) {
    return Future->fail("MCP error $err->{code}: $err->{message}");
  }

  return Future->done($data->{result});
}

sub _handle_sse_response {
  my ( $self, $body ) = @_;

  # Parse SSE events, find the JSON-RPC response
  my $last_data;
  for my $line (split /\n/, $body) {
    if ($line =~ /^data:\s*(.+)/) {
      my $data_str = $1;
      my $data = eval { $self->{json}->decode($data_str) };
      next unless $data && ref $data eq 'HASH';
      # Look for a JSON-RPC response (has id and result/error)
      if (exists $data->{id} && (exists $data->{result} || exists $data->{error})) {
        $last_data = $data;
      }
    }
  }

  return Future->fail("MCP HTTP no JSON-RPC response in SSE stream")
    unless $last_data;

  if (my $err = $last_data->{error}) {
    return Future->fail("MCP error $err->{code}: $err->{message}");
  }

  return Future->done($last_data->{result});
}

=seealso

=over 4

=item * L<Net::Async::MCP> - Main client module that uses this transport

=item * L<Net::Async::MCP::Transport::InProcess> - Alternative transport for in-process Perl servers

=item * L<Net::Async::MCP::Transport::Stdio> - Alternative transport for external subprocesses

=item * L<Net::Async::HTTP> - HTTP client used internally

=item * L<https://modelcontextprotocol.io/specification/2026-07-28/basic/transports> - MCP Streamable HTTP transport specification

=back

=cut

1;
