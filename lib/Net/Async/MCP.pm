package Net::Async::MCP;
# ABSTRACT: Async MCP (Model Context Protocol) client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use Carp qw( croak );
use Scalar::Util qw( looks_like_number );

our $VERSION = '0.004';

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Net::Async::MCP;
    use Future::AsyncAwait;

    my $loop = IO::Async::Loop->new;

    # In-process transport (Perl MCP::Server in same process)
    use MCP::Server;
    my $server = MCP::Server->new(name => 'MyServer');
    $server->tool(
        name         => 'echo',
        description  => 'Echo text',
        input_schema => {
            type       => 'object',
            properties => { message => { type => 'string' } },
            required   => ['message'],
        },
        code => sub { return "Echo: $_[1]->{message}" },
    );

    my $mcp = Net::Async::MCP->new(server => $server);
    $loop->add($mcp);

    # Stdio transport (external MCP server subprocess)
    my $mcp_stdio = Net::Async::MCP->new(
        command => ['npx', '@anthropic/mcp-server-web-search'],
    );
    $loop->add($mcp_stdio);

    # HTTP transport (remote MCP server)
    my $mcp_http = Net::Async::MCP->new(
        url     => 'https://example.com/mcp',
        headers => { Authorization => "Bearer $token" },
    );
    $loop->add($mcp_http);

    # All transports share the same async API:
    async sub main {
        await $mcp->initialize;

        my $tools = await $mcp->list_tools;
        # [{name => 'echo', description => '...', inputSchema => {...}}]

        my $result = await $mcp->call_tool('echo', { message => 'Hello' });
        # {content => [{type => 'text', text => 'Echo: Hello'}], isError => \0}

        await $mcp->shutdown;
    }

    main()->get;

=head1 DESCRIPTION

L<Net::Async::MCP> is an asynchronous client for the MCP (Model Context
Protocol) built on L<IO::Async>. It connects to MCP servers via pluggable
transports:

=over 4

=item * B<InProcess> - Direct calls to an L<MCP::Server> instance in the same
process. See L<Net::Async::MCP::Transport::InProcess>.

=item * B<Stdio> - Subprocess communication over stdin/stdout using
newline-delimited JSON-RPC. Works with any MCP server implementation (Perl,
Node.js, Python, etc.). See L<Net::Async::MCP::Transport::Stdio>.

=item * B<HTTP> - Streamable HTTP transport for remote MCP servers. Supports
both JSON and SSE responses. See L<Net::Async::MCP::Transport::HTTP>.

=back

All methods return L<Future> objects and work with L<Future::AsyncAwait>.
Call L</initialize> first before using any other MCP methods. It performs the
handshake with a single C<server/discover> request of the current revision (the
legacy C<initialize> request no longer exists in the current MCP revision),
carrying the client's protocol version, capabilities, and info in C<_meta>.

=cut

my $DEFAULT_PROTOCOL_VERSION
  = eval { require MCP::Constants; MCP::Constants::PROTOCOL_VERSION() } // '2026-07-28';

# The keys handed to the HTTP transport as they are. Kept apart from the rest
# because they are passed on only when the caller actually gave them: the
# transport's own default for stall_timeout has to survive a client that was
# never asked about it.
my @HTTP_KEYS = qw( headers timeout stall_timeout );

sub _init {
  my ( $self, $params ) = @_;
  for my $key (qw( server command url protocol_version client_capabilities ), @HTTP_KEYS) {
    $self->{$key} = delete $params->{$key} if exists $params->{$key};
  }
  $self->{protocol_version}    //= $DEFAULT_PROTOCOL_VERSION;
  $self->{client_capabilities} //= {};
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  my @http = grep { exists $params{$_} } @HTTP_KEYS;
  for my $key (qw( server command url protocol_version client_capabilities ), @HTTP_KEYS) {
    $self->{$key} = delete $params{$key} if exists $params{$key};
  }
  $self->{protocol_version}    //= $DEFAULT_PROTOCOL_VERSION;
  $self->{client_capabilities} //= {};

  # A transport that already exists takes the change too: the transport is
  # built when this client joins a loop, and a bearer token that has to be
  # rotated arrives long after that.
  $self->{transport}->configure(map { $_ => $self->{$_} } @http)
    if @http
    && $self->{transport}
    && $self->{transport}->isa('Net::Async::MCP::Transport::HTTP');

  $self->SUPER::configure(%params);
}

