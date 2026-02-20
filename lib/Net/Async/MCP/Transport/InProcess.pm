package Net::Async::MCP::Transport::InProcess;
# ABSTRACT: In-process MCP transport via direct MCP::Server calls
our $VERSION = '0.002';
use strict;
use warnings;

use Future;
use Scalar::Util qw( blessed );
use Carp qw( croak );

=head1 SYNOPSIS

    # Usually created automatically by Net::Async::MCP
    use Net::Async::MCP;

    my $mcp = Net::Async::MCP->new(server => $my_mcp_server);
    $loop->add($mcp);

    # Or construct directly for testing:
    use Net::Async::MCP::Transport::InProcess;

    my $transport = Net::Async::MCP::Transport::InProcess->new(
        server => $my_mcp_server,
    );

=head1 DESCRIPTION

L<Net::Async::MCP::Transport::InProcess> provides direct in-process
communication with an L<MCP::Server> instance. It calls C<handle()>
directly on the server object, making it the most efficient transport for
Perl-based MCP servers running in the same process.

If a tool returns a L<Mojo::Promise> (from an async MCP server
implementation), the promise is resolved synchronously via C<wait()>. For
fully non-blocking async tools, use L<Net::Async::MCP::Transport::Stdio>
with a separate subprocess instead.

This transport is selected automatically by L<Net::Async::MCP> when
constructed with a C<server> argument.

=cut

sub new {
  my ( $class, %args ) = @_;
  croak "server is required" unless $args{server};
  return bless {
    server  => $args{server},
    next_id => 0,
  }, $class;
}

=method new

    my $transport = Net::Async::MCP::Transport::InProcess->new(
        server => $mcp_server,
    );

Constructs a new in-process transport. Requires a C<server> argument which
must be an L<MCP::Server> instance (or any object with a C<handle> method
that accepts a JSON-RPC request hashref).

=cut

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

=method send_request

    my $future = $transport->send_request($method, \%params);

Sends a JSON-RPC request to the MCP server by calling C<handle()> directly.
Returns a L<Future> that resolves to the C<result> value from the response,
or fails with an error message if the server returns a JSON-RPC error.

=cut

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

=method send_notification

    my $future = $transport->send_notification($method, \%params);

Sends a JSON-RPC notification (a request with no C<id>, expecting no
response) directly to the server via C<handle()>. Returns an immediately
resolved L<Future>.

=cut

sub close { Future->done }

=method close

    my $future = $transport->close;

No-op for the in-process transport since there is no external process or
connection to close. Returns an immediately resolved L<Future>.

=cut

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

=seealso

=over 4

=item * L<Net::Async::MCP> - Main client module that uses this transport

=item * L<Net::Async::MCP::Transport::Stdio> - Alternative transport for external subprocesses

=item * L<MCP::Server> - The MCP server this transport communicates with

=back

=cut

1;
