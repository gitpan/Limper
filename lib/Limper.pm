package Limper;
$Limper::VERSION = '0.010';
use 5.10.0;
use strict;
use warnings;

use IO::Socket;

use Exporter qw/import/;
our @EXPORT = qw/get post put del trace status headers request response options hook limp/;
our @EXPORT_OK = qw/note warning rfc1123date/;

# data stored here
my $request = {};
my $response = {};
my $options = {};
my $hook = {};
my $conn;

# route subs
my $route = {};
sub get    { push @{$route->{GET}},    @_ }
sub post   { push @{$route->{POST}},   @_ }
sub put    { push @{$route->{PUT}},    @_ }
sub del    { push @{$route->{DELETE}}, @_ }
sub trace  { push @{$route->{TRACE}},  @_ }

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

# Returns current time or passed timestamp as an HTTP 1.1 date
my @months = qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
my @days = qw/Sun Mon Tue Wed Thu Fri Sat/;
sub rfc1123date {
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = @_ ? gmtime $_[0] : gmtime;
    sprintf '%s, %02d %s %4d %02d:%02d:%02d GMT', $days[$wday], $mday, $months[$mon], $year + 1900, $hour, $min, $sec;
}

# Formats date like "2014-08-17 00:12:41" in local time.
sub date {
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
    sprintf '%04d-%02d-%02d %02d:%02d:%02d', $year + 1900, $mon, $mday, $hour, $min, $sec;
}

# Trivially log to STDOUT or STDERR
sub note    { say  date, ' ', @_ }
sub warning { warn date, ' ', @_ }

sub timeout {
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm($options->{timeout} // 5);
        $_ = $_[0]->();
        alarm 0;
    };
    $@ ? ($conn->close and undef) : $_;
}