sub _add_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_add_to_loop($loop);
  $self->_ensure_transport;
}

sub _ensure_transport {
  my ( $self ) = @_;
  return if $self->{transport};

  if ($self->{server}) {
    require Net::Async::MCP::Transport::InProcess;
    $self->{transport} = Net::Async::MCP::Transport::InProcess->new(
      server => $self->{server},
    );
  }
  elsif ($self->{command}) {
    croak "Stdio transport requires being added to an IO::Async::Loop"
      unless $self->loop;
    require Net::Async::MCP::Transport::Stdio;
    my $transport = Net::Async::MCP::Transport::Stdio->new(
      command => $self->{command},
    );
    $self->{transport} = $transport;
    $self->add_child($transport);
  }
  elsif ($self->{url}) {
    croak "HTTP transport requires being added to an IO::Async::Loop"
      unless $self->loop;
    require Net::Async::MCP::Transport::HTTP;
    my $transport = Net::Async::MCP::Transport::HTTP->new(
      url => $self->{url},
      # Only the keys the caller actually gave: handing over a stall_timeout of
      # undef for one that was never set would switch off the transport's
      # default instead of leaving it alone.
      map { $_ => $self->{$_} } grep { exists $self->{$_} } @HTTP_KEYS,
    );
    $self->{transport} = $transport;
    $self->add_child($transport);
  }
  else {
    croak "Must provide server, command, or url";
  }
}

sub protocol_version { $_[0]->{protocol_version} }

=method protocol_version

    my $version = $mcp->protocol_version;

Returns (or via C<configure>/constructor argument C<protocol_version> sets) the
MCP protocol revision this client speaks on the wire, such as C<'2026-07-28'>.
Defaults to the L<MCP::Constants> C<PROTOCOL_VERSION> of the installed
L<MCP::Server>. Sent on every request inside C<_meta>.

=cut

sub client_capabilities { $_[0]->{client_capabilities} }

=method client_capabilities

    my $caps = $mcp->client_capabilities;
    $mcp->configure(client_capabilities => { sampling => {} });

Returns (or via C<configure>/constructor argument C<client_capabilities> sets)
the HashRef of client capabilities sent on every request inside C<_meta>.
Defaults to C<{}>, an empty declaration, which is what a client that never
touches this attribute keeps sending.

Setting this is a B<promise>, not a hint. A conforming server may not send an
C<inputRequest> for a capability the client did not declare, so the empty
default is precisely what keeps a server from asking this client for anything
it cannot do. Declaring C<sampling> or C<elicitation> here tells the server it
may ask - and this client has no way to answer either of them yet, so such a
request would go unanswered and the server would be left waiting. Declare a
capability only once there is something on your side that serves it.

=cut

sub headers { $_[0]->{headers} }

=method headers

    my $headers = $mcp->headers;
    $mcp->configure(headers => { Authorization => "Bearer $token" });

Returns (or via C<configure>/constructor argument C<headers> sets) a HashRef of
extra headers sent with every HTTP request, which is how a server behind OAuth
is reached: nothing else in this client sets an C<Authorization>. Configuring
them after the client has joined a loop works too, so a token can be rotated on
a live client.

They cannot take over a header the MCP binding derives from the request body -
see L<Net::Async::MCP::Transport::HTTP/new> for why that is a rejection rather
than an override. Only the HTTP transport sends headers at all; the InProcess
and Stdio transports ignore this.

=cut

sub timeout { $_[0]->{timeout} }

=method timeout

    my $timeout = $mcp->timeout;

