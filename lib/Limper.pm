package Limper;
$Limper::VERSION = '0.005';
use 5.10.0;
use strict;
use warnings;

use IO::Socket;

use Exporter qw/import/;
our @EXPORT = qw/get post put del trace status headers request limp/;

# data stored here
my $request = {};
my $response = {};
my $options = {};

# route subs
my $route = {};
sub get($$)    { push @{$route->{GET}},    @_ }
sub post($$)   { push @{$route->{POST}},   @_ }
sub put($$)    { push @{$route->{PUT}},    @_ }
sub del($$)    { push @{$route->{DELETE}}, @_ }
sub trace($$)  { push @{$route->{TRACE}},  @_ }

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
    $request = { headers => [], hheaders => {} };
    $response = {};
    my ($request_line, $headers_done);
    while (1) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm($options->{timeout} // 5);
            $_ = $conn->getline;
            alarm 0;
        };
        last unless defined $_;
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
    my $head = 1;
    (defined $request->{method} and $request->{method} eq 'HEAD') ? ($request->{method} = 'GET') : ($head = 0);
    if (defined $request->{method} and exists $route->{$request->{method}}) {
        for (my $i = 0; $i < @{$route->{$request->{method}}}; $i += 2) {
            if ($route->{$request->{method}}[$i] eq $request->{uri} ||
                        ref $route->{$request->{method}}[$i] eq 'Regexp' and $request->{uri} =~ $route->{$request->{method}}[$i]) {
                $response->{body} = & { $route->{$request->{method}}[$i+1] };
                send_response($conn, $request->{version}, $head);
                return;
            }
        }
    }
    $response->{body} = 'This is the void';
    $response->{status} = 404;
    send_response($conn, $request->{version}, $head);
}

# Sends a response to client.
# Default reponse has Status-Line "200 OK HTTP/1.1", no headers, and no message-body.
sub send_response {
    my ($conn, $version, $head) = @_;
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
        return unless $conn->connected;
        $conn->print('Server: limper/' . ($Limper::VERSION // 'pre-release'));
        $conn->print( join(': ', splice(@{$response->{headers}}, 0, 2)) ) while @{$response->{headers}};
        $conn->print();
    }
    $conn->print($response->{body}) unless $head;
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

sub limp(%) {
    $options = shift @_ if ref $_[0] eq 'HASH';
    my $sock = IO::Socket::INET->new(Listen => SOMAXCONN, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp', @_)
            or die "cannot bind to port: $!";

    logg 'limper started';

    for (1 .. $options->{workers} // 5) {
        defined(my $pid = fork) or die "fork failed: $!";
        while (!$pid) {
            if (my $conn = $sock->accept()) {
                do {
                    get_request $conn;
                    handle_request $conn;
                } while ($conn->connected);
            }
        }
    }
    1 while (wait != -1);

    my $shutdown = $sock->shutdown(2);
    my $closed = $sock->close();
    logg 'shutdown ', $shutdown ? 'successful' : 'unsuccessful';
    logg 'closed ', $closed ? 'successful' : 'unsuccessful';
}

1;

__END__

=head1 NAME

Limper - extremely lightweight but not very powerful web application framework

=head1 VERSION

version 0.005

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
It has a simple syntax like L<Dancer>, but no dependencies at all (except
for the tests, which only run if C<Net::HTTP::Client> is installed), unlike
the dozens that L<Dancer> pulls in.  It also does little to no processing of
requests nor formatting of responses.  This is by design, othewise, just use
L<Dancer>.  There is also no PSGI support or other similar fanciness.

It also fatpacks beautifully (at least on 5.10.1):

  fatpack pack example.pl > example-packed.pl

=head1 EXPORTS

The following are all exported by default:

  get post put del trace
  status headers request limp

=head1 FUNCTIONS

=head2 get

=head2 post

=head2 put

=head2 del

=head2 trace

Defines a route handler for METHOD to the given path:

  get '/' => sub { 'Hello world!' };

Note that a route to match B<HEAD> requests is automatically created as well for C<get>.

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

  Listen => SOMAXCONN, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp'

In addition, the first argument can be a C<HASH> to pass other settings:

  limp({timeout => 60, workers => 10}, LocalAddr => '0.0.0.0', LocalPort => 3001);

Default timeout is C<5> (seconds), and default workers is C<10>. A timeout of C<0> means never timeout.

This keyword should be called at the very end of the script, once all routes
are defined.  At this point, Limper takes over control.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 by Ashley Willis E<lt>ashley@gitable.orgE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.4 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<IO::Socket::INET>

L<Dancer>

L<Dancer2>

L<Web::Simple>

L<App::FatPacker>
