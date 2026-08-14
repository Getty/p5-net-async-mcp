package Net::Async::MCP::Transport::HTTP;
# ABSTRACT: Streamable HTTP MCP transport via Net::Async::HTTP
use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future;
use JSON::MaybeXS;
use Carp qw( croak );
use Encode qw( encode );
use MIME::Base64 qw( encode_base64 );

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

There is no session to manage. The current revision is stateless: it dropped
protocol sessions and the C<Mcp-Session-Id> header entirely, and every request
describes itself through its own C<_meta>. A conforming server must ignore that
header and never mint or echo a session ID, so this transport neither sends nor
reads one.

The revision mirrors a request's metadata into HTTP headers so that
intermediaries can route on it without parsing the body:
C<MCP-Protocol-Version>, C<Mcp-Method>, and for the three methods with a
name-ish parameter (C<tools/call>, C<prompts/get>, C<resources/read>) also
C<Mcp-Name>. The body stays the truth; this transport derives the headers from
it rather than from any state of its own, because a conforming server compares
the two and rejects a missing or diverging header with C<-32020>
(C<HEADER_MISMATCH>).

The same holds for tool arguments annotated with C<x-mcp-header> in a tool's
input schema, which travel as C<Mcp-Param-{Name}> alongside a C<tools/call>.
This transport does not go looking for them: which arguments are annotated
follows from the tool's schema, so L<Net::Async::MCP/call_tool> resolves them
and hands the finished name/value pairs to L</send_request>, which encodes them
like any other header. A server rejects a C<tools/call> that passes an
annotated argument without its header just as it rejects a header for an
argument the call did not pass.

This transport is selected automatically by L<Net::Async::MCP> when constructed
with a C<url> argument.

=cut

# The methods whose name-ish parameter is mirrored into Mcp-Name, and the
# parameter it is taken from. Same table as MCP::Client and MCP::Server's HTTP
# transport, which compares the header against exactly this field of the body.
my %NAME_PARAM = (
  'prompts/get'    => 'name',
  'resources/read' => 'uri',
  'tools/call'     => 'name',
);

sub _init {
  my ( $self, $params ) = @_;
  $self->{url} = delete $params->{url}
    or croak "url is required";
  $self->{next_id} = 0;
  $self->{json}    = JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1);
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
  my ( $self, $method, $params, %options ) = @_;

  my $id = ++$self->{next_id};
  my $request = {
    jsonrpc => '2.0',
    id      => $id,
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $body = $self->{json}->encode($request);

  require HTTP::Request;
  my $http_req = HTTP::Request->new(
    POST => $self->{url},
    [ $self->_standard_headers($method, $params, %options) ],
    $body,
  );

  return $self->{http}->do_request(request => $http_req)->then(sub {
    my ( $response ) = @_;
    return $self->_handle_response($response);
  });
}

=method send_request

    my $future = $transport->send_request($method, \%params);
    my $future = $transport->send_request($method, \%params,
        header_params => [ { name => 'Region', value => 'europe-west1' } ]);

Sends a JSON-RPC request as an HTTP POST to the MCP endpoint. The request
includes C<Accept: application/json, text/event-stream> to support both
direct JSON responses and SSE streams, plus the metadata headers derived from
the body as described above.

Optional trailing name/value options carry binding hints the body cannot
express. Only C<header_params> is defined: an ArrayRef of hashrefs with C<name>
and C<value>, one per tool argument annotated with C<x-mcp-header>, which this
transport sends as C<Mcp-Param-{Name}>. The value arrives formatted the way the
server compares it - L<Net::Async::MCP/call_tool> resolves it from the tool's
input schema - and this transport only encodes it for the wire.

Returns a L<Future> that resolves to the C<result> value from the JSON-RPC
response. Handles both C<application/json> and C<text/event-stream> response
content types.

If the server answers with a non-2xx status, a JSON-RPC error in the body wins
over the status: MCP servers render errors such as C<METHOD_NOT_FOUND> with a
404 and a rejected C<_meta> with a 400, so the future fails with that
C<MCP error $code: $message>. A non-2xx without a JSON-RPC error body fails
with the HTTP status line.

An C<error> member that is not a JSON-RPC error object - a bare string, as
L<MCP::Server>'s own HTTP transport renders its refusals, or whatever shape a
gateway in between invents - fails the L<Future> as well, carrying the text the
body held.

=cut

