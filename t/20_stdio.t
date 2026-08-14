use strict;
use warnings;
use Test2::V0;

use IO::Async::Loop;
use JSON::MaybeXS;
use Net::Async::MCP;
use Net::Async::MCP::Transport::Stdio;
use File::Basename qw( dirname );

my $server_script = dirname(__FILE__) . '/bin/test_mcp_server.pl';

# Create MCP client with Stdio transport
my $loop = IO::Async::Loop->new;
my $mcp = Net::Async::MCP->new(
  command => [ $^X, $server_script ],
);
$loop->add($mcp);

# Test initialize (current protocol: server/discover + _meta)
{
  my $result = $mcp->initialize->get;
  is($result->{_meta}{'io.modelcontextprotocol/serverInfo'}{name},
    'TestServer', 'server name in result._meta serverInfo');
  ok($result->{capabilities}, 'capabilities returned');
  is($mcp->server_info->{name}, 'TestServer', 'server_info accessor');
}

# Test ping
{
  my $ok = $mcp->ping->get;
  ok($ok, 'ping succeeds');
}

# Test list_tools
{
  my $tools = $mcp->list_tools->get;
  is(scalar @$tools, 2, 'two tools listed');

  my %by_name = map { $_->{name} => $_ } @$tools;
  ok($by_name{echo}, 'echo tool exists');
  ok($by_name{add}, 'add tool exists');
}

# Test call_tool - echo
{
  my $result = $mcp->call_tool('echo', { message => 'via stdio' })->get;
  ok(!$result->{isError}, 'echo not an error');
  is($result->{content}[0]{text}, 'Echo: via stdio', 'echo result correct');
}

# Test call_tool - add
{
  my $result = $mcp->call_tool('add', { a => 10, b => 20 })->get;
  ok(!$result->{isError}, 'add not an error');
  is($result->{content}[0]{text}, '30', 'add result correct');
}

# Test multiple rapid requests
{
  my @futures;
  for my $i (1..5) {
    push @futures, $mcp->call_tool('echo', { message => "msg$i" });
  }
  for my $i (1..5) {
    my $result = $futures[$i-1]->get;
    is($result->{content}[0]{text}, "Echo: msg$i", "rapid request $i correct");
  }
}

# Test shutdown
{
  my $ok = $mcp->shutdown->get;
  ok($ok, 'shutdown succeeds');
}

# ping is a transport-level liveness check, so once the subprocess is gone it
# must report that instead of claiming the server is still reachable.
{
  my $f = $mcp->ping;
  ok($f->failure, 'ping fails after the subprocess has exited');
  like($f->failure, qr/not alive/, 'failure names a dead transport');
}

# Cancellation. On stdio the only way to tell a server to stop is the
# notifications/cancelled notification, and the only handle a caller has on a
# request is the future send_request returned - so cancelling that future is
# what has to produce it. The Perl test server ignores notifications entirely,
# so what is asserted here is the wire content, not a server-side effect.
{
  my $json = JSON::MaybeXS->new(utf8 => 1, canonical => 1);

  # Records every line it is given and answers every request with the
  # transcript so far. That makes what reached the subprocess assertable from
  # a normal response, with no log file to poll and no sleeps to race.
  my $recorder = Net::Async::MCP::Transport::Stdio->new(
    command => [
      $^X, '-MJSON::MaybeXS', '-e', q{
        my $json = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
        my @seen;
        $| = 1;
        while (defined(my $line = <STDIN>)) {
          chomp $line;
          next if $line eq '';
          push @seen, $line;
          my $message = $json->decode($line);
          next unless defined $message->{id};
          print $json->encode({
            jsonrpc => '2.0',
            id      => $message->{id},
            result  => { seen => [ @seen ] },
          }), "\n";
        }
      },
    ],
  );
  $loop->add($recorder);

  my $cancelled = $recorder->send_request('tools/call', { name => 'slow' });
  is(scalar keys %{ $recorder->{pending} }, 1, 'request is pending before cancellation');

  $cancelled->cancel;
  is(scalar keys %{ $recorder->{pending} }, 0, 'cancellation drops the pending entry');

  # The recorder does answer the cancelled request too; that response has to
  # land on nothing and must not be mistaken for the answer to this probe.
  my $seen = $recorder->send_request('ping')->get->{seen};
  is(scalar @$seen, 3, 'request, cancellation and probe reached the subprocess');

  my $note = $json->decode($seen->[1]);
  is($note->{jsonrpc}, '2.0', 'cancellation is JSON-RPC 2.0');
  is($note->{method}, 'notifications/cancelled', 'cancellation uses the notification method');
  ok(!exists $note->{id}, 'cancellation is a notification, carrying no id of its own');
  is($note->{params}{requestId}, $json->decode($seen->[0])->{id},
    'requestId names the request that was cancelled');

  # A request that already has its answer must send nothing when cancelled,
  # otherwise every completed call would leave a stray notification behind.
  my $answered = $recorder->send_request('ping');
  my $before = scalar @{ $answered->get->{seen} };
  $answered->cancel;
  ok($answered->is_done, 'an answered request stays done through ->cancel');
  my $after = $recorder->send_request('ping')->get->{seen};
  is(scalar @$after, $before + 1, 'cancelling a finished request sends nothing');

  # close marks the transport closed while the subprocess is still dying, so
  # a cancellation in that window must not write into the doomed pipe.
  my $in_flight = $recorder->send_request('tools/call', { name => 'doomed' });
  my $closing = $recorder->close;
  ok(!$in_flight->is_ready, 'request is still pending right after close');
  ok(lives { $in_flight->cancel }, 'cancelling on a closed transport does not die')
    or note $@;
  is(scalar keys %{ $recorder->{pending} }, 0,
    'cancellation on a closed transport still drops the pending entry');
  $closing->get;
}

done_testing;
