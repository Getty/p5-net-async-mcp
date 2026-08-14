use strict;
use warnings;
use Test2::V0;

use MIME::Base64 qw( decode_base64 );
use Encode qw( decode );

use Net::Async::MCP::Transport::HTTP;

# HTTP::Message reaches this distribution only through Net::Async::HTTP, which
# is a recommendation and not a requirement: without it there is no usable HTTP
# transport, so there is nothing here to test either.
skip_all 'HTTP::Message is required for the HTTP transport tests'
  unless eval { require HTTP::Response; 1 };

# The suite has no MCP server to talk to over HTTP, so these tests drive the
# response handling directly: turning an HTTP response into a Future is where
# the transport makes its decisions, and getting them wrong turns a real
# JSON-RPC error into a misleading transport error.

my $transport = Net::Async::MCP::Transport::HTTP->new(
  url => 'http://mcp.invalid/mcp',
);

sub response {
  my ( $code, $content_type, $body ) = @_;
  return HTTP::Response->new($code, undef,
    [ defined $content_type ? ( 'Content-Type' => $content_type ) : () ], $body);
}

# The HTTP transport holds no connection between requests
{
  ok($transport->is_alive, 'HTTP transport is always alive');
}

# Every POST mirrors the request metadata into headers so an intermediary can
# route without parsing the body. MCP::Server::Transport::HTTP::_check_headers
# compares them against the body and answers -32020 for anything missing or
# diverging, so a wrong value here does not degrade the client, it fails every
# single request.

sub headers {
  my ( $method, $params ) = @_;
  return { $transport->_standard_headers($method, $params) };
}

# The header value the server compares is what comes back out of the sentinel
sub decoded_name {
  my ( $value ) = @_;
  return $value unless $value =~ /^=\?base64\?(.*)\?=$/s;
  return decode('UTF-8', decode_base64($1));
}

