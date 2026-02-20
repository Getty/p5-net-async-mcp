package Net::Async::MCP::Transport::InProcess;
# ABSTRACT: In-process MCP transport via direct MCP::Server calls

use strict;
use warnings;

use Future;
use Scalar::Util qw( blessed );
use Carp qw( croak );

sub new {
  my ( $class, %args ) = @_;
  croak "server is required" unless $args{server};
  return bless {
    server  => $args{server},
    next_id => 0,
  }, $class;
}

sub send_request {
  my ( $self, $method, $params ) = @_;

  my $id = ++$self->{next_id};
  my $request = {
    jsonrpc => '2.0',
    id      => $id,
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  my $response = $self->{server}->handle($request, {});

  # Handle Mojo::Promise from async MCP tools
  if (blessed($response) && $response->isa('Mojo::Promise')) {
    my ( $resolved, $error );
    $response->then(
      sub { $resolved = $_[0] },
      sub { $error = $_[0] },
    )->wait;
    return Future->fail("MCP async tool error: $error") if $error;
    $response = $resolved;
  }

  return $self->_process_response($response);
}

sub send_notification {
  my ( $self, $method, $params ) = @_;

  my $request = {
    jsonrpc => '2.0',
    method  => $method,
    defined $params ? ( params => $params ) : (),
  };

  $self->{server}->handle($request, {});
  return Future->done;
}

sub close { Future->done }

sub _process_response {
  my ( $self, $response ) = @_;

  return Future->fail("No response from MCP server") unless $response;
  return Future->fail("Invalid response from MCP server")
    unless ref $response eq 'HASH';

  if (my $err = $response->{error}) {
    return Future->fail("MCP error $err->{code}: $err->{message}");
  }

  return Future->done($response->{result});
}

1;

=head1 SYNOPSIS

  # Usually created automatically by Net::Async::MCP
  use Net::Async::MCP;
  my $mcp = Net::Async::MCP->new(server => $my_mcp_server);

=head1 DESCRIPTION

L<Net::Async::MCP::Transport::InProcess> provides direct in-process
communication with an L<MCP::Server> instance. It calls C<handle()>
directly on the server object, making it the most efficient transport
for Perl-based MCP servers.

If a tool returns a L<Mojo::Promise> (async MCP tool), the promise is
resolved synchronously via C<wait()>. For non-blocking async tools,
use the Stdio transport with a separate process instead.

=method send_request

  my $future = $transport->send_request($method, \%params);

Sends a JSON-RPC request to the server and returns a L<Future> that
resolves to the result.

=method send_notification

  my $future = $transport->send_notification($method, \%params);

Sends a JSON-RPC notification (no response expected).

=method close

  my $future = $transport->close;

No-op for InProcess transport. Returns a resolved L<Future>.

=seealso L<Net::Async::MCP>, L<MCP::Server>

=cut