sub send_notification {
  my ( $self, $method, $params ) = @_;

  my $request = {
    jsonrpc => '2.0',
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $body = $self->{json}->encode($request);

  require HTTP::Request;
  my $http_req = HTTP::Request->new(
    POST => $self->{url},
    [ $self->_standard_headers($method, $params) ],
    $body,
  );

  return $self->{http}->do_request(request => $http_req)->then(sub {
    my ( $response ) = @_;
    return $self->_handle_notification_response($response);
  });
}

=method send_notification

    my $future = $transport->send_notification($method, \%params);

Sends a JSON-RPC notification (no C<id> field, no response expected) as an
HTTP POST. The server typically responds with HTTP 202 Accepted. Returns a
L<Future> that resolves once the HTTP request completes with a 2xx status,
whether or not it carries a body: a notification has no answer this client
would read.

A non-2xx status fails the returned L<Future>, with the same precedence as on
the request path: a JSON-RPC error in the body wins over the status, and only a
body without one falls back to the HTTP status line.

The revision defines no header requirements for notification POSTs, so a
notification carries whatever its body supports and nothing more: always
C<Mcp-Method>, and C<MCP-Protocol-Version> only when the notification has an
C<_meta> to take it from.

=cut

sub close { Future->done }

=method close

    my $future = $transport->close;

No-op for the HTTP transport: there is no session to terminate, since the
current revision is stateless and each request stands on its own. A server on
this revision answers C<DELETE> on the MCP endpoint with C<405 Method Not
Allowed>, so nothing is sent. Returns an immediately resolved L<Future>.

=cut

sub is_alive { 1 }

=method is_alive

    my $alive = $transport->is_alive;

Always true: the transport holds no connection between requests, so a dead
endpoint only shows up when a request is actually made. Used by
L<Net::Async::MCP/ping> for its transport-level liveness check.

=cut

sub mirrors_header_params { 1 }

=method mirrors_header_params

    my $mirrors = $transport->mirrors_header_params;

Always true: this binding mirrors tool arguments annotated with
C<x-mcp-header> into C<Mcp-Param-{Name}> headers, so
L<Net::Async::MCP/call_tool> has to resolve them from the tool's input schema
before calling L</send_request> - and is worth fetching a tool list for when it
does not know the schema yet. The other transports answer false and are spared
that request.

=cut

# The metadata headers every POST carries. They are read back out of the body
# instead of out of transport state so that the two cannot drift apart: the
# server compares header against body and answers -32020 when they differ.
sub _standard_headers {
  my ( $self, $method, $params, %options ) = @_;

  $params = {} unless ref $params eq 'HASH';

  my @headers = (
    'Content-Type' => 'application/json',
    'Accept'       => 'application/json, text/event-stream',
  );

  # Absent for a request built without _meta, and for a notification sent
  # through send_notification with no params at all - this client sends none
  # itself, but the method stays open to callers. Sending a made up version
  # would be worse than sending none: the server only compares what it gets.
  my $version = ($params->{_meta} // {})->{'io.modelcontextprotocol/protocolVersion'};
  push @headers, 'MCP-Protocol-Version' => $version if defined $version;

  push @headers, 'Mcp-Method' => $method;

  if (my $key = $NAME_PARAM{$method}) {
    push @headers, 'Mcp-Name' => $self->_encode_header($params->{$key} // '');
  }

  # Tool arguments annotated with x-mcp-header, already resolved and formatted
  # by the client: which arguments these are and what they look like is MCP
  # semantics, only the wire form is this transport's business. They travel
  # through the same sentinel encoding as Mcp-Name, which is what the server
  # undoes before comparing.
  for my $param (@{ $options{header_params} // [] }) {
    push @headers,
      "Mcp-Param-$param->{name}" => $self->_encode_header($param->{value} // '');
  }

  return @headers;
}

# A header value that is not printable ASCII travels base64 encoded in a
# sentinel, as does one that already looks like the sentinel itself, which
# would otherwise be decoded by the server into something the body never said.
sub _encode_header {
  my ( $self, $value ) = @_;

  return $value
    if $value =~ /^[\x20-\x7e]*\z/ && $value !~ /^=\?base64\?.*\?=$/;

  return '=?base64?' . encode_base64(encode('UTF-8', $value), '') . '?=';
}

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

    return Future->fail("MCP HTTP error: " . $response->status_line);
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

# A notification is answered with a status and nothing this client reads, so
# the status is all there is to judge - 202 Accepted with an empty body is the
# normal case. Deliberately not routed through _handle_response, which would
# fail exactly that empty body as invalid JSON.
sub _handle_notification_response {
  my ( $self, $response ) = @_;

  return Future->done if $response->is_success;

  if (my $error = $self->_jsonrpc_error_from_body($response)) {
    return Future->fail($error);
  }

  return Future->fail("MCP HTTP error: " . $response->status_line);
}

sub _jsonrpc_error_from_body {
  my ( $self, $response ) = @_;

  my $body = eval { $response->decoded_content(charset => 'none') };
  return undef unless defined $body && length $body;

  my $data = eval { $self->{json}->decode($body) };
  return $self->_jsonrpc_error_message($data);
}

# The failure message for a decoded body that carries a JSON-RPC error object,
# and undef for anything else. Not every JSON error body is a JSON-RPC one: an
# MCP server answers a bad method with {error => 'Method not allowed'}, and a
# gateway in between may invent its own shape, so the shape is checked before
# it is read as an object.
sub _jsonrpc_error_message {
  my ( $self, $data ) = @_;

  return undef unless ref $data eq 'HASH';

  my $err = $data->{error};
  return undef unless ref $err eq 'HASH' && defined $err->{code};

  return "MCP error $err->{code}: " . ($err->{message} // '(no message)');
}

# A body that says "error" in a shape this client cannot read as JSON-RPC still
# says the request failed. Report it as a failure carrying whatever text it
# holds rather than reaching into it as if it were an object.
sub _foreign_error_message {
  my ( $self, $err ) = @_;

  my $text = ref $err ? eval { $self->{json}->encode($err) } // 'unknown error' : $err;
  return "MCP HTTP error response: $text";
}

sub _handle_json_response {
  my ( $self, $body ) = @_;

  my $data = eval { $self->{json}->decode($body) };
  return Future->fail("MCP HTTP invalid JSON: $@") if $@;
  return Future->fail("MCP HTTP invalid response") unless ref $data eq 'HASH';

  if (defined(my $err = $data->{error})) {
    return Future->fail($self->_jsonrpc_error_message($data)
      // $self->_foreign_error_message($err));
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

  if (defined(my $err = $last_data->{error})) {
    return Future->fail($self->_jsonrpc_error_message($last_data)
      // $self->_foreign_error_message($err));
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
