package Net::Async::MCP::Transport::Stdio;
# ABSTRACT: Stdio MCP transport via subprocess JSON-RPC

use strict;
use warnings;
use parent 'IO::Async::Notifier';

use Future;
use JSON::MaybeXS;
use Carp qw( croak );

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

  my $process = IO::Async::Process->new(
    command => $self->{command},
    stdin   => { via => 'pipe_write' },
    stdout  => {
      on_read => sub {
        my ( $stream, $buffref, $eof ) = @_;
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
      $self->_on_finish($exitcode);
    },
  );

  $self->{process} = $process;
  $self->add_child($process);
}

sub send_request {
  my ( $self, $method, $params ) = @_;

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
  return $future;
}

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

    if (my $err = $response->{error}) {
      $future->fail("MCP error $err->{code}: $err->{message}");
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

1;

=head1 SYNOPSIS

  # Usually created automatically by Net::Async::MCP
  use Net::Async::MCP;
  my $mcp = Net::Async::MCP->new(
    command => ['npx', '@anthropic/mcp-server-web-search'],
  );

=head1 DESCRIPTION

L<Net::Async::MCP::Transport::Stdio> communicates with an external MCP
server process via stdin/stdout using newline-delimited JSON-RPC. The
subprocess is managed as an L<IO::Async::Process> child.

This transport works with any MCP server that supports the stdio
transport, regardless of implementation language (Perl, Node.js, Python,
etc.).

=method send_request

  my $future = $transport->send_request($method, \%params);

Sends a JSON-RPC request and returns a L<Future> that resolves when the
server responds.

=method send_notification

  my $future = $transport->send_notification($method, \%params);

Sends a JSON-RPC notification (no response expected).

=method close

  my $future = $transport->close;

Sends SIGTERM to the subprocess and returns a L<Future> that resolves
when the process exits.

=seealso L<Net::Async::MCP>, L<IO::Async::Process>

=cut