Returns (or via C<configure>/constructor argument C<timeout> sets) the
wall-clock limit in seconds on a single HTTP request. Unset by default, because
an MCP C<tools/call> may legitimately run for minutes and a default would break
such a setup; L</stall_timeout> is the one that guards against a hung server.
Note that C<0> is a limit of zero seconds rather than "no limit". HTTP
transport only.

=cut

sub stall_timeout { $_[0]->{stall_timeout} }

=method stall_timeout

    my $stall_timeout = $mcp->stall_timeout;

Returns (or via C<configure>/constructor argument C<stall_timeout> sets) how
many seconds an HTTP request may go without a single byte moving before it is
given up on. Set it to C<0> to switch it off. Undef here means it was never
configured and L<Net::Async::MCP::Transport::HTTP>'s default of 60 seconds
applies. HTTP transport only.

=cut

# Private: the C<_meta> fields carried on every JSON-RPC request, as required
# by the current MCP revision.
sub _meta {
  my ( $self ) = @_;
  return {
    'io.modelcontextprotocol/protocolVersion'    => $self->{protocol_version},
    'io.modelcontextprotocol/clientCapabilities' => $self->{client_capabilities},
    'io.modelcontextprotocol/clientInfo'         => {
      name    => 'Net::Async::MCP',
      version => $VERSION,
    },
  };
}