sub bad_request {
    warning "[$request->{remote_host}] bad request: $_[0]";
    $response = { status => 400, body => 'Bad Request' };
    send_response($request->{method} // '' eq 'HEAD', 'close');
}

# Returns a processed request as a hash, or sends a 400 and closes if invalid.
sub get_request {
    $request = { headers => [], hheaders => {}, remote_host => $conn->peerhost // 'localhost' };
    $response = { headers => [] };
    my ($request_line, $headers_done, $chunked);
    while (1) {
        defined(my $line = timeout(sub { $conn->getline })) or last;
        if (!defined $request_line) {
            next if $line eq "\r\n";
            ($request->{method}, $request->{uri}, $request->{version}) = $line =~ /^($method_rx) ($uri_rx) ($version_rx)\r\n/;
            return bad_request $line unless defined $request->{method};
            $request_line = 1;
        } elsif (!defined $headers_done) {
            if ($line =~ /^\r\n/) {
                $headers_done = 1;
            } else {
                my ($name, $value) = split /:[ \t]*/, $line, 2;
                if ($name =~ /\r\n/) {
                    return bad_request $line;
                }
                $value =~ s/\r\n//;
                $value = $1 if lc $name eq 'host' and $request->{version} eq 'HTTP/1.1' and $request->{uri} =~ s{^https?://(.+?)/}{/};
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
            return if defined $chunked;
            note "[$request->{remote_host}] $request->{method} $request->{uri} $request->{version} [", {@{$request->{headers}}}->{'user-agent'} // "", "]";
            return bad_request 'Host header missing' if $request->{version} eq 'HTTP/1.1' and (!exists $request->{hheaders}{host} or ref $request->{hheaders}{host});
            for (my $i = 0; $i < @{$request->{headers}}; $i += 2) {
                if ($request->{headers}[$i] eq 'expect' and lc $request->{headers}[$i+1] eq '100-continue' and $request->{version} eq 'HTTP/1.1') {
                    $conn->print("HTTP/1.1 100 Continue\r\n\r\n");	# this does not check if route is valid. just here to comply.
                }
                if ($request->{headers}[$i] eq 'content-length') {
                    timeout(sub { $conn->read($request->{body}, $request->{headers}[$i+1]) });
                    last;
                } elsif ($request->{headers}[$i] eq 'transfer-encoding' and lc $request->{headers}[$i+1] eq 'chunked') {
                    my $length = my $offset = $chunked = 0;
                    do {
                        $_ = timeout(sub { $conn->getline });
                        $length = hex((/^([A-Fa-f0-9]+)(?:;.*)?\r\n/)[0]);
                        timeout(sub { $conn->read($request->{body}, $length + 2, $offset) }) if $length;
                        $offset += $length;
                    } while $length;
                    $request->{body} =~ s/\r\n$//;
                    undef $headers_done; # to get optional footers, and another blank line
                }
            }
            last if defined $headers_done;
        }
    }
}

# Finds and calls the appropriate route sub, or sends a 404 response.
sub handle_request {
    my $head = 1;
    (defined $request->{method} and $request->{method} eq 'HEAD') ? ($request->{method} = 'GET') : ($head = 0);
    if (defined $request->{method} and exists $route->{$request->{method}}) {
        for (my $i = 0; $i < @{$route->{$request->{method}}}; $i += 2) {
            if ($route->{$request->{method}}[$i] eq $request->{uri} ||
                        ref $route->{$request->{method}}[$i] eq 'Regexp' and $request->{uri} =~ $route->{$request->{method}}[$i]) {
                $response->{body} = & { $route->{$request->{method}}[$i+1] };
                return send_response($head);
            }
        }
    }
    $response->{body} = 'This is the void';
    $response->{status} = 404;
    send_response($head);
}

# Sends a response to client. Default status is 200.
sub send_response {
    my ($head, $connection) = @_;
    $connection //= (($request->{version} // '') eq 'HTTP/1.1')
            ? lc($request->{hheaders}{connection} // '')
            : lc($request->{hheaders}{connection} // 'close') eq 'keep-alive' ? 'keep-alive' : 'close';
    $response->{status} //= 200;
    push @{$response->{headers}}, 'Date', rfc1123date();
    if (defined $response->{body} and !ref $response->{body}) {
        my @headers = keys %{{@{$response->{headers}}}};
        push @{$response->{headers}}, ('Content-Length', length $response->{body}) unless grep { $_ eq 'Content-Length' } @headers;
        push @{$response->{headers}}, ('Content-Type', 'text/plain') unless grep { $_ eq 'Content-Type' } @headers;
    }
    delete $response->{body} if $head // 0;
    push @{$response->{headers}}, 'Connection', $connection if $connection eq 'close' or ($connection eq 'keep-alive' and $request->{version} ne 'HTTP/1.1');
    unshift @{$response->{headers}}, 'Server', 'limper/' . ($Limper::VERSION // 'pre-release');
    $_->($request, $response) for @{$hook->{after}};
    return $hook->{response_handler}[0]->() if exists $hook->{response_handler};
    {
        local $\ = "\r\n";
        $conn->print(join ' ', $request->{version} // 'HTTP/1.1', $response->{status}, $response->{reason} // $reasons->{$response->{status}});
        return unless $conn->connected;
        $conn->print( join(': ', splice(@{$response->{headers}}, 0, 2)) ) while @{$response->{headers}};
        $conn->print();
    }
    $conn->print($response->{body} // '') if defined $response->{body};
    $conn->close if $connection eq 'close';
}

sub status {
    if (defined wantarray) {
        wantarray ? ($response->{status}, $response->{reason}) : $response->{status};
    } else {
        $response->{status} = shift;
        $response->{reason} = shift if @_;
    }
}

sub headers {
    if (defined wantarray) {
        wantarray ? @{$response->{headers}} : $response->{headers};
    } else {
        @{$response->{headers}} = @_;
    }
}

sub request { $request }

sub response { $response }

sub options { $options }

sub hook { push @{$hook->{$_[0]}}, $_[1] }

sub limp {
    $options = shift @_ if ref $_[0] eq 'HASH';
    return $hook->{request_handler}[0] if exists $hook->{request_handler};
    my $sock = IO::Socket::INET->new(Listen => SOMAXCONN, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp', @_)
            or die "cannot bind to port: $!";

    note 'limper started';

    for (1 .. $options->{workers} // 5) {
        defined(my $pid = fork) or die "fork failed: $!";
        while (!$pid) {
            if ($conn = $sock->accept()) {
                do {
                    eval {
                        get_request;
                        handle_request if $conn->connected;
                    };
                    if ($@) {
                        $response = { status => 500, body => $options->{debug} // 0 ? $@ : 'Internal Server Error' };
                        send_response 0, 'close';
                        warning $@;
                    }
                } while ($conn->connected);
            }
        }
    }
    1 while (wait != -1);

    my $shutdown = $sock->shutdown(2);
    my $closed = $sock->close();
    note 'shutdown ', $shutdown ? 'successful' : 'unsuccessful';
    note 'closed ', $closed ? 'successful' : 'unsuccessful';
}

1;

__END__

=for Pod::Coverage bad_request date get_request handle_request send_response timeout

=head1 NAME

Limper - extremely lightweight but not very powerful web application framework

=head1 VERSION

version 0.010

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
  status headers request response options hook limp

Also exportable:

  note warning rfc1123date

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

Note: All previously defined headers will be discarded if you set new headers.

=head2 request

Returns a C<HASH> of the request. Request keys are: C<method>, C<uri>, and
C<version>.  It may also contain C<headers> which is an C<ARRAY>,
C<hheaders> which is a C<HASH> form of the headers, and C<body>.

There is no decoding of the body content nor URL paramters.

=head2 response

Returns response C<HASH>. Keys are C<status>, C<reason>, C<headers> (an
C<ARRAY> of key/value pairs), and C<body>.

=head2 options

Returns options C<HASH>. See B<limp> below for known options.

=head2 hook

Adds a hook at some position.

Three hooks are currently defined: B<after>, B<request_handler>, and B<response_handler>.

=head3 after

Runs after all other processing, just before response is sent.

  hook after => sub {
    my ($request, $response) = @_;
    # modify response as needed
  };

=head3 request_handler

Runs when C<limp> is called, after only setting passed options, and returns
the result instead of starting up the built-in web server.  A simplified
example for PSGI (including the B<response_handler> below) is:

  hook request_handler => sub {
    get_psgi @_;
    handle_request;
  };

=head3 response_handler

Runs right after the B<after> hook, and returns the result instead of using
the built-in web server for sending the response. For PSGI, this is:

  hook response_handler => sub {
    [ response->{status}, response->{headers}, ref response->{body} ? response->{body} : [response->{body}] ];
  };

=head2 limp

Starts the server. You can pass it the same options as L<IO::Socket::INET>
takes.  The default options are:

  Listen => SOMAXCONN, ReuseAddr => 1, LocalAddr => 'localhost', LocalPort => 8080, Proto => 'tcp'

In addition, the first argument can be a C<HASH> to pass other settings:

  limp({debug => 1, timeout => 60, workers => 10}, LocalAddr => '0.0.0.0', LocalPort => 3001);

Default debug is C<0>, default timeout is C<5> (seconds), and default
workers is C<10>.  A timeout of C<0> means never timeout.

This keyword should be called at the very end of the script, once all routes
are defined.  At this point, Limper takes over control.

=head1 ADDITIONAL FUNCTIONS

=head2 note

=head2 warning

Log given list to B<STDOUT> or B<STDERR>. Prepends the current local time in
format "YYYY-MM-DD HH:MM:SS".

=head2 rfc1123date

Returns the current time or passed timestamp as an HTTP 1.1 date (RFC 1123).

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 by Ashley Willis E<lt>ashley+perl@gitable.orgE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.12.4 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

L<IO::Socket::INET>

L<Limper::PSGI>

L<Limper::SendFile>

L<Limper::SendJSON>

L<Dancer>

L<Dancer2>

L<Web::Simple>

L<App::FatPacker>
