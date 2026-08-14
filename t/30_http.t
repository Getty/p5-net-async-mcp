use strict;
use warnings;
use Test2::V0;

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

# MCP::Server renders a rejected _meta as -32602 with HTTP 400. Reporting the
# status line instead would throw away the only useful part of the answer.
{
  my $f = $transport->_handle_response(response(400, 'application/json',
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Missing protocol version"}}'));
  is($f->failure, 'MCP error -32602: Missing protocol version',
    'HTTP 400 with a JSON-RPC error body surfaces the JSON-RPC error');
}

# MCP::Server answers an unknown method - subscriptions/listen on a server
# without notification support, for one - with -32601 and HTTP 404. That is a
# method error, not an expired session, and must not drop the session ID.
{
  $transport->{session_id} = 'session-alive';
  my $f = $transport->_handle_response(response(404, 'application/json',
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method \'subscriptions/listen\' not found"}}'));
  is($f->failure, "MCP error -32601: Method 'subscriptions/listen' not found",
    'HTTP 404 with a JSON-RPC error body surfaces the JSON-RPC error');
  is($transport->{session_id}, 'session-alive',
    'session id survives a 404 that carries a JSON-RPC error');
}

# A 404 that is not a JSON-RPC error really is a gone session
{
  $transport->{session_id} = 'session-gone';
  my $f = $transport->_handle_response(response(404, 'text/plain', 'Not Found'));
  like($f->failure, qr/session expired/, 'bare HTTP 404 is an expired session');
  is($transport->{session_id}, undef, 'expired session drops the session id');
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