# Private: merge a caller's C<_meta> (if any) into the standard one, returning
# params that carry C<_meta> on every request.
sub _with_meta {
  my ( $self, $params ) = @_;
  my %params = %{ $params // {} };
  my %meta   = (%{ $self->_meta }, %{ $params{_meta} // {} });
  return { %params, _meta => \%meta };
}

sub server_info { $_[0]->{server_info} }

=method server_info

    my $info = $mcp->server_info;

Returns the server info hashref from the MCP C<server/discover> handshake
response. Contains at minimum C<name> and C<version> keys. Only available after
L</initialize> has been called.

=cut

sub server_capabilities { $_[0]->{server_capabilities} }

=method server_capabilities

    my $caps = $mcp->server_capabilities;

Returns the server capabilities hashref from the MCP C<server/discover>
handshake response. Only available after L</initialize> has been called.

=cut

async sub initialize {
  my ( $self ) = @_;
  $self->_ensure_transport;

  my $result = await $self->{transport}->send_request('server/discover',
    $self->_with_meta);

  # Read without autovivifying an _meta key into the result we hand back.
  my $meta = $result->{_meta} // {};
  $self->{server_info} = $meta->{'io.modelcontextprotocol/serverInfo'} // {};
  $self->{server_capabilities} = $result->{capabilities} // {};

  return $result;
}

=method initialize

    my $result = await $mcp->initialize;

Performs the MCP handshake. Must be called before any other MCP method. The
current MCP revision has replaced the old C<initialize> request with
C<server/discover>, which this method sends, carrying the client's protocol
version and L</client_capabilities> in C<_meta>. The server responds with its
capabilities and, in C<result._meta>, its server info.

That single request is the whole handshake: no C<notifications/initialized>
follows it. SEP-2575 removed the C<initialize>/C<initialized> pair along with
the C<initialize> request itself, and the Streamable HTTP binding of this
revision defines no client-to-server notifications at all, so the follow-up
would have been an extra POST that no conforming server acts on.

Returns the raw result hashref (C<capabilities> key, plus C<_meta> containing
C<io.modelcontextprotocol/serverInfo>). Also populates the L</server_info> and
L</server_capabilities> accessors.

C<initialize> remains a compatibility alias for the handshake; there is no
separate C<discover> entry point.

=cut

# Private: how many pages a list method walks before giving up. Only a cursor
# that comes round again proves a server is looping; one that keeps changing
# while never running out cannot be told apart from a genuinely long list, so
# there has to be an end to it somewhere.
my $MAX_LIST_PAGES = 100;

# Private: every entry of a paginated list method, following nextCursor until
# the server stops handing one out. $key is the result key holding the entries,
# and each page is appended in the order the server sent it.
#
# Anything short of the full list is failed rather than returned. Handing back
# the pages collected so far would be indistinguishable from a server that
# really has that many entries, which is exactly the bug this walk exists to
# fix - it would just move from the first page to the hundredth.
async sub _list_all {
  my ( $self, $method, $key ) = @_;

  my ( @entries, %seen, $cursor );

  for my $page ( 1 .. $MAX_LIST_PAGES ) {
    my $result = await $self->{transport}->send_request($method,
      $self->_with_meta(defined $cursor ? { cursor => $cursor } : undef));

    push @entries, @{ $result->{$key} // [] };

    $cursor = $result->{nextCursor};
    return \@entries unless defined $cursor;

    # A cursor is a position in the list, so being handed one back that was
    # already followed means the server is not moving. Left alone that spins
    # for as long as the server keeps answering.
    croak "MCP $method pagination: server repeated cursor '$cursor'"
      if $seen{$cursor}++;
  }

  croak "MCP $method pagination: server offered more than $MAX_LIST_PAGES pages";
}

async sub list_tools {
  my ( $self ) = @_;
  my $tools = await $self->_list_all('tools/list', 'tools');

  # A fresh listing is the whole truth about the server's tools, so it replaces
  # the cache rather than adding to it - and the whole truth is every page,
  # which is why this runs on the merged list once the walk is through. A walk
  # that failed part way leaves the cache as it was instead of replacing it with
  # what happens to have arrived.
  $self->{tool_header_params} = {
    map { $_->{name} => _header_params($_->{inputSchema}) }
    grep { ref $_ eq 'HASH' && defined $_->{name} } @$tools
  };

  return $tools;
}

=method list_tools

    my $tools = await $mcp->list_tools;

Returns an ArrayRef of tool definition hashrefs from the MCP server. Each
hashref contains C<name>, C<description>, and C<inputSchema> keys.

Also caches, per tool, which of its arguments are annotated with
C<x-mcp-header> in the input schema, which L</call_tool> needs to build the
C<Mcp-Param-{Name}> headers of the HTTP binding.

Paginated tool lists are walked to the end: as long as the server answers with
a C<nextCursor>, the next page is requested with that C<cursor> and its tools
appended, so both the returned list and the cache cover every page. Nothing
short of the whole list is ever returned - a server that keeps handing back a
cursor it already gave out, or that offers more than 100 pages, fails the
returned L<Future> instead, because a quietly truncated list is the same bug
this walk is here to fix.

=cut

# Private: the arguments a server expects mirrored into Mcp-Param-{Name}
# headers - every property annotated with x-mcp-header, reachable from the
# schema root through a chain of "properties" keys and nothing else. Same walk
# as MCP::Tool::_header_params, whose result the server checks the headers
# against, down to sorting by key so both sides agree on order.
sub _header_params {
  my ( $schema, $path ) = @_;
  $path //= [];

  return [] unless ref $schema eq 'HASH' && ref $schema->{properties} eq 'HASH';

  my $properties = $schema->{properties};
  my @params;
  for my $key (sort keys %$properties) {
    my $property = $properties->{$key};
    next unless ref $property eq 'HASH';

    my @next = ( @$path, $key );
    push @params, {
      name => $property->{'x-mcp-header'},
      path => \@next,
      type => $property->{type} // '',
    } if defined $property->{'x-mcp-header'};
    push @params, @{ _header_params($property, \@next) };
  }

  return \@params;
}

# Private: the argument a header parameter points at, or undef if the caller
# passed none. Same walk as MCP::Server::Transport::HTTP::_arg_value, which is
# what the server compares the header against.
sub _arg_value {
  my ( $arguments, $path ) = @_;

  my $value = $arguments;
  for my $key (@$path) {
    return undef unless ref $value eq 'HASH';
    $value = $value->{$key};
  }
  return $value;
}

# Private: an argument value in the form the server's _match_value compares it
# in. Getting this wrong is not a degradation but a rejection: the server
# answers -32020 (HEADER_MISMATCH) for a header that disagrees with the body.
sub _header_value {
  my ( $type, $value ) = @_;

  if ($type eq 'boolean') {
    # A JSON false reaches us either as \0, which JSON::MaybeXS encodes as
    # false, or as a JSON::PP::Boolean. The latter knows it is false, but \0 is
    # a reference and so a *true* Perl value: asking it directly would put
    # "true" in the header while the body says false. Unwrap plain scalar
    # references first, and let an object's own boolean overload speak.
    $value = $$value while ref $value eq 'SCALAR' || ref $value eq 'REF';
    return $value ? 'true' : 'false';
  }

  # Compared numerically by the server, so the number decides, not its
  # spelling. Anything that is not a number at all is passed through as text
  # for the server to reject.
  return 0 + $value if $type eq 'integer' && !ref $value && looks_like_number($value);

  return "$value";
}

# Private: the Mcp-Param-{Name} bindings for a tools/call, as a list of
# name/value pairs with each value already formatted the way the server
# compares it.
async sub _tool_header_params {
  my ( $self, $name, $arguments ) = @_;

  my $transport = $self->{transport};
  return () unless $transport->can('mirrors_header_params')
    && $transport->mirrors_header_params;

  unless (exists $self->{tool_header_params}{$name}) {
    # Calling a tool whose schema this client has never seen is not safe over a
    # binding that mirrors arguments into headers: an annotated argument
    # without its header is rejected outright, so the schema has to be fetched
    # before the call goes out. A failure is deliberately swallowed - the tool
    # may well have no annotated argument at all, and must not become
    # uncallable because an unrelated tools/list failed. The request then goes
    # out bare and the server decides.
    await $self->list_tools->else(sub { Future->done });
  }

  my @params;
  for my $param (@{ $self->{tool_header_params}{$name} // [] }) {
    my $value = _arg_value($arguments, $param->{path});

    # A header the server does not expect is rejected exactly like a missing
    # one, so an argument the caller left out gets no header.
    next unless defined $value;

    push @params, {
      name  => $param->{name},
      value => _header_value($param->{type}, $value),
    };
  }

  return @params;
}

async sub call_tool {
  my ( $self, $name, $arguments ) = @_;
  $arguments //= {};

  my @header_params = await $self->_tool_header_params($name, $arguments);

  my $result = await $self->{transport}->send_request('tools/call',
    $self->_with_meta({
      name      => $name,
      arguments => $arguments,
    }),
    @header_params ? ( header_params => \@header_params ) : (),
  );
  return $result;
}

=method call_tool

    my $result = await $mcp->call_tool($name, \%arguments);

Calls a named tool on the MCP server with the given arguments hashref.
Returns a hashref with C<content> (ArrayRef of content blocks) and C<isError>
(boolean).

A tool may annotate arguments in its input schema with C<x-mcp-header>, which
over the HTTP binding have to be mirrored into C<Mcp-Param-{Name}> headers; a
conforming server rejects a C<tools/call> that passes such an argument without
its header, and equally one that carries a header for an argument it did not
pass. This method resolves them from the tool's input schema, which means it
needs the schema: on a transport that mirrors headers it fetches L</list_tools>
once for a tool it has not seen, and keeps using the cached schemas afterwards.
If that fetch fails the call is still sent, without headers, leaving the
decision to the server.

Transports that do not mirror headers - InProcess and Stdio - resolve nothing
and never fetch a tool list on their own.

=cut

async sub list_prompts {
  my ( $self ) = @_;
  return await $self->_list_all('prompts/list', 'prompts');
}

=method list_prompts

    my $prompts = await $mcp->list_prompts;

Returns an ArrayRef of prompt definition hashrefs from the MCP server.
Paginated results are followed to the end and merged, on the same terms as
L</list_tools>.

=cut

async sub get_prompt {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('prompts/get',
    $self->_with_meta({
      name      => $name,
      arguments => $arguments // {},
    }));
  return $result;
}

=method get_prompt

    my $result = await $mcp->get_prompt($name, \%arguments);

Retrieves a named prompt from the MCP server, optionally passing arguments.
Returns the prompt result hashref.

=cut

async sub list_resources {
  my ( $self ) = @_;
  return await $self->_list_all('resources/list', 'resources');
}

=method list_resources

    my $resources = await $mcp->list_resources;

Returns an ArrayRef of resource definition hashrefs from the MCP server.
Paginated results are followed to the end and merged, on the same terms as
L</list_tools>.

=cut

async sub read_resource {
  my ( $self, $uri ) = @_;
  my $result = await $self->{transport}->send_request('resources/read',
    $self->_with_meta({
      uri => $uri,
    }));
  return $result;
}

=method read_resource

    my $result = await $mcp->read_resource($uri);

Reads a resource by URI from the MCP server. Returns the resource content
hashref.

=cut

async sub subscriptions_listen {
  my ( $self, $notifications ) = @_;
  my $result = await $self->{transport}->send_request('subscriptions/listen',
    $self->_with_meta({
      notifications => $notifications // {},
    }));
  return $result;
}

=method subscriptions_listen

    my $subscription = await $mcp->subscriptions_listen({ toolsListChanged => 1 });

Opens a C<subscriptions/listen> subscription on the MCP server, requesting
server-initiated notifications. C<$notifications> is a hashref mapping
notification types to a truthy value (e.g. C<toolsListChanged>,
C<promptsListChanged>, C<resourcesListChanged>). The request carries the
standard C<_meta> like all client methods.

Returns the server's C<subscriptions/listen> result. Whether a server supports
this method (and its notifications) is transport-dependent; a server without
notification support responds with JSON-RPC error -32601 (C<METHOD_NOT_FOUND>),
which this method surfaces as a failed L<Future>.

=cut

async sub ping {
  my ( $self ) = @_;
  # The current MCP revision moved liveness to the transport level and has no
  # client-addressable JSON-RPC "ping" request. Sending one would fail against
  # MCP::Server >= 0.15 (InProcess errors with -32601); stdio only "succeeded"
  # via an accidental legacy latch. Ask the transport whether it is still
  # usable instead of reporting success unconditionally.
  $self->_ensure_transport;
  croak "MCP transport is not alive" unless $self->{transport}->is_alive;
  return 1;
}

=method ping

    await $mcp->ping;

Performs a transport-level liveness check and returns C<1>. The current MCP
revision moved liveness to the transport layer and has no client-addressable
JSON-RPC C<ping> request, so no request goes on the wire; sending one would
fail against L<MCP::Server> E<gt>= 0.15.

Instead the transport's C<is_alive> is consulted, and the returned L<Future>
fails if the transport can no longer carry requests: for
L<Net::Async::MCP::Transport::Stdio> that means the subprocess has exited,
while the InProcess and HTTP transports have no connection state and are
always alive.

=cut

async sub shutdown {
  my ( $self ) = @_;
  if ($self->{transport} && $self->{transport}->can('close')) {
    await $self->{transport}->close;
  }
  return 1;
}

=method shutdown

    await $mcp->shutdown;

Cleanly shuts down the MCP connection. For the Stdio transport this sends
SIGTERM to the subprocess and waits for it to exit. For the InProcess and HTTP
transports this is a no-op: neither holds anything that outlives a request.

=cut

=seealso

=over 4

=item * L<Net::Async::MCP::Transport::InProcess> - In-process transport for Perl MCP servers

=item * L<Net::Async::MCP::Transport::Stdio> - Subprocess transport via stdin/stdout

=item * L<Net::Async::MCP::Transport::HTTP> - Streamable HTTP transport for remote servers

=item * L<IO::Async::Notifier> - Base class

=item * L<Future::AsyncAwait> - Async/await syntax used with this module

=item * L<https://modelcontextprotocol.io> - MCP specification

=back

=cut

1;
