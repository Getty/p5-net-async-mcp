package Net::Async::MCP;
# ABSTRACT: Async MCP (Model Context Protocol) client for IO::Async

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future::AsyncAwait;
use Carp qw( croak );

our $VERSION = '0.001';

sub _init {
  my ( $self, $params ) = @_;
  for my $key (qw( server command url )) {
    $self->{$key} = delete $params->{$key} if exists $params->{$key};
  }
  $self->{_initialized} = 0;
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  for my $key (qw( server command url )) {
    $self->{$key} = delete $params{$key} if exists $params{$key};
  }
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
    croak "HTTP transport not yet implemented";
  }
  else {
    croak "Must provide server, command, or url";
  }
}

sub server_info { $_[0]->{server_info} }

sub server_capabilities { $_[0]->{server_capabilities} }

async sub initialize {
  my ( $self ) = @_;
  $self->_ensure_transport;

  my $result = await $self->{transport}->send_request('initialize', {
    protocolVersion => '2025-11-25',
    capabilities => {},
    clientInfo => {
      name    => 'Net::Async::MCP',
      version => $VERSION,
    },
  });

  $self->{server_info} = $result->{serverInfo};
  $self->{server_capabilities} = $result->{capabilities};
  $self->{_initialized} = 1;

  await $self->{transport}->send_notification('notifications/initialized');

  return $result;
}

async sub list_tools {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('tools/list');
  return $result->{tools} // [];
}

async sub call_tool {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('tools/call', {
    name      => $name,
    arguments => $arguments // {},
  });
  return $result;
}

async sub list_prompts {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('prompts/list');
  return $result->{prompts} // [];
}

async sub get_prompt {
  my ( $self, $name, $arguments ) = @_;
  my $result = await $self->{transport}->send_request('prompts/get', {
    name      => $name,
    arguments => $arguments // {},
  });
  return $result;
}

async sub list_resources {
  my ( $self ) = @_;
  my $result = await $self->{transport}->send_request('resources/list');
  return $result->{resources} // [];
}

async sub read_resource {
  my ( $self, $uri ) = @_;
  my $result = await $self->{transport}->send_request('resources/read', {
    uri => $uri,
  });
  return $result;
}

async sub ping {
  my ( $self ) = @_;
  await $self->{transport}->send_request('ping');
  return 1;
}

async sub shutdown {
  my ( $self ) = @_;
  if ($self->{transport} && $self->{transport}->can('close')) {
    await $self->{transport}->close;
  }
  return 1;
}

1;

=head1 SYNOPSIS

  use IO::Async::Loop;
  use Net::Async::MCP;
  use Future::AsyncAwait;

  my $loop = IO::Async::Loop->new;

  # In-process (requires MCP module)
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

  # Stdio (external process)
  my $mcp_stdio = Net::Async::MCP->new(
    command => ['npx', '@anthropic/mcp-server-web-search'],
  );
  $loop->add($mcp_stdio);

  # All transports, same async API:
  async sub main {
    await $mcp->initialize;

    my $tools = await $mcp->list_tools;
    # [{name => 'echo', description => '...', inputSchema => {...}}]

    my $result = await $mcp->call_tool('echo', { message => 'Hello' });
    # {content => [{type => 'text', text => 'Echo: Hello'}], isError => false}

    await $mcp->shutdown;
  }

  main()->get;

=head1 DESCRIPTION

L<Net::Async::MCP> is an asynchronous MCP (Model Context Protocol) client built
on L<IO::Async>. It can connect to MCP servers via multiple transports:

=over 4

=item * B<InProcess> - Direct calls to an L<MCP::Server> instance in the same process

=item * B<Stdio> - Subprocess communication over stdin/stdout (JSON-RPC)

=back

All methods return L<Future> objects and work with L<Future::AsyncAwait>.

=attr server

An L<MCP::Server> instance for in-process communication. When provided,
the InProcess transport is used.

=attr command

An ArrayRef of command and arguments to spawn an MCP server subprocess.
When provided, the Stdio transport is used.

=method initialize

  my $info = await $mcp->initialize;

Sends the MCP initialize handshake. Must be called before any other MCP
methods. Returns the server's initialization response containing
C<serverInfo> and C<capabilities>.

=method list_tools

  my $tools = await $mcp->list_tools;

Returns an ArrayRef of tool definitions from the MCP server.

=method call_tool

  my $result = await $mcp->call_tool($name, \%arguments);

Calls a tool on the MCP server. Returns the tool result containing
C<content> (ArrayRef of content blocks) and C<isError> (boolean).

=method list_prompts

  my $prompts = await $mcp->list_prompts;

Returns an ArrayRef of prompt definitions.

=method get_prompt

  my $result = await $mcp->get_prompt($name, \%arguments);

Gets a prompt from the MCP server with the given arguments.

=method list_resources

  my $resources = await $mcp->list_resources;

Returns an ArrayRef of resource definitions.

=method read_resource

  my $result = await $mcp->read_resource($uri);

Reads a resource from the MCP server by URI.

=method ping

  await $mcp->ping;

Sends a ping to verify the server is responsive.

=method shutdown

  await $mcp->shutdown;

Shuts down the connection. For Stdio transport, this terminates the
subprocess.

=method server_info

  my $info = $mcp->server_info;

Returns the server info hash from the initialize response. Available after
L</initialize> has been called.

=method server_capabilities

  my $caps = $mcp->server_capabilities;

Returns the server capabilities hash from the initialize response. Available
after L</initialize> has been called.

=seealso L<MCP>, L<IO::Async>, L<https://modelcontextprotocol.io>

=cut
