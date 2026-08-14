package Net::Async::MCP::Transport::Stdio;
# ABSTRACT: Stdio MCP transport via subprocess JSON-RPC
use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future;
use JSON::MaybeXS;
use Carp qw( croak );
use Scalar::Util qw( weaken );

=head1 SYNOPSIS

    # Usually created automatically by Net::Async::MCP
    use IO::Async::Loop;
    use Net::Async::MCP;

    my $loop = IO::Async::Loop->new;
    my $mcp = Net::Async::MCP->new(
        command => ['npx', '@anthropic/mcp-server-web-search'],
    );
    $loop->add($mcp);

=head1 DESCRIPTION

L<Net::Async::MCP::Transport::Stdio> communicates with an external MCP server
process via stdin/stdout using newline-delimited JSON-RPC 2.0. The subprocess
is managed as an L<IO::Async::Process> child notifier.

This transport works with any MCP server that supports the stdio transport,
regardless of implementation language (Perl, Node.js, Python, Go, etc.).

Requests are matched to responses by their JSON-RPC C<id> field. Each pending
request is represented by a L<Future> that resolves when the matching response
arrives. If the subprocess exits unexpectedly, all pending futures are failed
with an error message including the exit code.

This transport is selected automatically by L<Net::Async::MCP> when constructed
with a C<command> argument.

=cut

sub _init {
  my ( $self, $params ) = @_;
  $self->{command} = delete $params->{command}
    or croak "command is required";
  $self->{pending} = {};
  $self->{next_id} = 0;
  $self->{buffer}  = '';
  $self->{closed}  = 0;
  $self->{json}    = JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1);
  $self->SUPER::_init($params);
}

sub configure {
  my ( $self, %params ) = @_;
  if (exists $params{command}) {
    $self->{command} = delete $params{command};
  }
  $self->SUPER::configure(%params);
}

sub _add_to_loop {
  my ( $self, $loop ) = @_;
  $self->SUPER::_add_to_loop($loop);

  require IO::Async::Process;

  # These callbacks end up on the process, and on the child streams the process
  # owns, while the transport owns the process - so capturing the transport
  # strongly here would close a cycle no refcount ever breaks, and the transport
  # would outlive its own client. Weakening them costs nothing: as long as
  # either callback can still fire, the loop holds the transport for us. The
  # loop keeps its notifiers alive strongly, and taking the transport out of the
  # loop takes the process out with it, which unwatches the child and silences
  # both callbacks. So the weak reference is never undef where it matters; the
  # guards below are for the DESTROY-ordering case only.
  weaken( my $weak_self = $self );

  my $process = IO::Async::Process->new(
    command => $self->{command},
    stdin   => { via => 'pipe_write' },
    stdout  => {
      on_read => sub {
        my ( $stream, $buffref, $eof ) = @_;
        my $self = $weak_self or return 0;
        $self->_on_stdout_read($buffref, $eof);
        return 0;
      },
    },
    stderr => {
      on_read => sub {
        my ( $stream, $buffref, $eof ) = @_;
        $$buffref = '';
        return 0;
      },
    },
    on_finish => sub {
      my ( $proc, $exitcode ) = @_;
      my $self = $weak_self or return;
      $self->_on_finish($exitcode);
    },
  );

  $self->{process} = $process;
  $self->add_child($process);
}

