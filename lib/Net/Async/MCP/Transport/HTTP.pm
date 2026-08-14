package Net::Async::MCP::Transport::HTTP;
# ABSTRACT: Streamable HTTP MCP transport via Net::Async::HTTP
use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future;
use JSON::MaybeXS;
use Carp qw( croak );
use Encode qw( encode is_utf8 );
use MIME::Base64 qw( encode_base64 );
use Scalar::Util qw( blessed );

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

my $DEFAULT_STALL_TIMEOUT = 60;

sub _init {
  my ( $self, $params ) = @_;
  $self->{url} = delete $params->{url}
    or croak "url is required";
  # exists, not defined: an explicit undef is a caller switching a timeout off,
  # and has to survive the default applied below.
  for my $key (qw( headers timeout stall_timeout )) {
    $self->{$key} = delete $params->{$key} if exists $params->{$key};
  }
  $self->{stall_timeout} = $DEFAULT_STALL_TIMEOUT
    unless exists $self->{stall_timeout};
  $self->{next_id} = 0;
  $self->{json}    = JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1);
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  if (exists $params{url}) {
    $self->{url} = delete $params{url};
  }
  $self->{headers} = delete $params{headers} if exists $params{headers};
  $self->{on_notification} = delete $params{on_notification}
    if exists $params{on_notification};
  for my $key (qw( timeout stall_timeout )) {
    next unless exists $params{$key};
    $self->{$key} = delete $params{$key};
    # Only once this transport has joined a loop is there an HTTP client to
    # reconfigure; before that _add_to_loop picks the values up itself.
    $self->{http}->configure($key => $self->{$key}) if $self->{http};
  }
  $self->SUPER::configure(%params);
}

sub _add_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_add_to_loop($loop);

  require Net::Async::HTTP;

  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 0,
    timeout                  => $self->{timeout},
    stall_timeout            => $self->{stall_timeout},
  );
  $self->{http} = $http;
  $self->add_child($http);
}

=method new

    my $transport = Net::Async::MCP::Transport::HTTP->new(
        url     => 'https://example.com/mcp',
        headers => { Authorization => "Bearer $token" },
    );

Constructs a new HTTP transport. C<url> is required and names the MCP endpoint
every request is POSTed to. Usually not called directly: L<Net::Async::MCP>
builds this transport itself and passes the same arguments through, so a caller
configures them there.

C<headers> is a HashRef of headers added to every POST - the place for
everything the protocol does not describe, an C<Authorization: Bearer ...> for
a server behind OAuth above all. They go on the request underneath the headers
this transport derives from the body, so a caller can add its own but cannot
replace C<MCP-Protocol-Version>, C<Mcp-Method>, C<Mcp-Name> or an
C<Mcp-Param-{Name}>: a header that disagrees with the body is exactly what a
conforming server answers with C<-32020>. A colliding header is dropped rather
than sent alongside the derived one, which would be the same divergence in
another shape.

C<timeout> and C<stall_timeout> are handed to the underlying
L<Net::Async::HTTP>, in seconds. C<stall_timeout> defaults to 60 and is the
only one with a default: it fires when a request spends that long without a
single byte moving in either direction, which is the hung connection a client
cannot otherwise notice, and it does not touch a request that is still making
progress. C<timeout>, the wall-clock limit on a whole request, deliberately has
no default - an MCP C<tools/call> may legitimately run for minutes, so a
default here would break working setups rather than protect them, and only a
caller that knows its own upper bound can pick one.

Pass C<stall_timeout> as C<0> (or C<undef>) to switch the stall timeout off.
C<timeout> is off unless set, and has to stay C<undef> to stay off: a
C<timeout> of C<0> is a real limit of zero seconds that fails every request
immediately.

