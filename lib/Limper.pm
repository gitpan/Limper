package Limper;
$Limper::VERSION = '0.002';
=head1 NAME

Limper - extremely lightweight but not very powerful web application framework

=head1 VERSION

Version 0.001

=head1 SYNOPSIS

  use Limper;

  my $generic = sub { 'yay' };

  get '/' => $generic;
  post '/' => $generic;

  post qr{^/foo/} => sub {
      status 202, 'whatevs';
      headers Foo => 'bar', Fizz => 'buzz';
      'you posted something: ' . request->{body};
  };

  limp;

=head1 DESCRIPTION

C<Limper> is designed primarily to be a simple HTTP/1.1 test server in perl.
It has a simple syntax like L<Dancer>, but no dependencies at all (expect
for the tests), unlike the dozens that L<Dancer> pulls in.  It also does
little to no processing of requests nor formatting of responses.  This is by
design, othewise, just use L<Dancer>.

=head1 EXPORTS

The following are all exported by default:

  get head post put delete trace
  status headers request limp

=head1 FUNCTIONS

=head2 get

=head2 head

=head2 post

=head2 put

=head2 delete

=head2 trace

Defines a route handler for METHOD to the given path:

  get '/' => sub { 'Hello world!' };

=head2 status

Get or set the response status, and optionally reason.

  status 404;
  status 401, 'Nope';
  my $status = status;
  my ($status, $reason) = status;

=head2 headers

Get or set the response headers.

  headers Foo => 'bar', Fizz => 'buzz';
  my @headers = headers;
  my $headers = headers;

=head2 request

Returns a C<HASH> of the request. Request keys are: C<method>, C<uri>, and
C<version>.  It may also contain C<headers> which is an C<ARRAY>,
C<hheaders> which is a C<HASH> form of the headers, and C<body>.

There is no decoding of the body content nor URL paramters.

=head2 limp

Starts the server. You can pass it the same options as L<IO::Socket::INET> takes. The default options are:

  Listen => 5, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp'

This keyword should be called at the very end of the script, once all routes
are defined.  At this point, Limper takes over control.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 by Ashley Willis E<lt>ashley@gitable.orgE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.4 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<IO::Socket::INET>

=cut

use 5.10.0;
use strict;
use warnings;

use IO::Socket;

use Data::Dumper;
$Data::Dumper::Terse = 1;

use Exporter qw/import/;
our @EXPORT = qw/get head post put delete trace status headers request limp/;

# data stored here
my $request = {};
my $response = {};

# route subs
my $route = {};
sub get($$)    { $route->{GET}{$_[0]} = $_[1] }
sub head($$)   { $route->{HEAD}{$_[0]} = $_[1] }
sub post($$)   { $route->{POST}{$_[0]} = $_[1] }
sub put($$)    { $route->{PUT}{$_[0]} = $_[1] }
sub delete($$) { $route->{DELETE}{$_[0]} = $_[1] }
sub trace($$)  { $route->{TRACE}{$_[0]} = $_[1] }

# for send_response()
my $reasons = {
    100 => 'Continue',
    101 => 'Switching Protocols',
    200 => 'OK',
    201 => 'Created',
    202 => 'Accepted',
    203 => 'Non-Authoritative Information',
    204 => 'No Content',
    205 => 'Reset Content',
    206 => 'Partial Content',
    300 => 'Multiple Choices',
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    304 => 'Not Modified',
    305 => 'Use Proxy',
    307 => 'Temporary Redirect',
    400 => 'Bad Request',
    401 => 'Unauthorized',
    402 => 'Payment Required',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',
    407 => 'Proxy Authentication Required',
    408 => 'Request Time-out',
    409 => 'Conflict',
    410 => 'Gone',
    411 => 'Length Required',
    412 => 'Precondition Failed',
    413 => 'Request Entity Too Large',
    414 => 'Request-URI Too Large',
    415 => 'Unsupported Media Type',
    416 => 'Requested range not satisfiable',
    417 => 'Expectation Failed',
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    502 => 'Bad Gateway',
    503 => 'Service Unavailable',
    504 => 'Gateway Time-out',
    505 => 'HTTP Version not supported',
};

# for get_request()
my $method_rx = qr/(?: OPTIONS | GET | HEAD | POST | PUT | DELETE | TRACE | CONNECT )/x;
my $version_rx = qr{HTTP/\d+\.\d+};
my $uri_rx = qr/[^ ]+/;

# for handle_request()
my $regex = quotemeta qr//;
$regex =~ s/\\\)$/.*\\\)/;



# Formats date like "2014-08-17 00:12:41" in UTC.
sub date() {
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
    sprintf '%04d-%02d-%02d %02d:%02d:%02d', $year + 1900, $mon, $mday, $hour, $min, $sec;
}

# Trivially logs things to STDOUT.
sub logg(@) {
    say date, ' ', @_;
}

