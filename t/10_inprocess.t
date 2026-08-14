use strict;
use warnings;
use Test2::V0;

use Future;
use IO::Async::Loop;
use Net::Async::MCP;
use MCP::Server;
use MCP::Server::Transport::HTTP;
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

# And declares nothing it cannot serve: an empty declaration is what keeps a
# conforming server from sending inputRequests this client could not answer.
is($mcp->client_capabilities, {}, 'declares no client capabilities by default');

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

# The other half: a server that does have a notification capable transport of
# its own. MCP::Server::_handle_listen then answers with an
# MCP::Server::Subscription object instead of a JSON-RPC response, expecting the
# transport to serve it as a notification stream. In process there is no stream,
# so the transport has to name its own limitation rather than blame the server
# for a malformed response - the message is what tells a caller whether to fix
# their server or pick another transport.
{
  my $streaming = MCP::Server->new(name => 'StreamingServer');
  $streaming->transport(
    MCP::Server::Transport::HTTP->new(server => $streaming, streaming => 1));
  ok($streaming->transport->notifications,
    'the attached server transport supports notifications');

  my $client = Net::Async::MCP->new(server => $streaming);
  $loop->add($client);

  my $f = $client->subscriptions_listen({ toolsListChanged => 1 });
  ok($f->failure, 'subscriptions_listen fails on a notification capable server too');
  like($f->failure, qr/cannot carry server-initiated notifications/,
    'the failure names the in-process transport as the limitation');
  like($f->failure, qr{subscriptions/listen is not usable},
    'and says which method is out of reach here');
  unlike($f->failure, qr/Invalid response/,
    'and does not accuse the server of a malformed response');
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

# Tool arguments annotated with x-mcp-header have to be mirrored into
# Mcp-Param-{Name} headers by the HTTP binding, and which arguments those are
# follows from the tool's input schema. The client reads them out of the schema
# so that every binding gets the same answer; this is the same walk
# MCP::Tool::_header_params does on the server, whose result the server checks
# the headers against.
{
  my $params = Net::Async::MCP::_header_params({
    type       => 'object',
    properties => {
      service => { type => 'string' },
      region  => { type => 'string',  'x-mcp-header' => 'Region' },
      dry_run => { type => 'boolean', 'x-mcp-header' => 'Dry-Run' },
      options => {
        type       => 'object',
        properties => {
          label => { type => 'string', 'x-mcp-header' => 'Label' },
          plain => { type => 'string' },
        },
      },
    },
  });

  is($params, [
    { name => 'Dry-Run', path => ['dry_run'],           type => 'boolean' },
    { name => 'Label',   path => ['options', 'label'],  type => 'string' },
    { name => 'Region',  path => ['region'],            type => 'string' },
  ], 'only annotated properties are extracted, nested ones with their full path');

  is(Net::Async::MCP::_header_params({ type => 'object' }), [],
    'a schema without properties has no header params');
  is(Net::Async::MCP::_header_params(undef), [],
    'and neither has a tool that ships no input schema at all');

  # x-mcp-header is only meaningful under a chain of "properties" keys, so an
  # annotation anywhere else is not a header param and must not be mirrored
  is(Net::Async::MCP::_header_params({
    type       => 'object',
    properties => {
      tags => {
        type  => 'array',
        items => { type => 'string', 'x-mcp-header' => 'Tag' },
      },
    },
  }), [], 'an annotation outside the properties chain is ignored');
}

# list_tools is what fills that cache, so a client that has listed its tools
# knows which arguments need a header without asking again
{
  my $annotated = MCP::Server->new(name => 'AnnotatedServer');
  $annotated->tool(
    name         => 'deploy',
    description  => 'Deploy a service',
    input_schema => {
      type       => 'object',
      properties => {
        service => { type => 'string' },
        region  => { type => 'string', 'x-mcp-header' => 'Region' },
      },
    },
    code => sub { return 'deployed' },
  );
  $annotated->tool(
    name         => 'status',
    description  => 'Report status',
    input_schema => { type => 'object', properties => { service => { type => 'string' } } },
    code => sub { return 'ok' },
  );

  my $client = Net::Async::MCP->new(server => $annotated);
  $loop->add($client);

  $client->list_tools->get;
  is($client->{tool_header_params}{deploy},
    [ { name => 'Region', path => ['region'], type => 'string' } ],
    'list_tools caches the header params of an annotated tool');
  is($client->{tool_header_params}{status}, [],
    'and an empty list for a tool without annotations, so it is never looked up again');
}

# The InProcess transport has no headers to mirror anything into, so the client
# must not spend a tools/list on resolving what it could not use anyway
{
  package Test::CountingServer;
  sub new { bless { methods => [] }, shift }
  sub handle {
    my ( $self, $request ) = @_;
    push @{ $self->{methods} }, $request->{method};
    return undef unless defined $request->{id};
    return {
      jsonrpc => '2.0',
      id      => $request->{id},
      result  => { content => [ { type => 'text', text => 'ok' } ] },
    };
  }
  sub methods { $_[0]{methods} }
}

{
  my $counting = Test::CountingServer->new;
  my $client = Net::Async::MCP->new(server => $counting);
  $loop->add($client);

  ok(!$client->{transport}->mirrors_header_params,
    'the InProcess transport mirrors no header params');

  # A tool this client never listed: over HTTP this is what triggers the
  # schema lookup, here it must trigger nothing but the call itself
  $client->call_tool('never_listed', { region => 'europe-west1' })->get;
  is($counting->methods, ['tools/call'],
    'calling an unlisted tool sends no tools/list on a transport without headers');
}

# Client capabilities are a promise to the server: it may only send an
# inputRequest for something the client declared. Declaring them therefore has
# to reach the server on the wire, not just sit in an accessor - a client that
# says it does sampling and then never sends it in _meta would never be asked,
# and one whose declaration got lost the other way round would be asked for
# something it cannot do.
{
  package Test::RecordingServer;
  sub new { bless { requests => [] }, shift }
  sub requests { $_[0]{requests} }
  sub handle {
    my ( $self, $request ) = @_;
    push @{ $self->{requests} }, $request;
    return undef unless defined $request->{id};
    return {
      jsonrpc => '2.0',
      id      => $request->{id},
      result  => { tools => [] },
    };
  }
}

{
  my $recording = Test::RecordingServer->new;
  my $capabilities = { sampling => {}, elicitation => {} };
  my $client = Net::Async::MCP->new(
    server              => $recording,
    client_capabilities => $capabilities,
  );
  $loop->add($client);

  is($client->client_capabilities, $capabilities,
    'client_capabilities are readable back');

  $client->list_tools->get;
  is($recording->requests->[0]{params}{_meta}{'io.modelcontextprotocol/clientCapabilities'},
    $capabilities, 'and travel in the _meta of a real request, not just initialize');

  # Same fallback as protocol_version: blanking the attribute must not put an
  # undef where the server expects a capabilities object.
  $client->configure(client_capabilities => undef);
  is($client->client_capabilities, {},
    'undef client_capabilities falls back to an empty declaration');

  $client->list_tools->get;
  is($recording->requests->[1]{params}{_meta}{'io.modelcontextprotocol/clientCapabilities'},
    {}, 'and the empty declaration is what goes on the wire afterwards');
}

# A server that pages its lists. MCP allows it, the installed MCP::Server never
# does it, so seeing the second page at all needs a stub. It records the cursor
# of every request, because appending a second page the client fetched without
# passing the cursor back would be a different (and broken) thing entirely.
{
  package Test::PagingServer;

  # method => [ result key, first page, second page ]
  my %LISTS = (
    'tools/list' => [ 'tools',
      [ { name => 'alpha', inputSchema => { type => 'object',
            properties => { region => { type => 'string', 'x-mcp-header' => 'Region' } } } } ],
      [ { name => 'beta', inputSchema => { type => 'object',
            properties => { zone => { type => 'string', 'x-mcp-header' => 'Zone' } } } } ],
    ],
    'prompts/list'   => [ 'prompts',   [ { name => 'first' } ], [ { name => 'second' } ] ],
    'resources/list' => [ 'resources', [ { uri => 'file:///one' } ], [ { uri => 'file:///two' } ] ],
  );

  sub new { bless { cursors => [] }, shift }
  sub cursors { $_[0]{cursors} }

  sub handle {
    my ( $self, $request ) = @_;
    return undef unless defined $request->{id};

    my $list = $LISTS{ $request->{method} }
      or return { jsonrpc => '2.0', id => $request->{id},
                  error => { code => -32601, message => 'Method not found' } };

    my ( $key, @pages ) = @$list;
    my $cursor = $request->{params}{cursor};
    push @{ $self->{cursors} }, $cursor;

    my $page = defined $cursor ? 1 : 0;
    return {
      jsonrpc => '2.0',
      id      => $request->{id},
      result  => {
        $key => $pages[$page],
        $page == 0 ? ( nextCursor => 'page-2' ) : (),
      },
    };
  }
}

{
  my $paging = Test::PagingServer->new;
  my $client = Net::Async::MCP->new(server => $paging);
  $loop->add($client);

  my $tools = $client->list_tools->get;
  is([ map { $_->{name} } @$tools ], ['alpha', 'beta'],
    'both pages of a paginated tool list are returned, in server order');
  is($paging->cursors, [ undef, 'page-2' ],
    'the first page is asked for without a cursor and the second with the one the server gave');

  # The header param cache is what call_tool resolves Mcp-Param headers from,
  # so a tool that only appears on the second page has to be in it too -
  # otherwise pagination would fix the returned list and leave calls to
  # late-page tools rejected by the server for a missing header.
  is($client->{tool_header_params}{alpha},
    [ { name => 'Region', path => ['region'], type => 'string' } ],
    'the schema cache knows the tool from the first page');
  is($client->{tool_header_params}{beta},
    [ { name => 'Zone', path => ['zone'], type => 'string' } ],
    'and the one that only exists on the second page');

  is([ map { $_->{name} } @{ $client->list_prompts->get } ], ['first', 'second'],
    'list_prompts merges its pages too');
  is([ map { $_->{uri} } @{ $client->list_resources->get } ],
    ['file:///one', 'file:///two'], 'and so does list_resources');
}

# A server that never advances: every page comes back with the cursor it just
# handed out. Following that forever is not an option, and neither is stopping
# quietly with what has arrived - a short list that looks complete is the bug
# pagination support was added to remove.
{
  package Test::LoopingServer;
  sub new { bless { requests => 0 }, shift }
  sub requests { $_[0]{requests} }
  sub handle {
    my ( $self, $request ) = @_;
    return undef unless defined $request->{id};
    $self->{requests}++;
    return {
      jsonrpc => '2.0',
      id      => $request->{id},
      result  => { tools => [ { name => 'again' } ], nextCursor => 'stuck' },
    };
  }
}

{
  my $looping = Test::LoopingServer->new;
  my $client = Net::Async::MCP->new(server => $looping);
  $loop->add($client);

  my $f = $client->list_tools;
  ok($f->failure, 'a server that repeats its cursor fails the list instead of looping');
  like($f->failure, qr/pagination/, 'and the failure says pagination is why');
  like($f->failure, qr/stuck/, 'naming the cursor that came round again');

  is($looping->requests, 2,
    'the repeat is caught on the request that proves it, not after a page limit');
  is($client->{tool_header_params}, undef,
    'and a failed walk leaves no partial schema cache behind');
}

# SEP-2322 lets a server answer with an input_required result instead of a
# final one, asking the client for something and to call again. MCP::Server
# only produces one from a primitive that returns MCP::Primitive::input_required
# itself, so scripting the exchange needs a stub: it answers each request with
# the next result on its list, repeats the last one for as long as it is asked,
# and keeps every request it saw - the retry is the whole point, so what it
# carries is what has to be checked.
{
  package Test::InputServer;
  sub new {
    my ( $class, @results ) = @_;
    return bless { results => \@results, requests => [] }, $class;
  }
  sub requests { $_[0]{requests} }
  sub handle {
    my ( $self, $request ) = @_;
    push @{ $self->{requests} }, $request;
    return undef unless defined $request->{id};
    my $result = @{ $self->{results} } > 1
      ? shift @{ $self->{results} }
      : $self->{results}[0];
    return { jsonrpc => '2.0', id => $request->{id}, result => $result };
  }
}

# An input_required result with a requestState and nothing else asks for
# nothing but the call again. The state is sealed and bound by the server, so
# the only correct thing to do with it is hand it back exactly as it arrived.
{
  my $state  = 'eyJwYXlsb2FkIjp7Im5hbWUiOiJlZGdlIn19.c2lnbmF0dXJl';
  my $server = Test::InputServer->new(
    { resultType => 'input_required', requestState => $state },
    { content => [ { type => 'text', text => 'deleted' } ] },
  );

  my $asked = 0;
  my $client = Net::Async::MCP->new(
    server           => $server,
    on_input_request => sub { $asked++; return { action => 'accept' } },
  );
  $loop->add($client);

  my $result = $client->call_tool('delete_release', { name => 'edge' })->get;
  is($result->{content}[0]{text}, 'deleted',
    'the caller sees the final result, not the input_required on the way to it');

  my @calls = @{ $server->requests };
  is(scalar @calls, 2, 'which took exactly one retry');
  is($calls[1]{params}{requestState}, $state,
    'the retry mirrors the requestState back unchanged');
  is($calls[1]{params}{name}, 'delete_release',
    'and repeats the original request rather than sending a bare retry');
  is($calls[1]{params}{arguments}, { name => 'edge' }, 'arguments included');
  ok(!exists $calls[1]{params}{inputResponses},
    'a result that asked for no input is answered with no inputResponses');
  ok(!exists $calls[0]{params}{requestState},
    'and the first attempt carried no state at all');
  is($asked, 0, 'a pure retry never troubles the input request handler');
}

# The other half: a result that names what it wants. Each request goes to
# on_input_request under the method it asks for, and the answers go back under
# the keys the server chose - those keys are how the server reads its own
# responses back, so getting them wrong loses the answer entirely.
{
  my $server = Test::InputServer->new(
    {
      resultType    => 'input_required',
      requestState  => 'STATE-1',
      inputRequests => {
        confirm => {
          method => 'elicitation/create',
          params => {
            message         => 'Really delete edge?',
            requestedSchema => { type => 'object' },
          },
        },
        pick => {
          method => 'sampling/createMessage',
          params => { messages => [ { role => 'user' } ] },
        },
      },
    },
    { content => [ { type => 'text', text => 'deleted' } ] },
  );

  my @asked;
  my $client = Net::Async::MCP->new(
    server              => $server,
    client_capabilities => { elicitation => {}, sampling => {} },
    on_input_request    => sub {
      my ( $mcp, $method, $params ) = @_;
      push @asked, [ $mcp, $method, $params ];

      # A handler that has to go and ask someone answers with a Future, which
      # is the whole reason this client waits for one.
      return Future->done({ action => 'accept', content => { ok => \1 } })
        if $method eq 'elicitation/create';
      return { role => 'assistant', content => { type => 'text', text => 'edge' } };
    },
  );
  $loop->add($client);

  my $result = $client->call_tool('delete_release', { name => 'edge' })->get;
  is($result->{content}[0]{text}, 'deleted',
    'the round trip ends in the final result');

  is([ map { $_->[1] } @asked ], [ 'elicitation/create', 'sampling/createMessage' ],
    'every input request reaches the handler, named by the method it asks for');
  is($asked[0][0], exact_ref($client), 'called with the client as first argument');
  is($asked[0][2]{message}, 'Really delete edge?',
    'and with the params of that very request');

  my $retry = $server->requests->[1]{params};
  is($retry->{inputResponses}, {
    confirm => { action => 'accept', content => { ok => \1 } },
    pick    => { role => 'assistant', content => { type => 'text', text => 'edge' } },
  }, 'the answers travel back under the keys the server asked by');
  is($retry->{requestState}, 'STATE-1', 'alongside the state, still untouched');
}

# Nothing about this is specific to tools/call - it sits in the one place every
# request goes through - and a result without a requestState must be retried
# without one rather than with an empty or undefined key.
{
  my $server = Test::InputServer->new(
    {
      resultType    => 'input_required',
      inputRequests => { confirm => { method => 'elicitation/create', params => {} } },
    },
    { messages => [ { role => 'user' } ] },
  );

  my $client = Net::Async::MCP->new(
    server              => $server,
    client_capabilities => { elicitation => {} },
    on_input_request    => sub { return { action => 'accept' } },
  );
  $loop->add($client);

  my $result = $client->get_prompt('review', { file => 'x.pm' })->get;
  is($result->{messages}[0]{role}, 'user', 'get_prompt walks the round trip too');

  my $retry = $server->requests->[1]{params};
  ok(!exists $retry->{requestState},
    'a result without a requestState is retried without one');
  is($retry->{inputResponses}{confirm}, { action => 'accept' },
    'and the answer is still there');
  is($retry->{name}, 'review', 'on top of the original params of prompts/get');
}

# A server may legitimately ask again after being answered, so the retry is a
# loop - and a loop needs an end. Handing back what has arrived is not one:
# an input_required result looks to a caller like a final result whose content
# went missing.
{
  my $server = Test::InputServer->new(
    { resultType => 'input_required', requestState => 'never-ending' },
  );
  my $client = Net::Async::MCP->new(server => $server);
  $loop->add($client);

  my $f = $client->call_tool('forever', {});
  ok($f->failure, 'a server that never stops asking fails the call');
  like($f->failure, qr/input_required more than 8 times/,
    'and the failure says how far it was followed');
  is(scalar @{ $server->requests }, 9,
    'which is eight retries after the original request, and then no more');
}

# inputRequests with nothing to answer them. Passing the input_required result
# back to the caller instead would be the same silence, only harder to find.
{
  my $server = Test::InputServer->new(
    {
      resultType    => 'input_required',
      inputRequests => { confirm => { method => 'elicitation/create', params => {} } },
    },
  );
  my $client = Net::Async::MCP->new(
    server              => $server,
    client_capabilities => { elicitation => {} },
  );
  $loop->add($client);

  my $f = $client->call_tool('confirm_me', {});
  ok($f->failure, 'input requests with no handler set fail the call');
  like($f->failure, qr/on_input_request/, 'the failure names what is missing');
  like($f->failure, qr/confirm/, 'and which request went unanswered');
  is(scalar @{ $server->requests }, 1, 'nothing is retried');
}

# Declaring a capability is a promise both ways: the server may only ask for
# what was declared, and a client that quietly answered anyway would be
# rewarding a server for breaking it.
{
  my $server = Test::InputServer->new(
    {
      resultType    => 'input_required',
      inputRequests => { pick => { method => 'sampling/createMessage', params => {} } },
    },
  );

  my $asked  = 0;
  my $client = Net::Async::MCP->new(
    server              => $server,
    client_capabilities => { elicitation => {} },
    on_input_request    => sub { $asked++; return { action => 'accept' } },
  );
  $loop->add($client);

  my $f = $client->call_tool('sample_me', {});
  ok($f->failure, 'an input request for an undeclared capability fails the call');
  like($f->failure, qr/did not declare/,
    'and is named as the server violation it is');
  like($f->failure, qr{sampling/createMessage}, 'naming what was asked for');
  is($asked, 0, 'the handler is never troubled with it');
}

# An input_required result with neither half leaves nothing to answer and
# nothing to send back, so a retry would repeat the first request exactly.
{
  my $server = Test::InputServer->new({ resultType => 'input_required' });
  my $client = Net::Async::MCP->new(server => $server);
  $loop->add($client);

  my $f = $client->read_resource('file:///one');
  ok($f->failure, 'an input_required result that asks for nothing fails the call');
  like($f->failure, qr/neither inputRequests nor requestState/,
    'saying what the server left out');
  is(scalar @{ $server->requests }, 1,
    'and no retry that could not have differed from the first attempt');
}

# What the handler returns goes on the wire as it is, so a handler that
# returned nothing usable has to be caught here rather than by the server.
{
  my $server = Test::InputServer->new(
    {
      resultType    => 'input_required',
      inputRequests => { confirm => { method => 'elicitation/create', params => {} } },
    },
  );
  my $client = Net::Async::MCP->new(
    server              => $server,
    client_capabilities => { elicitation => {} },
    on_input_request    => sub { return },
  );
  $loop->add($client);

  my $f = $client->call_tool('confirm_me', {});
  ok($f->failure, 'a handler that answers with nothing fails the call');
  like($f->failure, qr/not a HashRef/, 'saying what was expected');
  like($f->failure, qr/confirm/, 'and for which request');
}

done_testing;