sub send_request {
  # %options: binding hints from the client, none of which apply on stdio
  my ( $self, $method, $params, %options ) = @_;

  if ($self->{closed}) {
    return Future->fail("MCP server process has exited");
  }

  my $id = ++$self->{next_id};
  my $request = {
    jsonrpc => '2.0',
    id      => $id,
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $json_line = $self->{json}->encode($request) . "\n";
  $self->{process}->stdin->write($json_line);

  my $future = $self->loop->new_future;
  $self->{pending}{$id} = $future;

  # The pending table holds the future and the future holds this callback, so
  # the callback must not hold the transport: that closes a reference cycle no
  # refcount ever breaks. Future drops its on_cancel list as soon as a future
  # is marked ready, so a request answered by the server, or failed by
  # _on_finish, never reaches this code.
  weaken( my $weak_self = $self );
  $future->on_cancel(sub {
    my $self = $weak_self or return;
    delete $self->{pending}{$id};
    return if $self->{closed};
    $self->send_notification('notifications/cancelled', { requestId => $id });
    return;
  });

  return $future;
}

=method send_request

    my $future = $transport->send_request($method, \%params);

Encodes a JSON-RPC request and writes it as a newline-terminated JSON line to
the subprocess stdin. Returns a L<Future> that resolves to the C<result> value
when the matching response is read from stdout, or fails with an error if the
server returns a JSON-RPC error or the process exits.

A JSON-RPC error fails the L<Future> with more than its message. L<Future>'s
failure convention is C<< ( $message, $category, @details ) >>, so the failure
reads C<< ( "MCP error $code: $message", 'mcp', $error ) >>: in scalar context
C<< ->failure >> is the message and nothing has changed, and in list context
the raw JSON-RPC error object comes with it.

    my ( $message, $category, $error ) = $future->failure;
    if (($category // '') eq 'mcp') {
      my $code      = $error->{code};          # -32601, -32602, ...
      my $supported = $error->{data}{supported};
    }

The C<mcp> category marks a genuine JSON-RPC error from the server and nothing
else. The failures this transport raises on its own - a request sent after the
subprocess has exited, and a request still pending when it does - carry their
message alone, so a caller that finds no category knows there is no server
error object behind it.

Fails immediately if the subprocess has already exited.

Cancelling the returned L<Future> cancels the request: the pending entry is
dropped, so a response that still arrives for it is discarded, and a
C<notifications/cancelled> notification naming that request in C<requestId> is
written to the subprocess stdin. No C<reason> is sent, since C<< ->cancel >>
carries no argument to put there. Nothing is written if the future is already
done or failed, or if the subprocess has exited: a cancellation never writes
into a dead pipe.

This is the stdio form of cancellation. On Streamable HTTP a request is
cancelled by closing its response stream instead, so
L<Net::Async::MCP::Transport::HTTP> sends no such notification. Note that an
MCP server is free to ignore the notification and finish the request anyway;
cancelling only guarantees that this client stops caring about the answer.

Accepts the same optional trailing name/value options as the other transports,
C<header_params> among them, and ignores all of them: they describe how a
request is mirrored into HTTP headers, of which a JSON-RPC line on stdin has
none. See L<Net::Async::MCP::Transport::HTTP/send_request>.

=cut

sub send_notification {
  my ( $self, $method, $params ) = @_;

  if ($self->{closed}) {
    return Future->fail("MCP server process has exited");
  }

  my $request = {
    jsonrpc => '2.0',
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $json_line = $self->{json}->encode($request) . "\n";
  $self->{process}->stdin->write($json_line);

  return Future->done;
}

=method send_notification

    my $future = $transport->send_notification($method, \%params);

Encodes a JSON-RPC notification (no C<id> field, no response expected) and
writes it to the subprocess stdin. Returns an immediately resolved L<Future>.

Fails immediately if the subprocess has already exited.

=cut

sub close {
  my ( $self ) = @_;
  return Future->done if $self->{closed};

  $self->{closed} = 1;

  if ($self->{process} && $self->{process}->is_running) {
    my $future = $self->loop->new_future;
    $self->{close_future} = $future;
    $self->{process}->kill('TERM');
    return $future;
  }

  return Future->done;
}

=method close

    my $future = $transport->close;

Sends SIGTERM to the subprocess and returns a L<Future> that resolves when
the process exits. If the process has already exited, returns an immediately
resolved L<Future>.

=cut

sub is_alive { !$_[0]->{closed} }

=method is_alive

    my $alive = $transport->is_alive;

Returns true while the subprocess can still carry requests, and false once it
has exited or L</close> has been called. Used by L<Net::Async::MCP/ping> for
its transport-level liveness check.

=cut

sub mirrors_header_params { 0 }

=method mirrors_header_params

    my $mirrors = $transport->mirrors_header_params;

Always false: a JSON-RPC line on stdin has no headers to mirror tool arguments
annotated with C<x-mcp-header> into, so L<Net::Async::MCP/call_tool> resolves
none and never fetches a tool list to do it.

=cut

sub _on_stdout_read {
  my ( $self, $buffref, $eof ) = @_;
  $self->{buffer} .= $$buffref;
  $$buffref = '';

  while ($self->{buffer} =~ s/^(.*?)\n//) {
    my $line = $1;
    $line =~ s/\r$//;
    next if $line eq '';

    my $response = eval { $self->{json}->decode($line) };
    next unless $response && ref $response eq 'HASH';

    my $id = $response->{id};
    next unless defined $id;

    my $future = delete $self->{pending}{$id};
    next unless $future;

    # The raw JSON-RPC error object travels with the message as the details of
    # a failure in category "mcp", so a caller can read the code and any
    # error->{data} the server sent instead of parsing the message for them.
    if (my $err = $response->{error}) {
      $future->fail("MCP error $err->{code}: $err->{message}", mcp => $err);
    }
    else {
      $future->done($response->{result});
    }
  }
}

sub _on_finish {
  my ( $self, $exitcode ) = @_;
  $self->{closed} = 1;

  for my $id (keys %{$self->{pending}}) {
    my $future = delete $self->{pending}{$id};
    $future->fail("MCP server process exited (code $exitcode)")
      if $future && !$future->is_ready;
  }

  if ($self->{close_future} && !$self->{close_future}->is_ready) {
    $self->{close_future}->done;
  }
}

=seealso

=over 4

=item * L<Net::Async::MCP> - Main client module that uses this transport

=item * L<Net::Async::MCP::Transport::InProcess> - Alternative transport for in-process Perl servers

=item * L<IO::Async::Process> - Subprocess management used internally

=item * L<IO::Async::Notifier> - Base class

=back

=cut

1;