# Returns a processed request as a hash.
# Will simply close the connection if an invalid Request-Line or header entry.
sub get_request($) {
    my ($conn) = @_;
    $request = {};
    $response = {};
    my ($request_line, $headers_done);
    while (defined($_ = $conn->getline)) {
        if (!defined $request_line) {
            ($request->{method}, $request->{uri}, $request->{version}) = $_ =~ /^($method_rx) ($uri_rx) ($version_rx)\r\n/;
            if (!defined $request->{method}) {
                chomp;
                logg "[", $conn->peerhost // "localhost", "] invalid request: $_";
                $conn->close();
                last;
            }
            $request_line = 1;
        } elsif (!defined $headers_done) {
            if (/^\r\n/) {
                $headers_done = 1;
            } else {
                my ($name, $value) = split /: /, $_, 2;
                if ($name =~ /\r\n/) {
                    chomp;
                    logg "[", $conn->peerhost // "localhost", "] invalid header: $_";
                    $conn->close();
                    last;
                }
                $value =~ s/\r\n//;
                push @{$request->{headers}}, lc $name, $value;
                if (exists $request->{hheaders}{lc $name}) {
                    if (ref $request->{hheaders}{lc $name}) {
                        push @{$request->{hheaders}{lc $name}}, $value;
                    } else {
                        $request->{hheaders}{lc $name} = [$request->{hheaders}{lc $name}, $value];
                    }
                } else {
                    $request->{hheaders}{lc $name} = $value;
                }
            }
        }
        if (defined $headers_done) {
            logg "[", $conn->peerhost // "localhost", "] $request->{method} $request->{uri} $request->{version} [", {@{$request->{headers}}}->{'user-agent'} // "", "]";
            for (my $i = 0; $i < @{$request->{headers}}; $i += 2) {
                if ($request->{headers}[$i] eq 'content-length') {
                    $conn->read($request->{body}, $request->{headers}[$i+1]);
                    last;
                }
            }
            last;
        }
    }
}

# Finds the appropriate route sub to call, and calls it.
# If no valid route found, sends a 404 response.
sub handle_request($) {
    my ($conn) = @_;
    # request keys: method, uri, version, [headers], [hheaders], [body]
    if (exists $route->{$request->{method}}) {
        if (exists $route->{$request->{method}}{$request->{uri}}) {
            $response->{body} = & { $route->{$request->{method}}{$request->{uri}} };
            send_response($conn, $request->{version});
            return;
        }
        for (grep { /^$regex$/ } keys %{ $route->{$request->{method}} }) {
            if ($request->{uri} =~ /$_/) {
                $response->{body} = & { $route->{$request->{method}}{$_} };
                send_response($conn, $request->{version});
                return;
            }
        }
    }
    $response->{body} = 'This is the void';
    $response->{status} = 404;
    send_response($conn, $request->{version});
}

# Sends a response to client.
# Default reponse has Status-Line "200 OK HTTP/1.1", no headers, and no message-body.
sub send_response {
    my ($conn, $version) = @_;
    $version //= 'HTTP/1.1';
    $response->{status} //= 200;
    $response->{reason} //= $reasons->{$response->{status}};
    $response->{body} //= '';
    if ($response->{body}) {
        $response->{headers} //= [];
        my @headers = keys %{{@{$response->{headers}}}};
        push @{$response->{headers}}, ('Content-Length', length $response->{body}) unless grep { $_ eq 'Content-Length' } @headers;
        push @{$response->{headers}}, ('Content-Type', 'text/plain') unless grep { $_ eq 'Content-Type' } @headers;
    }
    {
        local $\ = "\r\n";
        $conn->print("$version $response->{status} $response->{reason}");
        $conn->print( join(': ', splice(@{$response->{headers}}, 0, 2)) ) while @{$response->{headers}};
        $conn->print();
    }
    $conn->print($response->{body});
}

sub status(;$$) {
    if (defined wantarray) {
        wantarray ? ($response->{status}, $response->{reason}) : $response->{status};
    } else {
        $response->{status} = shift;
        $response->{reason} = shift if @_;
    }
}

sub request() {
    $request;
}

sub headers(%) {
    if (defined wantarray) {
        wantarray ? @{$response->{headers}} : $response->{headers};
    } else {
        @{$response->{headers}} = @_;
    }
}

# Prints parsed request to STDERR, but without the headers ARRAY.
sub dump_request() {
    my $headers = delete $request->{headers};
    warn Dumper $request;
    $request->{headers} = $headers;
}

sub limp(%) {
    my $sock = IO::Socket::INET->new(Listen => 5, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp', @_)
            or die "cannot bind to port: $!";

    logg 'limper started';

    while (1) {
        if (my $conn = $sock->accept()) {
            get_request $conn;
            next unless defined $request->{method};
            #dump_request;
            handle_request $conn;
        }
    }

    my $shutdown = $sock->shutdown(2);
    my $closed = $sock->close();
    logg 'shutdown ', $shutdown ? 'successful' : 'unsuccessful';
    logg 'closed ', $closed ? 'successful' : 'unsuccessful';
}

1;