{
  my $params = {
    name      => 'get_weather',
    arguments => { city => 'Berlin' },
    _meta     => { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28' },
  };
  my $h = headers('tools/call', $params);

  is($h->{'Content-Type'}, 'application/json', 'the JSON content type survives');
  is($h->{'Accept'}, 'application/json, text/event-stream',
    'both response types are still accepted');
  is($h->{'MCP-Protocol-Version'},
    $params->{_meta}{'io.modelcontextprotocol/protocolVersion'},
    'MCP-Protocol-Version comes from the body _meta, so it cannot diverge');
  is($h->{'Mcp-Method'}, 'tools/call', 'Mcp-Method is the method being called');
  is($h->{'Mcp-Name'}, $params->{name}, 'Mcp-Name is the tool name from the body');
}

# The name lives under a different key per method, and the server compares
# against exactly that key
{
  my $prompt = headers('prompts/get', { name => 'greeting' });
  is($prompt->{'Mcp-Name'}, 'greeting', 'prompts/get takes Mcp-Name from params.name');

  my $resource = headers('resources/read', { uri => 'file:///etc/hosts' });
  is($resource->{'Mcp-Name'}, 'file:///etc/hosts',
    'resources/read takes Mcp-Name from params.uri');
}

# A method without a name parameter gets no Mcp-Name at all - an empty one
# would claim the body said something it did not
{
  my $h = headers('tools/list', {
    _meta => { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28' },
  });
  is($h->{'Mcp-Method'}, 'tools/list', 'Mcp-Method is set for a listing method too');
  ok(!exists $h->{'Mcp-Name'}, 'no Mcp-Name for a method without a name parameter');
}

# Header values are bytes, so anything outside printable ASCII travels base64
# encoded in a sentinel the server knows how to undo
{
  my $name = "Wetter-\x{00dc}bersicht";
  my $h = headers('tools/call', { name => $name });
  is($h->{'Mcp-Name'}, '=?base64?V2V0dGVyLcOcYmVyc2ljaHQ=?=',
    'a non-ASCII tool name is base64 encoded as UTF-8 bytes');
  is(decoded_name($h->{'Mcp-Name'}), $name,
    'and the server decodes it back to the name in the body');
}

{
  my $name = "grep\tfiles";
  my $h = headers('tools/call', { name => $name });
  is($h->{'Mcp-Name'}, '=?base64?Z3JlcAlmaWxlcw==?=',
    'a control character outside [\x20-\x7e] is base64 encoded as well');
  is(decoded_name($h->{'Mcp-Name'}), $name,
    'and decodes back to the name in the body');
}

# A name that already looks like the sentinel has to be encoded too, or the
# server would decode a name the body never contained
{
  my $name = '=?base64?Zm9v?=';
  my $h = headers('tools/call', { name => $name });
  is($h->{'Mcp-Name'}, '=?base64?PT9iYXNlNjQ/Wm05dj89?=',
    'a name shaped like the sentinel is encoded rather than passed through');
  is(decoded_name($h->{'Mcp-Name'}), $name,
    'and decodes back to the literal name, not to its inner value');
}

# Net::Async::MCP::initialize sends notifications/initialized without any
# params. There is no protocol version to mirror then, and inventing one would
# be worse than sending none
{
  my $h = headers('notifications/initialized', undef);
  is($h->{'Mcp-Method'}, 'notifications/initialized',
    'a notification without params still names its method');
  ok(!exists $h->{'MCP-Protocol-Version'},
    'no MCP-Protocol-Version header without params to take it from');

  my $no_meta = headers('tools/list', {});
  ok(!exists $no_meta->{'MCP-Protocol-Version'},
    'nor with params that carry no _meta');
  is($no_meta->{'Mcp-Method'}, 'tools/list', 'while Mcp-Method is there either way');
}

# MCP::Server renders a rejected _meta as -32602 with HTTP 400. Reporting the
# status line instead would throw away the only useful part of the answer.
{
  my $f = $transport->_handle_response(response(400, 'application/json',
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Missing protocol version"}}'));
  is($f->failure, 'MCP error -32602: Missing protocol version',
    'HTTP 400 with a JSON-RPC error body surfaces the JSON-RPC error');
}

# MCP::Server answers an unknown method - subscriptions/listen on a server
# without notification support, for one - with -32601 and HTTP 404. The status
# alone would say nothing about which method the server refused.
{
  my $f = $transport->_handle_response(response(404, 'application/json',
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method \'subscriptions/listen\' not found"}}'));
  is($f->failure, "MCP error -32601: Method 'subscriptions/listen' not found",
    'HTTP 404 with a JSON-RPC error body surfaces the JSON-RPC error');
}

# A bare 404 is nothing but a 404. The current revision has no protocol
# sessions, so there is no expired session left to blame it on and the honest
# report is the status line.
{
  my $f = $transport->_handle_response(response(404, 'text/plain', 'Not Found'));
  like($f->failure, qr/^MCP HTTP error: 404/,
    'bare HTTP 404 falls back to the HTTP status line');
}

# A JSON body with a plain string "error" is not a JSON-RPC error. MCP::Server
# answers a bad method with exactly that shape, and a gateway in between may
# invent another one, so it must not be read as a JSON-RPC error object.
{
  my $f = $transport->_handle_response(response(405, 'application/json',
    '{"error":"Method not allowed"}'));
  like($f->failure, qr/^MCP HTTP error: 405/,
    'a non-JSON-RPC error body falls back to the HTTP status line');
}

# Any other non-2xx without a JSON-RPC body keeps the old HTTP-level report
{
  my $f = $transport->_handle_response(
    HTTP::Response->new(502, 'Bad Gateway', [ 'Content-Type' => 'text/html' ], '<html>nope</html>'));
  like($f->failure, qr/^MCP HTTP error: 502/,
    'non-2xx without a JSON-RPC body falls back to the HTTP status line');
}

# The body reaches the JSON decoder as UTF-8 bytes. decoded_content would hand
# back characters, and decoding those again as UTF-8 mangles or dies on
# anything outside ASCII.
{
  my $f = $transport->_handle_response(response(200, 'application/json; charset=utf-8',
    qq({"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Gr\xc3\xbc\xc3\x9fe"}]}})));
  ok($f->is_done, 'utf-8 JSON body parses') or diag $f->failure;
  is($f->is_done && $f->get->{content}[0]{text}, "Gr\x{00fc}\x{00df}e",
    'utf-8 JSON body is decoded exactly once');
}

# Same for SSE, where decoded_content does apply a charset (text/*) and the
# double decoding actually fails
{
  my $body = "event: message\n"
    . qq(data: {"jsonrpc":"2.0","id":1,"result":{"text":"Gr\xc3\xbc\xc3\x9fe"}}\n\n);
  my $f = $transport->_handle_response(response(200, 'text/event-stream', $body));
  ok($f->is_done, 'utf-8 SSE body parses') or diag $f->failure;
  is($f->is_done && $f->get->{text}, "Gr\x{00fc}\x{00df}e",
    'utf-8 SSE body is decoded exactly once');
}

# A successful JSON response still reports a JSON-RPC error as one
{
  my $f = $transport->_handle_response(response(200, 'application/json',
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unknown tool"}}'));
  is($f->failure, 'MCP error -32602: Unknown tool', 'JSON-RPC error in a 200 response');
}

done_testing;
