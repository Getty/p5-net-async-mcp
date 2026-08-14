use strict;
use warnings;
use Test2::V0;

use IO::Async::Loop;
use Net::Async::MCP;
use MCP::Server;
use MCP::Constants qw(PROTOCOL_VERSION);

# Create test MCP server with tools
my $server = MCP::Server->new(name => 'TestServer');

$server->tool(
  name         => 'echo',
  description  => 'Echo the input text',
  input_schema => {
    type       => 'object',
    properties => { message => { type => 'string' } },
    required   => ['message'],
  },
  code => sub { return "Echo: $_[1]->{message}" },
);

$server->tool(
  name         => 'add',
  description  => 'Add two numbers',
  input_schema => {
    type       => 'object',
    properties => {
      a => { type => 'number' },
      b => { type => 'number' },
    },
    required => ['a', 'b'],
  },
  code => sub { return $_[1]->{a} + $_[1]->{b} },
);

# Create MCP client with InProcess transport
my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(server => $server);
$loop->add($mcp);

# The client speaks the current protocol revision by default
is($mcp->protocol_version, PROTOCOL_VERSION, 'defaults to current protocol version');

# Reconfiguring with an undefined protocol version must fall back to the
# default instead of blanking the client: every request carries
# protocolVersion in _meta, and MCP::Server answers a missing one with -32602.
{
  $mcp->configure(protocol_version => undef);
  is($mcp->protocol_version, PROTOCOL_VERSION,
    'undef protocol_version falls back to the default');

  my $f = $mcp->list_tools;
  ok(!$f->failure, 'a request after configure still carries a usable protocol version')
    or diag $f->failure;
}

# Test initialize (current protocol: server/discover + _meta)
{
  my $result = $mcp->initialize->get;
  is($result->{_meta}{'io.modelcontextprotocol/serverInfo'}{name},
    'TestServer', 'server name in result._meta serverInfo');
  ok($result->{capabilities}, 'capabilities returned');
  is($mcp->server_info->{name}, 'TestServer', 'server_info accessor');
}

# ping is a transport-level liveness no-op in the current protocol (no
# client-addressable JSON-RPC ping); it must succeed.
{
  my $ok = $mcp->ping->get;
  ok($ok, 'ping (transport-level liveness) succeeds');
}

# Test list_tools
{
  my $tools = $mcp->list_tools->get;
  is(scalar @$tools, 2, 'two tools listed');

  my %by_name = map { $_->{name} => $_ } @$tools;
  ok($by_name{echo}, 'echo tool exists');
  ok($by_name{add}, 'add tool exists');
  is($by_name{echo}{description}, 'Echo the input text', 'echo description');
}

# Test call_tool - echo
{
  my $result = $mcp->call_tool('echo', { message => 'hello world' })->get;
  ok(!$result->{isError}, 'echo not an error');
  is($result->{content}[0]{type}, 'text', 'content type is text');
  is($result->{content}[0]{text}, 'Echo: hello world', 'echo result correct');
}

# Test call_tool - add
{
  my $result = $mcp->call_tool('add', { a => 3, b => 4 })->get;
  ok(!$result->{isError}, 'add not an error');
  is($result->{content}[0]{text}, '7', 'add result correct');
}

# Test call_tool - nonexistent tool
{
  my $f = $mcp->call_tool('nonexistent', {});
  ok($f->failure, 'calling nonexistent tool fails');
  like($f->failure, qr/not found/i, 'error mentions not found');
}

# Test list_prompts (empty)
{
  my $prompts = $mcp->list_prompts->get;
  is(scalar @$prompts, 0, 'no prompts');
}

# Test list_resources (empty)
{
  my $resources = $mcp->list_resources->get;
  is(scalar @$resources, 0, 'no resources');
}

# Test subscriptions_listen with an InProcess server that has no notification
# transport attached: MCP::Server::_handle_listen only honours the request when
# the server's transport supports notifications, otherwise it responds with
# JSON-RPC error -32601 (METHOD_NOT_FOUND). We verify that subscriptions_listen
# builds a _meta-carrying request (so it reaches the handler and fails with
# "method not found" rather than a protocol error) and surfaces that failure.
{
  my $f = $mcp->subscriptions_listen({ toolsListChanged => 1 });
  ok($f->failure, 'subscriptions_listen fails on a server without notification transport');
  like($f->failure, qr/not found/i, 'failure is JSON-RPC METHOD_NOT_FOUND');
}

# A server whose discover result carries no _meta at all. MCP::Server always
# sends one, so this needs a stub, but a foreign server may not: server_info
# must then default to {} without the client mutating the result it hands back
# to the caller.
{
  package Test::NoMetaServer;
  sub new { bless {}, shift }
  sub handle {
    my ( $self, $request ) = @_;
    return undef unless defined $request->{id};
    return {
      jsonrpc => '2.0',
      id      => $request->{id},
      result  => { capabilities => {} },
    };
  }
}

{
  my $bare = Net::Async::MCP->new(server => Test::NoMetaServer->new);
  $loop->add($bare);

  my $result = $bare->initialize->get;
  is($bare->server_info, {}, 'server_info defaults to {} when the result has no _meta');
  ok(!exists $result->{_meta}, 'initialize does not autovivify _meta into the result');
}

done_testing;
