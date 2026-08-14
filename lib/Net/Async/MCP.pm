package Net::Async::MCP;
# ABSTRACT: Async MCP (Model Context Protocol) client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use Carp qw( croak );

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
        url => 'https://example.com/mcp',
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
both JSON and SSE responses, with automatic session management. See
L<Net::Async::MCP::Transport::HTTP>.

=back

All methods return L<Future> objects and work with L<Future::AsyncAwait>.
Call L</initialize> first before using any other MCP methods. It performs the
handshake by sending the current revision's C<server/discover> request (the
legacy C<initialize> request no longer exists in the current MCP revision),
carrying the client's protocol version, capabilities, and info in C<_meta>.

=cut

my $DEFAULT_PROTOCOL_VERSION
  = eval { require MCP::Constants; MCP::Constants::PROTOCOL_VERSION() } // '2026-07-28';

sub _init {
  my ( $self, $params ) = @_;
  for my $key (qw( server command url protocol_version )) {
    $self->{$key} = delete $params->{$key} if exists $params->{$key};
  }
  $self->{protocol_version} //= $DEFAULT_PROTOCOL_VERSION;
  $self->{_initialized} = 0;
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  for my $key (qw( server command url protocol_version )) {
    $self->{$key} = delete $params{$key} if exists $params{$key};
  }
  $self->{protocol_version} //= $DEFAULT_PROTOCOL_VERSION if exists $params{protocol_version};
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

# Private: the C<_meta> fields carried on every JSON-RPC request, as required
# by the current MCP revision.
sub _meta {
  my ( $self ) = @_;
  return {
    'io.modelcontextprotocol/protocolVersion'     => $self->{protocol_version},
    'io.modelcontextprotocol/clientCapabilities' => {},
    'io.modelcontextprotocol/clientInfo'          => {
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
    $self->_with_meta({ capabilities => {} }));

  $self->{server_info}
    = $result->{_meta}{'io.modelcontextprotocol/serverInfo'} // {};
  $self->{server_capabilities} = $result->{capabilities} // {};
  $self->{_initialized} = 1;

  await $self->{transport}->send_notification('notifications/initialized');

  return $result;
}

=method initialize

    my $result = await $mcp->initialize;

Performs the MCP handshake. Must be called before any other MCP method. The
current MCP revision has replaced the old C<initialize> request with
C<server/discover>, which this method sends, carrying the client's protocol
version and capabilities in C<_meta>. The server responds with its capabilities
and, in C<result._meta>, its server info.

Returns the raw result hashref (C<capabilities> key, plus C<_meta> containing
C<io.modelcontextprotocol/serverInfo>). Also populates the L</server_info> and
L</server_capabilities> accessors.

C<initialize> remains a compatibility alias for the handshake; there is no
separate C<discover> entry point.

=cut

async sub list_tools {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('tools/list',
    $self->_with_meta);
  return $result->{tools} // [];
}

=method list_tools

    my $tools = await $mcp->list_tools;

Returns an ArrayRef of tool definition hashrefs from the MCP server. Each
hashref contains C<name>, C<description>, and C<inputSchema> keys.

=cut

async sub call_tool {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('tools/call',
    $self->_with_meta({
      name      => $name,
      arguments => $arguments // {},
    }));
  return $result;
}

=method call_tool

    my $result = await $mcp->call_tool($name, \%arguments);

Calls a named tool on the MCP server with the given arguments hashref.
Returns a hashref with C<content> (ArrayRef of content blocks) and C<isError>
(boolean).

=cut

async sub list_prompts {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('prompts/list',
    $self->_with_meta);
  return $result->{prompts} // [];
}

=method list_prompts

    my $prompts = await $mcp->list_prompts;

Returns an ArrayRef of prompt definition hashrefs from the MCP server.

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
  my $result = await $self->{transport}->send_request('resources/list',
    $self->_with_meta);
  return $result->{resources} // [];
}

=method list_resources

    my $resources = await $mcp->list_resources;

Returns an ArrayRef of resource definition hashrefs from the MCP server.

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

async sub ping {
  my ( $self ) = @_;
  # The current MCP revision moved liveness to the transport level and has no
  # client-addressable JSON-RPC "ping" request. Sending one would fail against
  # MCP::Server >= 0.15 (InProcess errors with -32601); stdio only "succeeded"
  # via an accidental legacy latch. Keep a transport-level liveness check that
  # returns success while the transport is fully set up.
  $self->_ensure_transport;
  return 1;
}

=method ping

    await $mcp->ping;

Performs a transport-level liveness check. The current MCP revision moved
liveness to the transport layer and has no client-addressable JSON-RPC
C<ping> request, so this is a no-op that returns C<1> once the transport is
set up, rather than sending a C<ping> that would fail against
L<MCP::Server> E<gt>= 0.15.

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
SIGTERM to the subprocess and waits for it to exit. For the InProcess
transport this is a no-op.

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