=cut

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

  return $self->{http}->do_request(
    request   => $http_req,
    on_header => sub { $self->_response_reader(@_) },
  )->then(sub {
    my ( $outcome ) = @_;

    # Both body readers end in the Future for the JSON-RPC outcome, and
    # Net::Async::HTTP passes whatever they return through as the result of
    # its own. A response object instead means the body never reached them:
    # a redirect, which it consumes itself rather than handing over - it does
    # not follow one for a POST, so this is where a redirected endpoint ends
    # up, and the status line is all there is to report.
    return $outcome if blessed($outcome) && $outcome->isa('Future');
    return $self->_handle_response($outcome);
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

An C<application/json> answer is read whole, as there is nothing to read
before it is complete. A C<text/event-stream> is read as it arrives instead,
because a server may send C<notifications/progress> and
C<notifications/message> on the stream of a long running request before the
response it answers with: an event carrying no C<id> is such a notification
and is delivered to L</on_notification> the moment it lands, an event with an
C<id> and a C<result> or C<error> is the response and settles the L<Future>. A
stream that ends without one fails it with C<MCP HTTP no JSON-RPC response in
SSE stream>.

If the server answers with a non-2xx status, a JSON-RPC error in the body wins
over the status: MCP servers render errors such as C<METHOD_NOT_FOUND> with a
404 and a rejected C<_meta> with a 400, so the future fails with that
C<MCP error $code: $message>. A non-2xx without a JSON-RPC error body fails
with the HTTP status line.

An C<error> member that is not a JSON-RPC error object - a bare string, as
L<MCP::Server>'s own HTTP transport renders its refusals, or whatever shape a
gateway in between invents - fails the L<Future> as well, carrying the text the
body held.

A JSON-RPC error fails the L<Future> with more than its message, wherever in
the body or the stream it was found. L<Future>'s failure convention is
C<< ( $message, $category, @details ) >>, so the failure reads
C<< ( "MCP error $code: $message", 'mcp', $error ) >>: in scalar context
C<< ->failure >> is the message and nothing has changed, and in list context
the raw JSON-RPC error object comes with it.

    my ( $message, $category, $error ) = $future->failure;
    if (($category // '') eq 'mcp') {
      my $code      = $error->{code};          # -32601, -32602, ...
      my $supported = $error->{data}{supported};
    }

The C<mcp> category marks a genuine JSON-RPC error from the server and nothing
else. The failures around it - the HTTP status line, an unreadable or
unexpected body, the foreign C<error> shape above, and a stream that ended
without a response - carry their message alone, so a caller that finds no
category knows there is no server error object behind it.

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
body without one falls back to the HTTP status line. Such an error carries the
C<mcp> category and the raw error object like any other, as described under
L</send_request>.

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

=attr on_notification

    my $transport = Net::Async::MCP::Transport::HTTP->new(
        url             => 'https://example.com/mcp',
        on_notification => sub {
            my ( $transport, $notification ) = @_;
            warn "$notification->{method}\n";
        },
    );

Invoked for every server-initiated notification that arrives on the response
stream of a request, with the decoded JSON-RPC notification as it stood on the
wire - C<method> and, where the notification has any, C<params>. The
C<notifications/progress> of a running C<tools/call> is what a caller usually
waits for here, and it is only worth anything while the call is still running,
which is why it is an event and not part of the L<Future> the call resolves
with.

Set through C<new> or C<configure> like any L<IO::Async::Notifier> event, or
by a subclass implementing a method of this name. Notifications are dropped
while nothing handles them: a server sends them whether or not this client
asked, and there is nothing sensible to do with one no caller wants.

=cut

# Net::Async::HTTP hands the response header over as soon as it has it and
# takes the callback for the body in return, so this is where the content type
# decides how the body is read: an event stream carries notifications the
# server sends before its response and has to be read as it arrives, while
# every other body says nothing until it is complete and is judged whole.
sub _response_reader {
  my ( $self, $header ) = @_;

  return $self->_sse_reader
    if $header->is_success
    && ($header->content_type // '') =~ m{^text/event-stream}i;

  return sub {
    return $header->add_content(@_) if @_;
    return $self->_handle_response($header);
  };
}

# Reads an SSE body as it arrives. Returns the callback Net::Async::HTTP feeds
# the body to: once per chunk of bytes as it lands, and once with no arguments
# at the end of the stream, where whatever it returns becomes the result of the
# request's Future - here the Future the JSON-RPC outcome is reported through.
#
# A chunk ends wherever the network put it, mid-line and mid-character
# included, so nothing leaves the buffer before its newline has arrived and
# nothing is decoded before its event is complete.
sub _sse_reader {
  my ( $self ) = @_;

  my $buffer = '';
  my @data;
  my $response;

  # One line of the stream, its newline already taken off. A blank line ends
  # an event, a line opening with a colon is a comment - the shape of the
  # keep-alives a server sends to hold an idle stream open - and every other
  # line is a field, of which this client reads only "data".
  my $line = sub {
    my ( $text ) = @_;

    $text =~ s/\r\z//;

    if (length $text) {
      return if $text =~ /^:/;
      my ( $field, $value ) = split /:/, $text, 2;
      return unless defined $field && $field eq 'data';
      $value = '' unless defined $value;
      $value =~ s/^ //;
      push @data, $value;
      return;
    }

    my $event = join "\n", @data;
    @data = ();
    return unless length $event;

    # Not every event is JSON-RPC this client can use, and one that is not is
    # no reason to abandon a stream that still owes it a response.
    my $decoded = eval { $self->{json}->decode($event) };
    return unless ref $decoded eq 'HASH';

    # An event that answers no request is a notification. One that does keeps
    # the first response it carries: a stream holds the answer to exactly one
    # request, and what comes after cannot make an earlier answer untrue. An
    # id without a result or an error is a server-initiated request, which
    # this client does not answer, so it is dropped.
    return $self->maybe_invoke_event(on_notification => $decoded)
      unless exists $decoded->{id};

    $response = $decoded
      if !$response && (exists $decoded->{result} || exists $decoded->{error});

    return;
  };

  return sub {
    unless (@_) {
      # The end of the stream terminates whatever it interrupted: a server
      # that closed right behind its last data line still said it.
      $line->($buffer) if length $buffer;
      $buffer = '';
      $line->('');
      return $self->_sse_result($response);
    }

    my ( $chunk ) = @_;
    return unless defined $chunk;

    # The JSON decoder has utf8 => 1 and wants bytes, which is what
    # Net::Async::HTTP hands over. Characters would be decoded a second time
    # and every non-ASCII event lost to the failed decode above.
    $chunk = encode('UTF-8', $chunk) if is_utf8($chunk);

    $buffer .= $chunk;
    $line->($1) while $buffer =~ s/^([^\n]*)\n//;

    return;
  };
}

# The outcome of a finished SSE stream: the response event it carried, or the
# failure of a stream that ended without one.
sub _sse_result {
  my ( $self, $data ) = @_;

  return Future->fail("MCP HTTP no JSON-RPC response in SSE stream")
    unless $data;

  if (defined(my $err = $data->{error})) {
    my @failure = $self->_jsonrpc_error_failure($data);
    return Future->fail(@failure) if @failure;
    return Future->fail($self->_foreign_error_message($err));
  }

  return Future->done($data->{result});
}

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

  # The caller's own headers go first and the derived ones after, so an
  # Authorization can be added while an Mcp-Method cannot be taken over.
  return ( $self->_caller_headers(@headers), @headers );
}

# The headers configured on this transport, minus every field the request
# derives from its body. Dropping them is not the same as ordering them:
# HTTP::Headers keeps a field given twice in one list as two values of one
# header rather than letting the later win, so a colliding caller header would
# travel alongside the derived one and diverge from the body just as visibly.
sub _caller_headers {
  my ( $self, @derived ) = @_;

  my $headers = $self->{headers};
  return () unless ref $headers eq 'HASH';

  my %derived;
  for (my $i = 0; $i < @derived; $i += 2) {
    $derived{ lc $derived[$i] } = 1;
  }

  return map  { $_ => $headers->{$_} }
         grep { !$derived{ lc $_ } }
         sort keys %$headers;
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
    if (my @failure = $self->_jsonrpc_error_from_body($response)) {
      return Future->fail(@failure);
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

  if (my @failure = $self->_jsonrpc_error_from_body($response)) {
    return Future->fail(@failure);
  }

  return Future->fail("MCP HTTP error: " . $response->status_line);
}

sub _jsonrpc_error_from_body {
  my ( $self, $response ) = @_;

  my $body = eval { $response->decoded_content(charset => 'none') };
  return () unless defined $body && length $body;

  my $data = eval { $self->{json}->decode($body) };
  return $self->_jsonrpc_error_failure($data);
}

# The Future->fail arguments for a decoded body that carries a JSON-RPC error
# object, and the empty list for anything else. Not every JSON error body is a
# JSON-RPC one: an MCP server answers a bad method with
# {error => 'Method not allowed'}, and a gateway in between may invent its own
# shape, so the shape is checked before it is read as an object.
#
# The message alone cannot carry a code to switch on or an error->{data} to
# read, so the raw error object travels with it as the details of a failure in
# category "mcp". The message stays the first element, so a caller reading the
# failure in scalar context sees exactly what it saw before.
sub _jsonrpc_error_failure {
  my ( $self, $data ) = @_;

  return () unless ref $data eq 'HASH';

  my $err = $data->{error};
  return () unless ref $err eq 'HASH' && defined $err->{code};

  return (
    "MCP error $err->{code}: " . ($err->{message} // '(no message)'),
    mcp => $err,
  );
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
    my @failure = $self->_jsonrpc_error_failure($data);
    return Future->fail(@failure) if @failure;
    return Future->fail($self->_foreign_error_message($err));
  }

  return Future->done($data->{result});
}

# A whole SSE body in hand rather than a stream to read from, which is the
# same events through the same reader, all at once. Only a caller holding a
# complete response gets here: a streamed one is read by _sse_reader itself.
sub _handle_sse_response {
  my ( $self, $body ) = @_;

  my $read = $self->_sse_reader;
  $read->($body);
  return $read->();
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
